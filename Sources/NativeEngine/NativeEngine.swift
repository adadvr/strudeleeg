import AVFoundation

// ---------------------------------------------------------------------------
// AudioDemoEngine protocol — duplicated here so NativeEngine stays isolated
// (no dependency on the app target's AudioDemoEngine.swift).
// The app target bridges them via a thin conformance wrapper.
// ---------------------------------------------------------------------------

/// The protocol that all demo audio engines must conform to.
/// NOTE: This definition lives in NativeEngine so the target stays self-contained.
/// The DemoStrudelApp target has its own copy (AudioDemoEngine.swift) that the UI uses.
public protocol AudioDemoEngineProtocol {
    func play(code: String)
    func stop()
}

// ---------------------------------------------------------------------------
// PlayResult — carries success or a human-readable error
// ---------------------------------------------------------------------------

public enum PlayResult {
    case ok
    case error(String)
}

// ---------------------------------------------------------------------------
// NativeEngine — F2
// Wires MiniNotationParser → Scheduler → AVAudioEngine.
// Effects (gain/room/cutoff) are applied per-layer in the Scheduler (F2).
// ---------------------------------------------------------------------------

/// Initialise with a dictionary of sample name → URL so the engine never
/// touches Bundle.module from the app, keeping it fully isolated.
public final class NativeEngine: AudioDemoEngineProtocol {

    // MARK: - Properties

    private let sampleURLs: [String: URL]
    private let audioEngine = AVAudioEngine()
    private var scheduler: Scheduler?

    private var isPlaying = false

    /// Called on the main thread with a human-readable error if parse fails.
    public var onParseError: ((String) -> Void)?

    // MARK: - Init

    public init(sampleURLs: [String: URL]) {
        self.sampleURLs = sampleURLs
        prepareEngine()
    }

    // MARK: - AudioDemoEngineProtocol

    /// Parse `code`, then start the scheduler. Re-entrant: always stops previous playback first.
    public func play(code: String) {
        stop()

        let parser = MiniNotationParser()
        let layers: [Layer]
        do {
            layers = try parser.parse(code)
        } catch let e as ParseError {
            let msg = e.errorDescription ?? e.localizedDescription
            print("[NativeEngine] Parse error: \(msg)")
            DispatchQueue.main.async { self.onParseError?(msg) }
            return
        } catch {
            let msg = error.localizedDescription
            print("[NativeEngine] Unexpected parse error: \(msg)")
            DispatchQueue.main.async { self.onParseError?(msg) }
            return
        }

        if layers.isEmpty {
            print("[NativeEngine] No layers parsed — nothing to play")
            return
        }

        // Log parsed layers for debugging
        for (i, layer) in layers.enumerated() {
            print("[NativeEngine] Layer \(i): sample=\(layer.sample) slowFactor=\(layer.slowFactor) isAlternation=\(layer.isAlternation) events=\(layer.events.count) gain=\(layer.gain.map { "\($0)" } ?? "nil") room=\(layer.room.map { "\($0)" } ?? "nil") cutoff=\(layer.cutoff.map { "\($0)" } ?? "nil")")
        }

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("[NativeEngine] Failed to start engine: \(error)")
                return
            }
        }

        let sched = Scheduler(audioEngine: audioEngine, sampleURLs: sampleURLs)
        scheduler = sched
        sched.play(layers: layers)
        isPlaying = true
        print("[NativeEngine] Playing F2 (parser + scheduler + effects)")
    }

    public func stop() {
        scheduler?.stop()
        scheduler = nil
        isPlaying = false
    }

    // MARK: - Private

    private func prepareEngine() {
        audioEngine.prepare()
    }
}
