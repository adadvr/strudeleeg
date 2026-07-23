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

    /// Acceso al engine para tests de diagnóstico (tap en mainMixer).
    public var audioEngineForTesting: AVAudioEngine { audioEngine }
    private var scheduler: PatternScheduler?

    /// Called on the main thread if code parsing fails.
    public var onParseError: ((String) -> Void)?

    public init(sampleURLs: [String: URL]) {
        self.sampleURLs = sampleURLs
    }

    // MARK: - Playback

    public func play(code: String) {
        stop()

        let sched = makeScheduler(for: code)
        guard let sched = sched else { return }
        scheduler = sched
        print("[MiniEngine] Playing")
    }

    /// Parse code, apply tempo, and return a configured PatternScheduler ready to play.
    /// Returns nil (and fires onParseError) if code fails to parse.
    /// Exposed for testing: callers can inspect sched.cps after calling this.
    public func makeScheduler(for code: String) -> PatternScheduler? {
        let parser = CodeParser()
        let result: ParseResult
        do {
            result = try parser.parseWithTempo(code)
        } catch {
            let msg = error.localizedDescription
            print("[MiniEngine] Parse error: \(msg)")
            DispatchQueue.main.async { self.onParseError?(msg) }
            return nil
        }

        let sched = PatternScheduler(audioEngine: audioEngine, sampleURLs: sampleURLs)

        // Bug 1 fix: apply setcps/setcpm BEFORE handing the pattern to the scheduler.
        // parseWithTempo() returns cps=nil when no tempo statement is present (use scheduler default).
        if let cps = result.cps {
            sched.setcps(cps)
        }

        sched.play(pattern: result.pattern)
        return sched
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
