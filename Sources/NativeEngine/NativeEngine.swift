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
// NativeEngine — F0 stub
// "Hello world" audio: plays Samples/pad.wav in a loop via AVAudioEngine.
// In F1+ the code string will be parsed; for now it is ignored and only pad
// is played to prove the AVAudioEngine pipeline works end-to-end.
// ---------------------------------------------------------------------------

/// Initialise with a dictionary of sample name → URL so the engine never
/// touches Bundle.module from the app, keeping it fully isolated.
///
/// Example:
/// ```swift
/// let engine = NativeEngine(sampleURLs: [
///     "pad":  Bundle.module.url(forResource: "pad",  withExtension: "wav", subdirectory: "Samples")!,
///     "bell": Bundle.module.url(forResource: "bell", withExtension: "wav", subdirectory: "Samples")!,
/// ])
/// ```
public final class NativeEngine: AudioDemoEngineProtocol {

    // MARK: - Properties

    private let sampleURLs: [String: URL]

    private let audioEngine = AVAudioEngine()
    private let padNode    = AVAudioPlayerNode()
    private let reverbNode = AVAudioUnitReverb()

    private var padBuffer: AVAudioPCMBuffer?
    private var isPlaying = false

    // MARK: - Init

    /// - Parameter sampleURLs: Map of sample name (e.g. "pad", "bell") to their file URLs.
    ///   The engine reads these files directly; it does NOT call Bundle.module.
    public init(sampleURLs: [String: URL]) {
        self.sampleURLs = sampleURLs
        setupAudioGraph()
    }

    // MARK: - AudioDemoEngineProtocol

    /// F0: ignores `code` and simply plays `pad.wav` in a loop.
    /// In F1+ the code will be parsed to schedule events.
    public func play(code: String) {
        guard !isPlaying else { return }

        guard let padURL = sampleURLs["pad"] else {
            print("[NativeEngine] pad sample URL not found")
            return
        }

        do {
            let file = try AVAudioFile(forReading: padURL)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else {
                print("[NativeEngine] Could not allocate PCM buffer")
                return
            }
            try file.read(into: buffer)
            self.padBuffer = buffer

            if !audioEngine.isRunning {
                try audioEngine.start()
            }

            // Schedule loop
            padNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            padNode.play()
            isPlaying = true
            print("[NativeEngine] Playing pad.wav in loop (F0 hello-world)")
        } catch {
            print("[NativeEngine] Error starting playback: \(error)")
        }
    }

    public func stop() {
        guard isPlaying else { return }
        padNode.stop()
        isPlaying = false
        print("[NativeEngine] Stopped")
    }

    // MARK: - Private

    private func setupAudioGraph() {
        // Attach nodes
        audioEngine.attach(padNode)
        audioEngine.attach(reverbNode)

        // Configure reverb (gentle room preset for meditation)
        reverbNode.loadFactoryPreset(.mediumRoom)
        reverbNode.wetDryMix = 40  // 40% wet — overridden in F2 by parsed room value

        let mainMixer = audioEngine.mainMixerNode
        let format = audioEngine.outputNode.inputFormat(forBus: 0)

        // pad → reverb → mainMixer → output
        audioEngine.connect(padNode,    to: reverbNode, format: nil)
        audioEngine.connect(reverbNode, to: mainMixer,  format: format)

        audioEngine.prepare()
    }
}
