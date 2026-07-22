import AVFoundation
import Foundation

// ---------------------------------------------------------------------------
// Scheduler — F1
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
// Nodes:
//   • One AVAudioPlayerNode per "pad" event (fire-and-forget per shot).
//   • For "bell" (pitched), pool of AVAudioPlayerNode + AVAudioUnitVarispeed,
//     rate = 2^((midi-60)/12).  Root note is C4 = MIDI 60.
// ---------------------------------------------------------------------------

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

    // Pool of player nodes — we keep them attached to the engine
    // and recycle them for new shots.
    private var playerPool: [PlayerSlot] = []
    private let poolQueue = DispatchQueue(label: "com.strudel.scheduler.pool")

    private struct PlayerSlot {
        let playerNode: AVAudioPlayerNode
        let varispeedNode: AVAudioUnitVarispeed?   // nil for pad (no pitch shift)
        var inUse: Bool
    }

    // MARK: - Init

    public init(audioEngine: AVAudioEngine, sampleURLs: [String: URL]) {
        self.audioEngine = audioEngine
        self.sampleURLs = sampleURLs
    }

    // MARK: - Public API

    /// Parse `code`, set up layers, reset cycle, start scheduling.
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

        // Start engine if needed
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("[Scheduler] Could not start AVAudioEngine: \(error)")
                return
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

        poolQueue.sync {
            for slot in playerPool {
                slot.playerNode.stop()
            }
        }
        print("[Scheduler] Stopped")
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
        // Convert absolute host seconds to cycle-relative position
        let elapsed0 = windowStart - startHostTime  // elapsed at window start
        let elapsed1 = windowEnd   - startHostTime  // elapsed at window end

        for layer in layers {
            let cycleDuration = Scheduler.CYCLE_SECONDS * layer.slowFactor
            // Which cycles overlap with [elapsed0, elapsed1)?
            let firstCycle = Int(floor(elapsed0 / cycleDuration))
            let lastCycle  = Int(floor(elapsed1 / cycleDuration))

            for cycleIndex in firstCycle...lastCycle {
                let cycleStart = Double(cycleIndex) * cycleDuration
                let events = layer.eventsForCycle(cycleIndex)

                for event in events {
                    let absoluteTime = startHostTime + cycleStart + event.cycleOnset * cycleDuration

                    // Only schedule events inside [windowStart, windowEnd)
                    // and that we haven't already scheduled (>= our old scheduledUpTo).
                    guard absoluteTime >= windowStart, absoluteTime < windowEnd else { continue }

                    // Also guard against past events on first call
                    guard absoluteTime >= startHostTime else { continue }

                    scheduleEvent(
                        sample: layer.sample,
                        midiNote: event.midiNote,
                        absoluteHostSeconds: absoluteTime
                    )
                }
            }
        }
    }

    private func scheduleEvent(sample: String, midiNote: Int?, absoluteHostSeconds: Double) {
        guard let buffer = buffers[sample] else {
            print("[Scheduler] No buffer for sample: \(sample)")
            return
        }

        // Compute AVAudioTime from absolute host seconds
        guard let avTime = avAudioTime(forHostSeconds: absoluteHostSeconds, format: buffer.format) else {
            return
        }

        // Pitch rate: 2^((midi-60)/12)
        let rate: Float
        if let midi = midiNote {
            rate = Float(pow(2.0, Double(midi - 60) / 12.0))
        } else {
            rate = 1.0
        }

        scheduleBufferFired(buffer: buffer, at: avTime, rate: rate)
    }

    // MARK: - Node pool management

    private func scheduleBufferFired(buffer: AVAudioPCMBuffer, at time: AVAudioTime, rate: Float) {
        poolQueue.async { [weak self] in
            guard let self else { return }

            let needsVarispeed = (rate != 1.0)
            let slot = self.acquireSlot(needsVarispeed: needsVarispeed)

            if let vs = slot.varispeedNode {
                vs.rate = rate
            }

            slot.playerNode.scheduleBuffer(buffer, at: time, options: [], completionHandler: {
                self.poolQueue.async {
                    // Mark slot free (we don't actually need to track — nodes can
                    // be scheduled again without issue; AVAudioPlayerNode queues internally)
                }
            })
            // Ensure the node is playing (might already be from a prior shot)
            if !slot.playerNode.isPlaying {
                slot.playerNode.play()
            }
        }
    }

    /// Acquire or create a player slot. We keep a small pool and grow as needed.
    private func acquireSlot(needsVarispeed: Bool) -> PlayerSlot {
        // Try to find an existing slot of the right type
        for i in playerPool.indices {
            let slot = playerPool[i]
            let hasVarispeed = slot.varispeedNode != nil
            if hasVarispeed == needsVarispeed {
                return slot  // reuse (AVAudioPlayerNode queues multiple buffers)
            }
        }
        // Create a new slot
        let player = AVAudioPlayerNode()
        var slot: PlayerSlot
        if needsVarispeed {
            let vs = AVAudioUnitVarispeed()
            audioEngine.attach(player)
            audioEngine.attach(vs)
            let mainMixer = audioEngine.mainMixerNode
            audioEngine.connect(player, to: vs, format: nil)
            audioEngine.connect(vs, to: mainMixer, format: mainMixer.outputFormat(forBus: 0))
            slot = PlayerSlot(playerNode: player, varispeedNode: vs, inUse: false)
        } else {
            audioEngine.attach(player)
            let mainMixer = audioEngine.mainMixerNode
            audioEngine.connect(player, to: mainMixer, format: nil)
            slot = PlayerSlot(playerNode: player, varispeedNode: nil, inUse: false)
        }
        // Start engine connections take effect automatically (engine must be running or prepared)
        playerPool.append(slot)
        return slot
    }

    // MARK: - Buffer loading

    private func preloadBuffers() throws {
        // Collect which samples are actually needed
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
        // mach_absolute_time is in mach ticks; convert to seconds using timebase
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_absolute_time()
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000.0
    }

    private func avAudioTime(forHostSeconds seconds: Double, format: AVAudioFormat) -> AVAudioTime? {
        // Convert host seconds → mach ticks
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanoSeconds = seconds * 1_000_000_000.0
        let ticks = UInt64(nanoSeconds) * UInt64(info.denom) / UInt64(info.numer)
        return AVAudioTime(hostTime: ticks)
    }
}
