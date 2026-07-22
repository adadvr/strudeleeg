// WebProbe — sonda headless para diagnosticar el Motor A sin abrir la app.
// Carga StrudelWeb/index.html igual que StrudelWebEngine, llama strudelPlay y
// luego reporta: estado del AudioContext, si fetch(file://...wav) funciona,
// y el contenido de los divs de status/error de la página.
//
// Uso: swift run WebProbe <ruta-al-bundle-de-recursos> [--allow-file]

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count > 1 else {
    print("uso: WebProbe <resourceBundleDir> [--allow-file]")
    exit(2)
}
let bundleDir = URL(fileURLWithPath: args[1])
let allowFile = args.contains("--allow-file")
let indexURL = bundleDir.appendingPathComponent("StrudelWeb/index.html")

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let config = WKWebViewConfiguration()
config.mediaTypesRequiringUserActionForPlayback = []
if allowFile {
    // Claves privadas (KVC) que permiten fetch/XHR de file:// desde página file://
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
    config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
}
if args.contains("--no-throttle") {
    // Sin esto, WebKit throttlea los timers de una página "oculta" y el reloj
    // de Strudel pierde todos sus deadlines ("skip query: too late").
    config.preferences.setValue(false, forKey: "hiddenPageDOMTimerThrottlingEnabled")
    config.preferences.setValue(false, forKey: "pageVisibilityBasedProcessSuppressionEnabled")
}

let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
let win = NSWindow(
    contentRect: NSRect(x: -100, y: -100, width: 1, height: 1),
    styleMask: [], backing: .buffered, defer: false
)
win.contentView = wv
win.orderBack(nil)

final class ProbeDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[probe] index.html cargado; esperando init de Strudel (4s)…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            // Capturar console.* para ver qué reporta el loader de samples
            let hook = """
            window.__probeLogs = [];
            ['log','warn','error'].forEach(k => {
              const orig = console[k];
              console[k] = (...a) => { window.__probeLogs.push(k + ': ' + a.map(String).join(' ')); orig(...a); };
            });
            undefined;
            """
            webView.evaluateJavaScript(hook) { _, _ in
                let seed = #"stack(s("pad").slow(4).gain(0.5).room(0.6), note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7))"#
                let encoded = String(data: try! JSONSerialization.data(withJSONObject: seed, options: [.fragmentsAllowed]), encoding: .utf8)!
                webView.evaluateJavaScript("window.strudelPlay(\(encoded)); undefined;") { _, err in
                    if let err { print("[probe] error evaluateJavaScript(play):", err.localizedDescription) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.diagnose(webView) }
        }
    }

    func diagnose(_ webView: WKWebView) {
        let body = """
        const r = {};
        r.ready = !!window.strudelReady;
        r.statusDiv = document.getElementById('status').textContent;
        r.errorDiv = document.getElementById('error').textContent;
        try {
          const g = __strudelExports.getAudioContext;
          r.hasGetCtx = !!g;
          if (g) {
            const ctx = g();
            r.ctxState = ctx.state;
            try { await ctx.resume(); r.ctxAfterResume = ctx.state; }
            catch (e) { r.resumeErr = String(e); }
          }
        } catch (e) { r.ctxErr = String(e); }
        try {
          const base = window.__STRUDEL_BASE_URL__ || new URL('../Samples/', location.href).href;
          r.base = base;
          const resp = await fetch(base + 'pad.wav');
          r.fetchOk = resp.ok;
          r.bytes = (await resp.arrayBuffer()).byteLength;
        } catch (e) { r.fetchErr = String(e); }
        r.logs = window.__probeLogs || [];
        return JSON.stringify(r);
        """
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): print("[probe] RESULT:", value as? String ?? "\(String(describing: value))")
            case .failure(let error): print("[probe] diagnose falló:", error.localizedDescription)
            }
            exit(0)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[probe] provisional navigation falló:", error.localizedDescription)
        exit(1)
    }
}

let delegate = ProbeDelegate()
wv.navigationDelegate = delegate
wv.loadFileURL(indexURL, allowingReadAccessTo: bundleDir)

// Timeout de seguridad
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    print("[probe] TIMEOUT")
    exit(3)
}

app.run()
