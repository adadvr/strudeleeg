import Foundation
import NativeEngine

// ---------------------------------------------------------------------------
// EngineAdapter — bridges NativeEngine.AudioDemoEngineProtocol to the app's
// AudioDemoEngine protocol so the UI stays decoupled from the engine target.
// ---------------------------------------------------------------------------

final class NativeEngineAdapter: AudioDemoEngine {

    private let engine: NativeEngine

    /// Forwarded from NativeEngine.onParseError; set by DemoViewModel.
    var onParseError: ((String) -> Void)? {
        didSet { engine.onParseError = onParseError }
    }

    init() {
        // Resolve sample URLs from the app bundle (DemoStrudelApp_DemoStrudelApp.bundle
        // is created by SPM for the resources target).
        // We pass the URLs to NativeEngine so it stays Bundle-independent.
        let bundle = Bundle.module

        var urls: [String: URL] = [:]

        if let padURL = bundle.url(
            forResource: "pad",
            withExtension: "wav",
            subdirectory: "Samples"
        ) {
            urls["pad"] = padURL
        } else {
            print("[EngineAdapter] Warning: pad.wav not found in bundle")
        }

        if let bellURL = bundle.url(
            forResource: "bell",
            withExtension: "wav",
            subdirectory: "Samples"
        ) {
            urls["bell"] = bellURL
        } else {
            print("[EngineAdapter] Warning: bell.wav not found in bundle")
        }

        self.engine = NativeEngine(sampleURLs: urls)
    }

    func play(code: String) {
        engine.play(code: code)
    }

    func stop() {
        engine.stop()
    }
}
