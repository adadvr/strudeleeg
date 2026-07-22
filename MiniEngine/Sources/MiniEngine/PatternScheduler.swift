// ---------------------------------------------------------------------------
// PatternScheduler — queries a ControlPattern cycle-by-cycle and dispatches
// each Hap to AVAudioEngine.
//
// Tempo: 0.5 cps → 1 cycle = 2 seconds (Strudel default).
//         setcps arrives in Phase 1.
//
// Architecture:
//   • One LayerGroup per distinct "s" value encountered in the pattern.
//     Each LayerGroup has a dedicated audio chain: player → [varispeed] → [EQ]
//     → [reverb] → mainMixer.
//   • On each Hap dispatch:
//       - sample name from hap.value["s"]
//       - MIDI note from hap.value["note"] (pitch-shifts via varispeed)
//       - gain  → player.volume at event time (per-event)
//       - room  → AVAudioUnitReverb wetDryMix (per-chain compromise — see doc)
//       - cutoff→ AVAudioUnitEQ frequency (per-chain compromise — see doc)
//
// Compromise (documented):
//   room/cutoff are applied per-chain at schedule time, not per-event.
//   Because AVAudioUnitReverb/EQ parameters are node-global (no per-buffer
//   scheduling API in AVAudioEngine), we set them at the moment of the first
//   hap in a burst. Events that alternate room/cutoff values would require
//   a separate chain per value — that is a Phase 1 enhancement.
//   gain IS per-event (player.volume is cheap to set per-buffer).
// ---------------------------------------------------------------------------

import AVFoundation

// MARK: - LayerGroup

private final class LayerGroup {
    let sampleName: String
    let player:    AVAudioPlayerNode
    let varispeed: AVAudioUnitVarispeed
    let eq:        AVAudioUnitEQ
    let reverb:    AVAudioUnitReverb

    init(sampleName: String,
         player:    AVAudioPlayerNode,
         varispeed: AVAudioUnitVarispeed,
         eq:        AVAudioUnitEQ,
         reverb:    AVAudioUnitReverb) {
        self.sampleName = sampleName
        self.player     = player
        self.varispeed  = varispeed
        self.eq         = eq
        self.reverb     = reverb
    }
}

// MARK: - PatternScheduler

public final class PatternScheduler {

    // MARK: - Constants

    /// Tempo: 0.5 cps → 1 cycle = 2 s. (Phase 1 will add setcps.)
    public private(set) var cycleSeconds: Double = 2.0
    private static let lookahead: Double = 0.4      // seconds
    private static let timerInterval: Double = 0.1  // seconds

    // MARK: - Dependencies

    private let audioEngine: AVAudioEngine
    private let sampleURLs: [String: URL]

    // MARK: - State

    private var pattern: ControlPattern?
    private var isRunning = false
    private var startHostTime: Double = 0
    private var scheduledUpTo: Double = 0
    private var timerSource: DispatchSourceTimer?
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var groups: [String: LayerGroup] = [:]
    private let poolQueue = DispatchQueue(label: "com.miniengine.scheduler", qos: .userInteractive)

    // MARK: - Init

    public init(audioEngine: AVAudioEngine, sampleURLs: [String: URL]) {
        self.audioEngine = audioEngine
        self.sampleURLs  = sampleURLs
    }

    // MARK: - Public API

