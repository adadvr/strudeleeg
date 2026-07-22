import AppKit
import WebKit

// ---------------------------------------------------------------------------
// StrudelWebEngine — Motor A
//
// Runs Strudel REAL inside a hidden WKWebView (0×0 NSView, off-screen).
// The HTML loads the offline strudel-bundle.js, registers local WAV samples,
// and exposes window.strudelPlay(code) / window.strudelStop().
//
// File access: loadFileURL(_:allowingReadAccessTo:) grants access to the whole
// SPM resource bundle directory, so the WebView can read both:
//   • StrudelWeb/strudel-bundle.js  (offline JS)
//   • Samples/bell.wav, Samples/pad.wav  (WAV files)
//
// Bell tuning: bell.wav is recorded at C4 (MIDI 60). We register it with the
// note-key map { c4: ['bell.wav'] } so superdough calculates pitch-shift
// relative to C4 instead of the default C2 — matching Motor B's behavior.
//
// Base URL injection: the Samples/ file:// URL is injected as a WKUserScript
// (injection time = .atDocumentStart) so it's available before any JS runs.
// ---------------------------------------------------------------------------

@MainActor
final class StrudelWebEngine: NSObject, @preconcurrency AudioDemoEngine, WKNavigationDelegate, WKScriptMessageHandler {

    // ── State ─────────────────────────────────────────────────────────────
    private var webView: WKWebView?
    private var isLoaded = false
    private var pendingCode: String?
    // Retain the off-screen window so it isn't released
    private var offscreenWindow: NSWindow?

    /// Called on JS errors or parse failures — wire to UI for red text.
    var onError: ((String) -> Void)?

    /// Called when the engine reports playing / stopped status.
    var onStatusChange: ((String) -> Void)?

    // ── Init ──────────────────────────────────────────────────────────────
    override init() {
        super.init()
        setupWebView()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()

        // Allow audio without requiring a user gesture (critical for macOS WKWebView)
        config.mediaTypesRequiringUserActionForPlayback = []

        // Inject the Samples base URL at document start so the JS can read it
        // synchronously before doInit() calls getBaseUrl().
        if let baseUrlScript = makeSamplesBaseUrlScript() {
            config.userContentController.addUserScript(
                WKUserScript(
                    source: baseUrlScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        // Message handlers for JS→Swift communication (weak to avoid retain cycle)
        let coordinator = WeakCoordinator(engine: self)
        config.userContentController.add(coordinator, name: "strudelReady")
        config.userContentController.add(coordinator, name: "strudelError")
        config.userContentController.add(coordinator, name: "strudelStatus")

        // Off-screen WKWebView — needs to be attached to a window to run JS on macOS.
        // We keep it at 1×1 off screen so it doesn't appear on screen.
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self

        let win = NSWindow(
            contentRect: NSRect(x: -20, y: -20, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        win.contentView = wv
        win.orderBack(nil)

        self.webView = wv
        self.offscreenWindow = win  // must be retained

        loadHTML()
    }

    /// Builds a JS snippet that sets window.__STRUDEL_BASE_URL__ to the
    /// file:// URL of the Samples/ folder in the resource bundle.
    private func makeSamplesBaseUrlScript() -> String? {
        guard
            let samplesURL = Bundle.module.url(
                forResource: "pad",
                withExtension: "wav",
                subdirectory: "Samples"
            )
        else { return nil }

        var base = samplesURL.deletingLastPathComponent().absoluteString
        if !base.hasSuffix("/") { base += "/" }

        guard let encoded = encodeStringAsJSONString(base) else { return nil }
        return "window.__STRUDEL_BASE_URL__ = \(encoded);"
    }

    private func loadHTML() {
        guard let wv = webView else { return }

        guard let bundleResourceURL = Bundle.module.resourceURL else {
            onError?("StrudelWebEngine: Bundle.module.resourceURL is nil")
            return
        }

        guard let indexURL = Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "StrudelWeb"
        ) else {
            onError?("StrudelWebEngine: StrudelWeb/index.html not found in bundle")
            return
        }

        // allowingReadAccessTo: bundle root → WebView can read Samples/ and StrudelWeb/
        wv.loadFileURL(indexURL, allowingReadAccessTo: bundleResourceURL)
    }

    // ── AudioDemoEngine ───────────────────────────────────────────────────

    func play(code: String) {
        guard let wv = webView else { return }

        if isLoaded {
            evaluatePlay(code: code, in: wv)
        } else {
            pendingCode = code
        }
    }

    func stop() {
        guard let wv = webView else { return }
        wv.evaluateJavaScript("window.strudelStop(); undefined;") { _, _ in }
    }

    // ── Private helpers ───────────────────────────────────────────────────

    private func evaluatePlay(code: String, in wv: WKWebView) {
        guard let encoded = encodeStringAsJSONString(code) else {
            onError?("StrudelWebEngine: failed to JSON-encode code")
            return
        }
        // Termina en `undefined`: strudelPlay es async y devuelve una Promise,
        // que evaluateJavaScript no puede serializar y reporta como error falso.
        // Los errores reales llegan por el message handler "strudelError".
        let js = "window.strudelPlay(\(encoded)); undefined;"
        wv.evaluateJavaScript(js) { [weak self] _, error in
            if let error = error as NSError?,
               !(error.domain == WKError.errorDomain
                 && error.code == WKError.javaScriptResultTypeIsUnsupported.rawValue) {
                Task { @MainActor in
                    self?.onError?("JS error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Returns a JSON string literal (with quotes) safe for embedding in JS.
    /// .fragmentsAllowed es obligatorio: sin él, un String top-level lanza
    /// NSException (no un Swift error, así que try? no la atrapa).
    private func encodeStringAsJSONString(_ s: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    // ── WKNavigationDelegate ──────────────────────────────────────────────

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isLoaded = true

            if let code = self.pendingCode {
                self.pendingCode = nil
                self.evaluatePlay(code: code, in: webView)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.onError?("WebView navigation failed: \(error.localizedDescription)")
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.onError?("WebView provisional navigation failed: \(error.localizedDescription)")
        }
    }

    // ── WKScriptMessageHandler ─────────────────────────────────────────────

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            switch message.name {
            case "strudelReady":
                break  // handled via isLoaded / pendingCode mechanism
            case "strudelError":
                let msg = message.body as? String ?? "Unknown Strudel error"
                self.onError?(msg)
            case "strudelStatus":
                let status = message.body as? String ?? ""
                self.onStatusChange?(status)
            default:
                break
            }
        }
    }
}

// ---------------------------------------------------------------------------
// WeakCoordinator — prevents retain cycle WKWebView ↔ StrudelWebEngine
// ---------------------------------------------------------------------------
private final class WeakCoordinator: NSObject, WKScriptMessageHandler {
    weak var engine: StrudelWebEngine?

    init(engine: StrudelWebEngine) {
        self.engine = engine
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        engine?.userContentController(userContentController, didReceive: message)
    }
}
