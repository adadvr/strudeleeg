import AVFoundation
import Foundation

// ---------------------------------------------------------------------------
// Scheduler — F2
// Cycle-based lookahead scheduler built on AVAudioEngine.
//
// Tempo: 0.5 cycles/second → 1 cycle = 2 seconds (Strudel default).
//
// Strategy:
//   • A DispatchSourceTimer fires every ~100ms.
//   • It looks LOOKAHEAD_SECONDS seconds ahead and schedules any events
//     that fall in the upcoming window that haven't been scheduled yet.
//   • Time anchor: on start(), we record audioEngine.outputNode.lastRenderTime
//     (converted to AVAudioTime in host ticks / sample time) as t=0.
//   • Each event's AVAudioTime = anchor + (absoluteTimeInSeconds * sampleRate).
//
// F2 — Per-layer effect chains
// ─────────────────────────────
//   • Each layer gets its own LayerChain: one player node (+ varispeed if the
//     layer has note/pitch events) wired through optional EQ and reverb to
//     the main mixer.
//
//   Chain topology per layer:
//     player → [varispeed] → [EQ lowPass if cutoff≠nil] → [reverb if room≠nil] → mainMixer
//
//   • gain  (0..1) → player.volume
//   • cutoff (Hz)  → AVAudioUnitEQ, single lowPass band, bypass=false
//   • room  (0..1) → AVAudioUnitReverb, wetDryMix = room*100
//                    Preset: .mediumHall — chosen because it gives a neutral,
//                    medium-decay hall tail (~1.5 s) that matches Strudel's
//                    generic "room" reverb for meditation pads and bells without
//                    the excessive muddiness of .largeHall or .cathedral.
//
//   The chain is rebuilt on every play() so re-parsings with different values
//   take effect cleanly (no stale nodes).
// ---------------------------------------------------------------------------

/// Holds all AVAudio nodes that belong to one parsed layer.
private final class LayerChain {
    let player: AVAudioPlayerNode
    let varispeed: AVAudioUnitVarispeed?  // non-nil only when pitch-shifting is needed
    let eq: AVAudioUnitEQ?               // non-nil when layer.cutoff != nil
    let reverb: AVAudioUnitReverb?        // non-nil when layer.room != nil

    init(player: AVAudioPlayerNode,
         varispeed: AVAudioUnitVarispeed?,
         eq: AVAudioUnitEQ?,
         reverb: AVAudioUnitReverb?) {
        self.player = player
        self.varispeed = varispeed
        self.eq = eq
        self.reverb = reverb
    }
}

public final class Scheduler {

    // MARK: - Constants

    private static let CYCLE_SECONDS: Double = 2.0          // 1 cycle = 2 s
    private static let LOOKAHEAD_SECONDS: Double = 0.4      // schedule 400 ms ahead
    private static let TIMER_INTERVAL_SECONDS: Double = 0.1 // fire every 100 ms

    // MARK: - Dependencies

    private let audioEngine: AVAudioEngine
    private let sampleURLs: [String: URL]

    // MARK: - State

    private var layers: [Layer] = []
    private var isRunning = false

    /// Wall-clock host time (seconds) when cycle 0 started.
    private var startHostTime: Double = 0

    /// The furthest absolute time (in seconds) we have already scheduled up to.
    private var scheduledUpTo: Double = 0

    private var timerSource: DispatchSourceTimer?

    // Loaded audio buffers (one per sample)
    private var buffers: [String: AVAudioPCMBuffer] = [:]

    // Per-layer effect chains (index matches layers array)
    private var chains: [LayerChain] = []

    private let poolQueue = DispatchQueue(label: "com.strudel.scheduler.pool")

    // MARK: - Init

    public init(audioEngine: AVAudioEngine, sampleURLs: [String: URL]) {
        self.audioEngine = audioEngine
        self.sampleURLs = sampleURLs
    }

    // MARK: - Public API

