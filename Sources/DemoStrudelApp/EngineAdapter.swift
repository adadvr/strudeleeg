import Foundation
import MiniEngine

// ---------------------------------------------------------------------------
// EngineAdapter — bridges MiniEngine to the app's AudioDemoEngine protocol.
// MiniEngine is Bundle-independent; we resolve sample URLs here from the
// app bundle and pass them to MiniEngine at init time.
// ---------------------------------------------------------------------------

final class NativeEngineAdapter: AudioDemoEngine {

    private let engine: MiniEngine

    /// Forwarded from MiniEngine.onParseError; set by DemoViewModel.
    var onParseError: ((String) -> Void)? {
        didSet { engine.onParseError = onParseError }
    }

    init() {
        let bundle = Bundle.module

        var urls: [String: URL] = [:]

        if let url = bundle.url(
            forResource: "pad",
            withExtension: "wav",
            subdirectory: "Samples"
        ) {
            urls["pad"] = url
        } else {
            print("[EngineAdapter] Warning: pad.wav not found in bundle")
        }

        if let url = bundle.url(
            forResource: "bell",
            withExtension: "wav",
            subdirectory: "Samples"
        ) {
            urls["bell"] = url
        } else {
            print("[EngineAdapter] Warning: bell.wav not found in bundle")
        }

        self.engine = MiniEngine(sampleURLs: urls)
    }

    func play(code: String) {
        engine.play(code: code)
    }

    func stop() {
        engine.stop()
    }
}
