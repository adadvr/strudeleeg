// ---------------------------------------------------------------------------
// MiniEngine — public entry point for the production audio engine.
// Wraps CodeParser + PatternScheduler + SampleBankManager.
//
// Remote samples:
//   If code contains samples('github:tidalcycles/dirt-samples') or
//   samples('https://...strudel.json'), the manifests are registered with
//   SampleBankManager before playback begins. Downloads are lazy + async;
//   the engine never blocks waiting for network. Bundle-local samples remain
//   the fallback if network is unavailable.
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

    /// Optional remote bank manager. When set, remote samples() calls are honoured.
    /// Defaults to SampleBankManager.shared. Can be replaced for testing.
    public var bankManager: SampleBankManager = .shared

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

    /// Parse code, apply tempo, register any samples() manifests, and return a
    /// configured PatternScheduler ready to play.
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

        // Register remote manifests found in samples('...') calls.
        // Espera acotada a que los manifests estén registrados ANTES de play:
        // sin esto, el prefetch del scheduler no conoce aún los nombres remotos
        // y el primer ciclo se salta aunque los samples estén en caché de disco.
        // El manifest cacheado carga en ms; el timeout mantiene el no-bloqueo.
        if !result.manifestURLs.isEmpty {
            sched.bankManager = bankManager
            let group = DispatchGroup()
            for urlStr in result.manifestURLs {
                group.enter()
                bankManager.register(manifestURL: urlStr) { key in
                    if let k = key {
                        print("[MiniEngine] Remote bank registered: \(k)")
                    } else {
                        print("[MiniEngine] Warning: manifest could not be loaded: \(urlStr)")
                    }
                    group.leave()
                }
            }
            _ = group.wait(timeout: .now() + 1.5)
        }

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