    /// Set up layers with effect chains, reset cycle, start scheduling.
    public func play(layers: [Layer]) {
        stop()

        self.layers = layers

        // Preload buffers
        do {
            try preloadBuffers()
        } catch {
            print("[Scheduler] Failed to preload buffers: \(error)")
            return
        }

        // Build per-layer effect chains (must happen before engine start so
        // nodes are attached and connected before audio graph is running)
        buildChains(for: layers)

        // Start engine if needed
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("[Scheduler] Could not start AVAudioEngine: \(error)")
                return
            }
        }

        // Start all player nodes so they are ready to receive scheduled buffers
        for chain in chains {
            if !chain.player.isPlaying {
                chain.player.play()
            }
        }

        // Anchor time: now in host seconds
        startHostTime = hostTimeNow()
        scheduledUpTo = startHostTime  // schedule from now

        isRunning = true

        // Fire once immediately, then every TIMER_INTERVAL_SECONDS
        let src = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        src.schedule(
            deadline: .now(),
            repeating: .milliseconds(Int(Scheduler.TIMER_INTERVAL_SECONDS * 1000))
        )
        src.setEventHandler { [weak self] in self?.tick() }
        src.resume()
        timerSource = src
    }

    public func stop() {
        isRunning = false
        timerSource?.cancel()
        timerSource = nil

        // Stop all player nodes, then detach all nodes in each chain
        for chain in chains {
            chain.player.stop()
            detachChain(chain)
        }
        chains = []

        print("[Scheduler] Stopped")
    }

    // MARK: - Effect chain construction

    /// Build and attach one LayerChain per layer, connecting the audio graph.
    private func buildChains(for layers: [Layer]) {
        let mainMixer = audioEngine.mainMixerNode

        for layer in layers {
            // Does this layer ever produce pitched events?
            let needsPitch = layer.isAlternation
                ? layer.alternatives.contains { $0.contains { $0.midiNote != nil } }
                : layer.events.contains { $0.midiNote != nil }

            // --- Create nodes ---
            let player = AVAudioPlayerNode()

            let varispeed: AVAudioUnitVarispeed? = needsPitch ? AVAudioUnitVarispeed() : nil

            let eq: AVAudioUnitEQ?
            if let hz = layer.cutoff {
                let unit = AVAudioUnitEQ(numberOfBands: 1)
                let band = unit.bands[0]
                band.filterType = .lowPass
                band.frequency  = Float(hz)
                band.bypass     = false
                // Resonance (Q): 0 dB keeps it a clean Butterworth-like response,
                // neutral for a meditation low-pass without resonance peaks.
                band.bandwidth  = 1.0   // octaves — ignored for lowPass; Q is implicit
                eq = unit
            } else {
                eq = nil
            }

            let reverb: AVAudioUnitReverb?
            if let room = layer.room {
                let unit = AVAudioUnitReverb()
                // .mediumHall: neutral hall decay (~1.5 s), transparent enough for
                // bell transients, warm enough for pad drones. largeHall adds ~3 s
                // decay that muddies overlapping bell events; cathedral would be
                // overkill. mediumHall matches Strudel's generic "room" feel.
                unit.loadFactoryPreset(.mediumHall)
                unit.wetDryMix = Float(room * 100)
                reverb = unit
            } else {
                reverb = nil
            }

            // --- Apply gain to player volume ---
            player.volume = Float(layer.gain ?? 1.0)

            // --- Attach all nodes ---
            audioEngine.attach(player)
            if let vs = varispeed { audioEngine.attach(vs) }
            if let eq = eq        { audioEngine.attach(eq) }
            if let rv = reverb    { audioEngine.attach(rv) }

            // --- Wire the chain ---
            // player → [varispeed] → [eq] → [reverb] → mainMixer
            var upstream: AVAudioNode = player

            if let vs = varispeed {
                audioEngine.connect(upstream, to: vs, format: nil)
                upstream = vs
            }
            if let eq = eq {
                audioEngine.connect(upstream, to: eq, format: nil)
                upstream = eq
            }
            if let rv = reverb {
                audioEngine.connect(upstream, to: rv, format: nil)
                upstream = rv
            }

            audioEngine.connect(upstream, to: mainMixer, format: nil)

            let chain = LayerChain(player: player, varispeed: varispeed, eq: eq, reverb: reverb)
            chains.append(chain)

            // Debug log
            let gainStr   = layer.gain.map   { String(format: "%.2f", $0) } ?? "—"
            let roomStr   = layer.room.map   { String(format: "%.2f", $0) } ?? "—"
            let cutoffStr = layer.cutoff.map { String(format: "%.0f Hz", $0) } ?? "—"
            print("[Scheduler] Chain built: sample=\(layer.sample)"
                + " player.volume=\(gainStr)"
                + " varispeed=\(varispeed != nil)"
                + " EQ(lowPass)=\(cutoffStr)"
                + " reverb(mediumHall)=\(roomStr)"
            )
        }
    }

    /// Detach all nodes in a chain from the engine.
    private func detachChain(_ chain: LayerChain) {
        chain.player.stop()
        audioEngine.detach(chain.player)
        if let vs = chain.varispeed { audioEngine.detach(vs) }
        if let eq = chain.eq        { audioEngine.detach(eq) }
        if let rv = chain.reverb    { audioEngine.detach(rv) }
    }

    // MARK: - Scheduling loop

    private func tick() {
        guard isRunning else { return }

        let now = hostTimeNow()
        let horizon = now + Scheduler.LOOKAHEAD_SECONDS

        // We schedule events from scheduledUpTo → horizon
        scheduleEvents(from: scheduledUpTo, to: horizon)
        scheduledUpTo = horizon
    }

    private func scheduleEvents(from windowStart: Double, to windowEnd: Double) {
        let elapsed0 = windowStart - startHostTime
        let elapsed1 = windowEnd   - startHostTime

        for (layerIndex, layer) in layers.enumerated() {
            guard layerIndex < chains.count else { continue }
            let chain = chains[layerIndex]

            let cycleDuration = Scheduler.CYCLE_SECONDS * layer.slowFactor
            let firstCycle = Int(floor(elapsed0 / cycleDuration))
            let lastCycle  = Int(floor(elapsed1 / cycleDuration))

            for cycleIndex in firstCycle...lastCycle {
                let cycleStart = Double(cycleIndex) * cycleDuration
                let events = layer.eventsForCycle(cycleIndex)

                for event in events {
                    let absoluteTime = startHostTime + cycleStart + event.cycleOnset * cycleDuration

                    guard absoluteTime >= windowStart, absoluteTime < windowEnd else { continue }
                    guard absoluteTime >= startHostTime else { continue }

                    scheduleEvent(
                        chain: chain,
                        sample: layer.sample,
                        midiNote: event.midiNote,
                        absoluteHostSeconds: absoluteTime
                    )
                }
            }
        }
    }

    private func scheduleEvent(chain: LayerChain,
                               sample: String,
                               midiNote: Int?,
                               absoluteHostSeconds: Double) {
        guard let buffer = buffers[sample] else {
            print("[Scheduler] No buffer for sample: \(sample)")
            return
        }

        guard let avTime = avAudioTime(forHostSeconds: absoluteHostSeconds) else {
            return
        }

        // Pitch rate: 2^((midi-60)/12). Root note of samples is C4 = MIDI 60.
        let rate: Float
        if let midi = midiNote {
            rate = Float(pow(2.0, Double(midi - 60) / 12.0))
        } else {
            rate = 1.0
        }

        poolQueue.async {
            if let vs = chain.varispeed {
                vs.rate = rate
            }

            chain.player.scheduleBuffer(buffer, at: avTime, options: [], completionHandler: nil)

            if !chain.player.isPlaying {
                chain.player.play()
            }
        }
    }

    // MARK: - Buffer loading

    private func preloadBuffers() throws {
        let needed = Set(layers.map { $0.sample })
        for name in needed {
            if buffers[name] != nil { continue }
            guard let url = sampleURLs[name] else {
                throw ParseError.unknownSample(name)
            }
            let file = try AVAudioFile(forReading: url)
            guard let buf = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else {
                throw ParseError.syntaxError("Could not allocate buffer for \(name)")
            }
            try file.read(into: buf)
            buffers[name] = buf
        }
    }

    // MARK: - Time utilities

    private func hostTimeNow() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_absolute_time()
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000.0
    }

    private func avAudioTime(forHostSeconds seconds: Double) -> AVAudioTime? {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanoSeconds = seconds * 1_000_000_000.0
        let ticks = UInt64(nanoSeconds) * UInt64(info.denom) / UInt64(info.numer)
        return AVAudioTime(hostTime: ticks)
    }
}
