// ---------------------------------------------------------------------------
// MiniEngine — public entry point for the production audio engine.
// Wraps CodeParser + PatternScheduler.
// ---------------------------------------------------------------------------

import AVFoundation

/// Errors that can occur in MiniEngine.
public enum MiniEngineError: Error, LocalizedError {
    case parseError(String)

    public var errorDescription: String? {
        if case .parseError(let m) = self { return m }
        return nil
    }
}

/// The production audio engine.
/// Init with sample URLs (keeps the engine Bundle-independent).
public final class MiniEngine {

    private let sampleURLs: [String: URL]
    private let audioEngine = AVAudioEngine()
    private var scheduler: PatternScheduler?

    /// Called on the main thread if code parsing fails.
    public var onParseError: ((String) -> Void)?

    public init(sampleURLs: [String: URL]) {
        self.sampleURLs = sampleURLs
    }

    // MARK: - Playback

    public func play(code: String) {
        stop()

        let parser = CodeParser()
        let pattern: ControlPattern
        do {
            pattern = try parser.parse(code)
        } catch {
            let msg = error.localizedDescription
            print("[MiniEngine] Parse error: \(msg)")
            DispatchQueue.main.async { self.onParseError?(msg) }
            return
        }

        let sched = PatternScheduler(audioEngine: audioEngine, sampleURLs: sampleURLs)
        scheduler = sched
        sched.play(pattern: pattern)
        print("[MiniEngine] Playing")
    }

    public func stop() {
        scheduler?.stop()
        scheduler = nil
    }

    // MARK: - Lower-level API (useful for testing / REPL)

    /// Parse code into a ControlPattern (no audio).
    public func parsePattern(_ code: String) throws -> ControlPattern {
        try CodeParser().parse(code)
    }
}