    public func play(pattern: ControlPattern) {
        stop()
        self.pattern = pattern

        // Pre-scan first few cycles to find sample names for preloading
        let scanSpan = TimeSpan(Rational(0), Rational(4))
        let previewHaps = pattern.query(scanSpan)
        let sampleNames = Set(previewHaps.compactMap { $0.value["s"]?.stringValue })

        do {
            try preloadBuffers(for: sampleNames)
        } catch {
            print("[PatternScheduler] Buffer preload failed: \(error)")
            return
        }

        buildGroups(for: sampleNames)

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("[PatternScheduler] Could not start AVAudioEngine: \(error)")
                return
            }
        }

        for group in groups.values {
            if !group.player.isPlaying { group.player.play() }
        }

        startHostTime  = hostTimeNow()
        scheduledUpTo  = startHostTime
        isRunning      = true

        let src = DispatchSource.makeTimerSource(queue: poolQueue)
        src.schedule(
            deadline: .now(),
            repeating: .milliseconds(Int(PatternScheduler.timerInterval * 1000))
        )
        src.setEventHandler { [weak self] in self?.tick() }
        src.resume()
        timerSource = src
    }

    public func stop() {
        isRunning = false
        timerSource?.cancel()
        timerSource = nil

        for group in groups.values {
            group.player.stop()
            audioEngine.detach(group.player)
            audioEngine.detach(group.varispeed)
            audioEngine.detach(group.eq)
            audioEngine.detach(group.reverb)
        }
        groups = [:]

        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    // MARK: - Tick

    private func tick() {
        guard isRunning, let pattern = pattern else { return }

        let now     = hostTimeNow()
        let horizon = now + PatternScheduler.lookahead

        scheduleWindow(pattern: pattern, from: scheduledUpTo, to: horizon)
        scheduledUpTo = horizon
    }

    // MARK: - Event scheduling

    private func scheduleWindow(pattern: ControlPattern, from windowStart: Double, to windowEnd: Double) {
        let elapsed0 = windowStart - startHostTime
        let elapsed1 = windowEnd   - startHostTime

        // Convert to cycle time
        let cycleBegin = Rational(approximating: elapsed0 / cycleSeconds)
        let cycleEnd   = Rational(approximating: elapsed1 / cycleSeconds)

        let querySpan  = TimeSpan(cycleBegin, cycleEnd)
        let haps       = pattern.query(querySpan)

        for hap in haps {
            guard let sampleName = hap.value["s"]?.stringValue else { continue }

            // Event absolute time: onset of the hap's part in cycle units → seconds
            let hapCycleOnset = hap.part.begin
            let hapSeconds    = hapCycleOnset.toDouble * cycleSeconds
            let absoluteTime  = startHostTime + hapSeconds

            guard absoluteTime >= windowStart, absoluteTime < windowEnd else { continue }
            guard absoluteTime >= startHostTime else { continue }

            let midiNote  = hap.value["note"]?.doubleValue.map { Int($0) } ?? nil
            let gainValue = hap.value["gain"]?.doubleValue ?? 1.0
            let roomValue = hap.value["room"]?.doubleValue
            let cutoffValue = hap.value["cutoff"]?.doubleValue

            dispatchHap(
                sampleName:   sampleName,
                midiNote:     midiNote,
                gain:         gainValue,
                room:         roomValue,
                cutoff:       cutoffValue,
                absoluteTime: absoluteTime
            )
        }
    }

    private func dispatchHap(
        sampleName:   String,
        midiNote:     Int?,
        gain:         Double,
        room:         Double?,
        cutoff:       Double?,
        absoluteTime: Double
    ) {
        // Lazily create a group for this sample if needed
        if groups[sampleName] == nil {
            do {
                try preloadBuffers(for: [sampleName])
            } catch {
                print("[PatternScheduler] Cannot preload \(sampleName): \(error)")
                return
            }
            buildGroups(for: [sampleName])
            if let g = groups[sampleName], !g.player.isPlaying { g.player.play() }
        }

        guard let group = groups[sampleName],
              let buffer = buffers[sampleName],
              let avTime = avAudioTime(forHostSeconds: absoluteTime) else { return }

        // Pitch via varispeed: 2^((midi-60)/12); root = C4 = 60
        let rate: Float
        if let midi = midiNote {
            rate = Float(pow(2.0, Double(midi - 60) / 12.0))
        } else {
            rate = 1.0
        }

        // Apply per-event gain
        group.player.volume = Float(gain)

        // Apply per-chain room/cutoff (compromise: see doc above)
        if let r = room {
            group.reverb.wetDryMix = Float(r * 100)
        }
        if let c = cutoff {
            group.eq.bands[0].frequency = Float(c)
            group.eq.bands[0].bypass    = false
        }

        group.varispeed.rate = rate
        group.player.scheduleBuffer(buffer, at: avTime, options: [], completionHandler: nil)
    }

    // MARK: - Group construction

    private func buildGroups(for sampleNames: Set<String>) {
        let mainMixer = audioEngine.mainMixerNode

        for name in sampleNames {
            if groups[name] != nil { continue }

            let player    = AVAudioPlayerNode()
            let varispeed = AVAudioUnitVarispeed()
            let eq        = AVAudioUnitEQ(numberOfBands: 1)
            let reverb    = AVAudioUnitReverb()

            // Configure EQ as low-pass, bypassed by default
            let band = eq.bands[0]
            band.filterType = .lowPass
            band.frequency  = 20_000
            band.bypass     = true

            // Configure reverb with mediumHall preset (neutral, ~1.5s decay)
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 0

            audioEngine.attach(player)
            audioEngine.attach(varispeed)
            audioEngine.attach(eq)
            audioEngine.attach(reverb)

            // Chain: player → varispeed → eq → reverb → mainMixer
            audioEngine.connect(player,    to: varispeed, format: nil)
            audioEngine.connect(varispeed, to: eq,        format: nil)
            audioEngine.connect(eq,        to: reverb,    format: nil)
            audioEngine.connect(reverb,    to: mainMixer, format: nil)

            let group = LayerGroup(
                sampleName: name,
                player:     player,
                varispeed:  varispeed,
                eq:         eq,
                reverb:     reverb
            )
            groups[name] = group

            print("[PatternScheduler] Built chain for sample: \(name)")
        }
    }

    // MARK: - Buffer loading

    private func preloadBuffers(for names: Set<String>) throws {
        for name in names {
            if buffers[name] != nil { continue }
            guard let url = sampleURLs[name] else {
                print("[PatternScheduler] No URL for sample: \(name)")
                continue
            }
            let file = try AVAudioFile(forReading: url)
            guard let buf = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { continue }
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
        let ns   = seconds * 1_000_000_000.0
        let ticks = UInt64(ns) * UInt64(info.denom) / UInt64(info.numer)
        return AVAudioTime(hostTime: ticks)
    }
}
