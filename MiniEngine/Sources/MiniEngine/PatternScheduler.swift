// ---------------------------------------------------------------------------
// PatternScheduler — queries a ControlPattern cycle-by-cycle and dispatches
// each Hap to AVAudioEngine.
//
// Tempo: 0.5 cps → 1 cycle = 2 seconds (Strudel default).
//
// Architecture:
//   • Sample layers: one LayerGroup per distinct sample name.
//     Chain: player → varispeed → EQ(lpf) → reverb → delay → distortion → vowelEQ → panner → mainMixer
//   • Synth layers (Fase 3/4): one SynthLayer per distinct synth name
//     (sawtooth, square, sine, triangle).
//     Chain: AVAudioSourceNode → EQ(lpf+hpf) → reverb → delay → distortion → vowelEQ → panner → mainMixer
//     The AVAudioSourceNode mixes a pool of SynthVoice objects (polyBLEP oscillators
//     + ADSR envelope). Voice pool size = 8 (documented default).
//
// Fase 4 additions:
//   • shape/distort: AVAudioUnitDistortion in chain, wet=0 (neutral) until called.
//       shape: preset .softDistortion (gentle overdrive). x → wetDryMix (x*100).
//       distort: same preset at higher gain (distort maps to same preset but with
//         output gain boosted by wetDryMix). Documented approximation.
//   • vowel: AVAudioUnitEQ with 3 bandpass bands for F1/F2/F3 formants.
//       Bypassed by default; enabled and reconfigured per vowel event.
//   • crush (samples): AVAudioPCMBuffer is quantised per event before scheduling.
//   • crush (synths): applied inside render block per voice.
//   • chop/striate: begin/end fields → scheduleSegment with frame offset/length.
//
// Synth dispatch:
//   • hap.value["synth"] present → route to SynthLayer (no sample lookup needed).
//   • MIDI note from hap.value["note"]; default = synthDefaultMIDI (MIDI 48 = C3)
//     if no note field present.
//   • Duration: (hap.whole.end − hap.whole.begin) × cycleSeconds (sustain window).
//     Release appended after; total voice length = duration + release.
//
// speed():
//   • For sample layers: multiplied with the note-based varispeed rate.
//   • For synth layers: not applicable (frequency is computed from MIDI directly).
//     Documented: speed() is a sample-only parameter for synths.
//
// Filter parameters (per-chain compromise — same as Fase 1):
//   lpf/hpf/resonance are set at dispatch time on the SynthLayer's EQ node.
//   They are not per-event but are updated each time a hap fires for that layer.
// ---------------------------------------------------------------------------

import AVFoundation

// MARK: - Vowel formant table
// Standard acoustic formant frequencies (F1/F2/F3) for English vowels.
// Source: public acoustic phonetics tables (e.g. Peterson & Barney 1952,
//         widely reproduced in textbooks and Wikipedia).
// Approximate average male/female midpoint values used; Q=3 for all bands.

private let vowelFormants: [String: (f1: Float, f2: Float, f3: Float)] = [
    "a": (730,  1090, 2440),  // /ɑ/ as in "father"
    "e": (530,  1840, 2480),  // /ɛ/ as in "bed"
    "i": (390,  1990, 2550),  // /iː/ as in "see"
    "o": (570,   840, 2410),  // /ɔ/ as in "thought"
    "u": (440,  1020, 2240),  // /uː/ as in "food"
]

private let vowelFormantGainDB: Float  = 6.0   // bandpass band gain in dB
private let vowelFormantBandwidthHz: Float = 150.0  // bandwidth hint (AVAudioUnitEQ uses octaves)
// Convert bandwidth at fc to octaves: bw_octaves ≈ bw_hz / (fc * ln2)
// We use a fixed Q ≈ 3 (fc/bw ≈ 3) which corresponds to ~0.5 octave bandwidth.
// Documented: approximate mapping; exact response depends on AVAudioUnitEQ implementation.
private let vowelFormantBandwidthOctaves: Float = 0.5

// MARK: - LayerGroup

private final class LayerGroup {
    let sampleName: String
    let player:     AVAudioPlayerNode
    let varispeed:  AVAudioUnitVarispeed
    let eq:         AVAudioUnitEQ
    let reverb:     AVAudioUnitReverb
    let delay:      AVAudioUnitDelay
    let distortion: AVAudioUnitDistortion   // Fase 4: shape/distort (wet=0 default)
    let vowelEQ:    AVAudioUnitEQ           // Fase 4: formant filter (3 bands, bypassed default)
    let panner:     AVAudioMixerNode        // per-layer panner (pan property)

    init(sampleName: String,
         player:     AVAudioPlayerNode,
         varispeed:  AVAudioUnitVarispeed,
         eq:         AVAudioUnitEQ,
         reverb:     AVAudioUnitReverb,
         delay:      AVAudioUnitDelay,
         distortion: AVAudioUnitDistortion,
         vowelEQ:    AVAudioUnitEQ,
         panner:     AVAudioMixerNode) {
        self.sampleName = sampleName
        self.player     = player
        self.varispeed  = varispeed
        self.eq         = eq
        self.reverb     = reverb
        self.delay      = delay
        self.distortion = distortion
        self.vowelEQ    = vowelEQ
        self.panner     = panner
    }
}

// MARK: - Layer/name pair

/// Identifies a unique (layer-index, audio-name) pair used as a chain key.
/// Each stack branch gets its own AVAudio sub-graph, indexed by (layerIdx, name).
private struct LayerNamePair: Hashable {
    let layerIdx: Int
    let name: String
}

// MARK: - PatternScheduler

public final class PatternScheduler {

    // MARK: - Constants

    /// Tempo: cycles-per-second. Default 0.5 cps → 1 cycle = 2 s.
    /// Change via setcps() / setcpm() before or during playback.
    public private(set) var cps: Double = 0.5
    public var cycleSeconds: Double { 1.0 / cps }
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
    private var buffers: [String: AVAudioPCMBuffer] = [:]          // keyed by sample name (no duplication)
    private var groups: [String: LayerGroup] = [:]                  // keyed by "\(layerIdx)#\(sampleName)"
    private var synthLayers: [String: SynthLayer] = [:]             // keyed by "\(layerIdx)#\(synthName)"
    private let poolQueue = DispatchQueue(label: "com.miniengine.scheduler", qos: .userInteractive)

    // MARK: - Layer key helper

    /// Build the chain key for a sample/synth from the _layer control field (default 0).
    /// Format: "\(layerIndex)#\(name)".  This gives each stack branch its own
    /// effect chain (EQ, reverb, delay, panner) and voice pool while buffers
    /// (which are large) are still deduplicated by plain sample name.
    public static func layerKey(layerIdx: Int, name: String) -> String {
        "\(layerIdx)#\(name)"
    }

    // MARK: - Init

    public init(audioEngine: AVAudioEngine, sampleURLs: [String: URL]) {
        self.audioEngine = audioEngine
        self.sampleURLs  = sampleURLs
    }

    // MARK: - Tempo control

    /// Set tempo in cycles-per-second. Default is 0.5 (1 cycle = 2 seconds).
    public func setcps(_ value: Double) {
        cps = max(0.0001, value)
    }

    /// Set tempo in cycles-per-minute. Equivalent to setcps(value / 60).
    public func setcpm(_ value: Double) {
        setcps(value / 60.0)
    }

    // MARK: - Public API

    public func play(pattern: ControlPattern) {
        stop()
        self.pattern = pattern

        // Pre-scan first few cycles to find sample/synth names AND their layer indices.
        // Each unique (layerIdx, name) pair gets its own chain; buffers are still
        // deduplicated by plain sample name to avoid memory duplication.
        let scanSpan = TimeSpan(Rational(0), Rational(4))
        let previewHaps = pattern.query(scanSpan)

        // Collect (layerIdx, sName) pairs
        var samplePairs: Set<LayerNamePair> = []
        var synthPairs:  Set<LayerNamePair> = []
        var sampleNames: Set<String>        = []

        for hap in previewHaps {
            guard let sVal = hap.value["s"]?.stringValue else { continue }
            let bankName = hap.value["bank"]?.stringValue ?? ""
            let sName    = bankName.isEmpty ? sVal : "\(bankName)_\(sVal)"
            let layerIdx = Int(hap.value["_layer"]?.doubleValue ?? 0.0)
            let pair     = LayerNamePair(layerIdx: layerIdx, name: sName)
            if isSynthName(sName) {
                synthPairs.insert(pair)
            } else {
                samplePairs.insert(pair)
                sampleNames.insert(sName)
            }
        }

        do {
            try preloadBuffers(for: sampleNames)
        } catch {
            print("[PatternScheduler] Buffer preload failed: \(error)")
            return
        }

        buildGroups(for: samplePairs)
        buildSynthLayers(for: synthPairs)

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
            audioEngine.detach(group.delay)
            audioEngine.detach(group.distortion)
            audioEngine.detach(group.vowelEQ)
            audioEngine.detach(group.panner)
        }
        groups = [:]

        for layer in synthLayers.values {
            audioEngine.detach(layer.sourceNode)
            audioEngine.detach(layer.eq)
            audioEngine.detach(layer.reverb)
            audioEngine.detach(layer.delay)
            audioEngine.detach(layer.distortion)
            audioEngine.detach(layer.vowelEQ)
            audioEngine.detach(layer.panner)
        }
        synthLayers = [:]

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
            guard let sBase = hap.value["s"]?.stringValue else { continue }

            // Resolve bank: if "bank" field present, effective key = "bank_sampleName"
            let bankName = hap.value["bank"]?.stringValue ?? ""
            let sName = bankName.isEmpty ? sBase : "\(bankName)_\(sBase)"

            // Bug 1 fix: read _layer index (0 if not set) for per-branch chain isolation.
            let layerIdx = Int(hap.value["_layer"]?.doubleValue ?? 0.0)

            // Event absolute time: onset of the hap's part in cycle units → seconds
            let hapCycleOnset = hap.part.begin
            let hapSeconds    = hapCycleOnset.toDouble * cycleSeconds
            let absoluteTime  = startHostTime + hapSeconds

            guard absoluteTime >= windowStart, absoluteTime < windowEnd else { continue }
            guard absoluteTime >= startHostTime else { continue }

            let midiNote      = hap.value["note"]?.doubleValue
            let gainValue     = hap.value["gain"]?.doubleValue ?? 1.0
            let roomValue     = hap.value["room"]?.doubleValue
            let cutoffValue   = hap.value["cutoff"]?.doubleValue ?? hap.value["lpf"]?.doubleValue
            let hpfValue      = hap.value["hpf"]?.doubleValue
            let resonanceVal  = hap.value["resonance"]?.doubleValue
            let panValue      = hap.value["pan"]?.doubleValue
            let delayValue    = hap.value["delay"]?.doubleValue
            let delayTimeVal  = hap.value["delaytime"]?.doubleValue
            let delayFeedVal  = hap.value["delayfeedback"]?.doubleValue
            let speedValue    = hap.value["speed"]?.doubleValue
            let attackVal     = hap.value["attack"]?.doubleValue
            let decayVal      = hap.value["decay"]?.doubleValue
            let sustainVal    = hap.value["sustain"]?.doubleValue
            let releaseVal    = hap.value["release"]?.doubleValue
            // Fase 4 parameters
            let shapeVal      = hap.value["shape"]?.doubleValue
            let distortVal    = hap.value["distort"]?.doubleValue
            let crushVal      = hap.value["crush"]?.doubleValue
            let vowelVal      = hap.value["vowel"]?.stringValue
            let beginVal      = hap.value["begin"]?.doubleValue   // chop/striate sample begin (0..1)
            let endVal        = hap.value["end"]?.doubleValue     // chop/striate sample end (0..1)

            // Event duration in cycle units (for ADSR note duration)
            let hapDurationCycles = (hap.whole ?? hap.part).end.toDouble
                                  - (hap.whole ?? hap.part).begin.toDouble
            let hapDurationSec = hapDurationCycles * cycleSeconds

            if isSynthName(sName) {
                // ── Synth route ─────────────────────────────────────────────
                dispatchSynthHap(
                    synthName:    sName,
                    layerIdx:     layerIdx,
                    midiNote:     midiNote ?? Double(synthDefaultMIDI),
                    gain:         gainValue,
                    room:         roomValue,
                    lpf:          cutoffValue,
                    hpf:          hpfValue,
                    resonance:    resonanceVal,
                    pan:          panValue,
                    delay:        delayValue,
                    delaytime:    delayTimeVal,
                    delayfeedback: delayFeedVal,
                    attack:       attackVal   ?? ADSRDefaults.attack,
                    decay:        decayVal    ?? ADSRDefaults.decay,
                    sustain:      sustainVal  ?? ADSRDefaults.sustain,
                    release:      releaseVal  ?? ADSRDefaults.release,
                    durationSec:  hapDurationSec,
                    absoluteTime: absoluteTime,
                    shape:        shapeVal,
                    distort:      distortVal,
                    crush:        crushVal,
                    vowel:        vowelVal
                )
            } else {
                // ── Sample route ────────────────────────────────────────────
                // Detect explicit ADSR parameters (nil = use default/no-op)
                // If NONE of attack/decay/sustain/release are set by the user,
                // we skip envelope processing entirely (backward-compat: no change in sound).
                let hasExplicitADSR = attackVal != nil || decayVal != nil
                                   || sustainVal != nil || releaseVal != nil
                dispatchHap(
                    sampleName:    sName,
                    layerIdx:      layerIdx,
                    midiNote:      midiNote.map { Int($0) },
                    gain:          gainValue,
                    room:          roomValue,
                    cutoff:        cutoffValue,
                    pan:           panValue,
                    delay:         delayValue,
                    delaytime:     delayTimeVal,
                    delayfeedback: delayFeedVal,
                    speed:         speedValue,
                    absoluteTime:  absoluteTime,
                    shape:         shapeVal,
                    distort:       distortVal,
                    crush:         crushVal,
                    vowel:         vowelVal,
                    beginFrac:     beginVal,
                    endFrac:       endVal,
                    // ADSR for samples (only when explicitly set)
                    attack:        hasExplicitADSR ? (attackVal  ?? ADSRDefaults.attack)  : nil,
                    decay:         hasExplicitADSR ? (decayVal   ?? ADSRDefaults.decay)   : nil,
                    sustain:       hasExplicitADSR ? (sustainVal ?? ADSRDefaults.sustain) : nil,
                    release:       hasExplicitADSR ? (releaseVal ?? ADSRDefaults.release) : nil,
                    durationSec:   hasExplicitADSR ? hapDurationSec : nil
                )
            }
        }
    }

    private func dispatchHap(
        sampleName:    String,
        layerIdx:      Int,
        midiNote:      Int?,
        gain:          Double,
        room:          Double?,
        cutoff:        Double?,
        pan:           Double?,
        delay:         Double?,
        delaytime:     Double?,
        delayfeedback: Double?,
        speed:         Double?,
        absoluteTime:  Double,
        shape:         Double? = nil,
        distort:       Double? = nil,
        crush:         Double? = nil,
        vowel:         String? = nil,
        beginFrac:     Double? = nil,   // chop/striate: sample start 0..1
        endFrac:       Double? = nil,   // chop/striate: sample end 0..1
        // ADSR for samples — nil = no envelope (backward-compat, no change in sound)
        attack:        Double? = nil,
        decay:         Double? = nil,
        sustain:       Double? = nil,
        release:       Double? = nil,
        durationSec:   Double? = nil
    ) {
        // Bug 1 fix: chain key is layer-qualified; buffers are keyed by plain name.
        let chainKey = PatternScheduler.layerKey(layerIdx: layerIdx, name: sampleName)

        // Lazily create a group for this (layer, sample) pair if needed
        if groups[chainKey] == nil {
            do {
                try preloadBuffers(for: [sampleName])
            } catch {
                print("[PatternScheduler] Cannot preload \(sampleName): \(error)")
                return
            }
            buildGroups(for: [LayerNamePair(layerIdx: layerIdx, name: sampleName)])
            if let g = groups[chainKey], !g.player.isPlaying { g.player.play() }
        }

        guard let group = groups[chainKey],
              let sourceBuffer = buffers[sampleName],
              let avTime = avAudioTime(forHostSeconds: absoluteTime) else { return }

        // Pitch via varispeed: 2^((midi-60)/12); root = C4 = 60
        // speed() multiplies the rate multiplicatively (documented).
        let noteRate: Double
        if let midi = midiNote {
            noteRate = pow(2.0, Double(midi - 60) / 12.0)
        } else {
            noteRate = 1.0
        }
        let rate = Float(noteRate * (speed ?? 1.0))

        // Apply per-event gain
        group.player.volume = Float(gain)

        // Apply pan: Strudel 0..1 → AVAudioMixerNode.pan -1..1
        if let p = pan {
            let avPan = Float(p * 2.0 - 1.0)  // 0→-1, 0.5→0, 1→1
            group.panner.pan = avPan
        }

        // Apply per-chain room/cutoff (compromise: see doc above)
        if let r = room {
            group.reverb.wetDryMix = Float(r * 100)
        }
        if let c = cutoff {
            group.eq.bands[0].frequency = Float(c)
            group.eq.bands[0].bypass    = false
        }

        // Apply delay (wet mix 0..1 → wetDryMix 0..100).
        // Defaults if delay set but delaytime/delayfeedback not: 0.25s / 0.5 feedback.
        if let d = delay {
            group.delay.wetDryMix  = Float(d * 100)
            group.delay.delayTime  = delaytime ?? 0.25
            group.delay.feedback   = Float((delayfeedback ?? 0.5) * 100)
        }

        // Fase 4: shape / distort — AVAudioUnitDistortion wet mix
        // shape: gentle overdrive — softDistortion preset, x → wetDryMix (x*100)
        // distort: same preset at full wetDryMix → more extreme
        // Priority: distort overrides shape if both present.
        if let d = distort {
            group.distortion.wetDryMix = Float(d * 100)
        } else if let s = shape {
            group.distortion.wetDryMix = Float(s * 100)
        }

        // Fase 4: vowel formant filter
        if let v = vowel {
            applyVowelToEQ(group.vowelEQ, vowel: v)
        }

        // Fase 4: chop/striate — select sub-segment of buffer
        // beginFrac/endFrac are fractional positions 0..1 in the sample.
        // We create a sub-buffer view covering [beginFrac*frameLength, endFrac*frameLength).
        var scheduleBuffer = sourceBuffer
        if let bf = beginFrac, let ef = endFrac, ef > bf {
            let totalFrames = Int(sourceBuffer.frameLength)
            let startFrame  = max(0, min(totalFrames - 1, Int(bf * Double(totalFrames))))
            let endFrame    = max(startFrame + 1, min(totalFrames, Int(ef * Double(totalFrames))))
            let segFrames   = endFrame - startFrame
            if segFrames > 0, let segBuf = AVAudioPCMBuffer(
                pcmFormat: sourceBuffer.format,
                frameCapacity: AVAudioFrameCount(segFrames)
            ) {
                segBuf.frameLength = AVAudioFrameCount(segFrames)
                let channelCount = Int(sourceBuffer.format.channelCount)
                if let srcChannels = sourceBuffer.floatChannelData,
                   let dstChannels = segBuf.floatChannelData {
                    for ch in 0..<channelCount {
                        let src = srcChannels[ch] + startFrame
                        let dst = dstChannels[ch]
                        dst.assign(from: src, count: segFrames)
                    }
                }
                scheduleBuffer = segBuf
            }
        }

        // Fase 4: crush (samples) — quantise buffer before scheduling
        if let bits = crush {
            scheduleBuffer = bitcrushedBuffer(scheduleBuffer, bits: bits)
        }

        // Fase 5: ADSR envelope over sample buffer (only when explicitly requested).
        // If attack/decay/sustain/release are all nil, this block is skipped entirely
        // — no change in sound for patterns that don't use ADSR (backward-compat).
        // When set: applies an ADSR amplitude envelope to a copy of the buffer.
        //   Attack  phase: 0 → 1 over first (attack * sampleRate) frames
        //   Decay   phase: 1 → sustain over next (decay * sampleRate) frames
        //   Sustain phase: sustain level until (durationSec * sampleRate) frames
        //   Release phase: sustain → 0 over final (release * sampleRate) frames
        // Buffers shorter than the envelope are truncated gracefully.
        if let att = attack, let dec = decay, let sus = sustain, let rel = release {
            scheduleBuffer = adsrEnvelopeBuffer(
                scheduleBuffer,
                sampleRate: scheduleBuffer.format.sampleRate,
                attack: att, decay: dec, sustain: sus, release: rel,
                durationSec: durationSec ?? Double(scheduleBuffer.frameLength) / scheduleBuffer.format.sampleRate
            )
        }

        group.varispeed.rate = rate
        group.player.scheduleBuffer(scheduleBuffer, at: avTime, options: [], completionHandler: nil)
    }

    // MARK: - Synth dispatch

    private func dispatchSynthHap(
        synthName:    String,
        layerIdx:     Int,
        midiNote:     Double,
        gain:         Double,
        room:         Double?,
        lpf:          Double?,
        hpf:          Double?,
        resonance:    Double?,
        pan:          Double?,
        delay:        Double?,
        delaytime:    Double?,
        delayfeedback: Double?,
        attack:       Double,
        decay:        Double,
        sustain:      Double,
        release:      Double,
        durationSec:  Double,
        absoluteTime: Double,
        shape:        Double? = nil,
        distort:      Double? = nil,
        crush:        Double? = nil,
        vowel:        String? = nil
    ) {
        // Bug 1 fix: chain key is layer-qualified so each stack branch has its own
        // SynthLayer (own voice pool + own EQ/reverb/delay/panner chain).
        let chainKey = PatternScheduler.layerKey(layerIdx: layerIdx, name: synthName)

        // Lazily create a SynthLayer for this (layer, synth) pair
        if synthLayers[chainKey] == nil {
            buildSynthLayers(for: [LayerNamePair(layerIdx: layerIdx, name: synthName)])
        }
        guard let layer = synthLayers[chainKey] else { return }

        // Usar el rate de la CAPA (el que declara su sourceNode y usan sus voces),
        // no el del outputNode: si difieren, el pitch sale transpuesto (bug e5→606Hz).
        let sampleRate = layer.sampleRate
        let freq = synthFrequency(midi: midiNote)

        // Apply per-chain effects
        if let r = room { layer.applyRoom(r) }
        if let f = lpf  { layer.applyLPF(freq: f, resonance: resonance) }
        if let f = hpf  { layer.applyHPF(freq: f, resonance: resonance) }
        if let p = pan  { layer.applyPan(p) }
        if let d = delay {
            layer.applyDelay(wet: d, time: delaytime, feedback: delayfeedback)
        }

        // Fase 4: shape / distort
        if let d = distort { layer.applyDistortion(d) }
        else if let s = shape { layer.applyDistortion(s) }

        // Fase 4: vowel formant filter
        if let v = vowel { layer.applyVowel(v) }

        // Bug 2 fix: pass absoluteTime (host seconds) so the voice waits until
        // its exact scheduled frame before producing audio, eliminating the
        // up-to-lookahead (400ms) early onset that the old immediate-trigger had.
        // The render block derives the exact buffer frame from (absoluteTime - bufferStartSeconds).
        layer.scheduleNote(
            freq:             freq,
            gain:             gain,
            attack:           attack,
            decay:            decay,
            sustain:          sustain,
            release:          release,
            durationSec:      durationSec,
            sampleRate:       sampleRate > 0 ? sampleRate : 44100.0,
            startHostSeconds: absoluteTime,
            crushBits:        crush ?? 0.0
        )
    }

    // MARK: - Synth layer construction

    /// Build one SynthLayer per (layerIdx, synthName) pair.
    /// The chain key is "\(layerIdx)#\(synthName)" so each stack branch gets its
    /// own voice pool, EQ, reverb, delay and panner.
    private func buildSynthLayers(for pairs: Set<LayerNamePair>) {
        let mainMixer  = audioEngine.mainMixerNode
        let sampleRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = sampleRate > 0 ? sampleRate : 44100.0

        for pair in pairs {
            let chainKey = PatternScheduler.layerKey(layerIdx: pair.layerIdx, name: pair.name)
            if synthLayers[chainKey] != nil { continue }

            let layer = SynthLayer(synthName: pair.name, sampleRate: sr)

            audioEngine.attach(layer.sourceNode)
            audioEngine.attach(layer.eq)
            audioEngine.attach(layer.reverb)
            audioEngine.attach(layer.delay)
            audioEngine.attach(layer.distortion)
            audioEngine.attach(layer.vowelEQ)
            audioEngine.attach(layer.panner)

            // Chain: sourceNode → EQ(lpf+hpf) → reverb → delay → distortion → vowelEQ → panner → mainMixer
            audioEngine.connect(layer.sourceNode,  to: layer.eq,         format: nil)
            audioEngine.connect(layer.eq,          to: layer.reverb,     format: nil)
            audioEngine.connect(layer.reverb,      to: layer.delay,      format: nil)
            audioEngine.connect(layer.delay,       to: layer.distortion, format: nil)
            audioEngine.connect(layer.distortion,  to: layer.vowelEQ,    format: nil)
            audioEngine.connect(layer.vowelEQ,     to: layer.panner,     format: nil)
            audioEngine.connect(layer.panner,      to: mainMixer,        format: nil)

            synthLayers[chainKey] = layer
            print("[PatternScheduler] Built synth chain for: \(chainKey)")
        }
    }

    // MARK: - Group construction

    /// Build one LayerGroup per (layerIdx, sampleName) pair.
    /// The chain key is "\(layerIdx)#\(sampleName)" — each stack branch gets its own
    /// player/varispeed/EQ/reverb/delay/panner chain.
    /// Buffers are still keyed by plain sampleName (deduplication — no memory waste).
    private func buildGroups(for pairs: Set<LayerNamePair>) {
        let mainMixer = audioEngine.mainMixerNode

        for pair in pairs {
            let chainKey = PatternScheduler.layerKey(layerIdx: pair.layerIdx, name: pair.name)
            let name     = pair.name
            if groups[chainKey] != nil { continue }

            let player     = AVAudioPlayerNode()
            let varispeed  = AVAudioUnitVarispeed()
            let eq         = AVAudioUnitEQ(numberOfBands: 1)
            let reverb     = AVAudioUnitReverb()
            let delay      = AVAudioUnitDelay()
            let distortion = AVAudioUnitDistortion()
            let vowelEQ    = AVAudioUnitEQ(numberOfBands: 3)
            let panner     = AVAudioMixerNode()

            // Configure EQ as low-pass, bypassed by default.
            // .lowPass type has no resonance peak; bandwidth param is ignored.
            let band = eq.bands[0]
            band.filterType = .lowPass
            band.frequency  = 20_000
            band.bypass     = true

            // Configure reverb with mediumHall preset (neutral, ~1.5s decay)
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 0

            // Configure delay: off by default; sensible defaults ready to use
            delay.wetDryMix     = 0
            delay.delayTime     = 0.25
            delay.feedback      = 50
            delay.lowPassCutoff = 15_000

            // Fase 4: Configure distortion — SoftDistortion preset (gentle overdrive)
            // Preset documented: SoftDistortion is the gentlest AVAudioUnitDistortion preset.
            // Wet=0 (dry) until shape/distort is called.
            distortion.loadFactoryPreset(.multiDistortedFunk)
            distortion.preGain    = 0     // no pre-amp — let wetDryMix do the work
            distortion.wetDryMix  = 0     // fully dry by default

            // Fase 4: Configure vowel EQ — 3 bandpass bands (F1/F2/F3), all bypassed
            configureVowelEQBands(vowelEQ)

            // Panner: center by default
            panner.pan = 0

            audioEngine.attach(player)
            audioEngine.attach(varispeed)
            audioEngine.attach(eq)
            audioEngine.attach(reverb)
            audioEngine.attach(delay)
            audioEngine.attach(distortion)
            audioEngine.attach(vowelEQ)
            audioEngine.attach(panner)

            // Chain: player → varispeed → eq → reverb → delay → distortion → vowelEQ → panner → mainMixer
            // Formato explícito en el player: todos los buffers están normalizados
            // a canonicalFormat, y la conexión debe coincidir o scheduleBuffer lanza.
            audioEngine.connect(player,     to: varispeed,  format: Self.canonicalFormat)
            audioEngine.connect(varispeed,  to: eq,         format: nil)
            audioEngine.connect(eq,         to: reverb,     format: nil)
            audioEngine.connect(reverb,     to: delay,      format: nil)
            audioEngine.connect(delay,      to: distortion, format: nil)
            audioEngine.connect(distortion, to: vowelEQ,    format: nil)
            audioEngine.connect(vowelEQ,    to: panner,     format: nil)
            audioEngine.connect(panner,     to: mainMixer,  format: nil)

            let group = LayerGroup(
                sampleName: name,
                player:     player,
                varispeed:  varispeed,
                eq:         eq,
                reverb:     reverb,
                delay:      delay,
                distortion: distortion,
                vowelEQ:    vowelEQ,
                panner:     panner
            )
            groups[chainKey] = group

            print("[PatternScheduler] Built chain for sample: \(chainKey)")
        }
    }

    // MARK: - Vowel EQ helpers

    /// Configure the 3 EQ bands as bandpass filters, all bypassed initially.
    private func configureVowelEQBands(_ eq: AVAudioUnitEQ) {
        for i in 0..<3 {
            let b = eq.bands[i]
            b.filterType = .parametric   // parametric (bell) filter as bandpass approximation
            b.gain       = vowelFormantGainDB
            b.bandwidth  = vowelFormantBandwidthOctaves
            b.bypass     = true
        }
    }

    /// Apply vowel formant frequencies to an EQ node.
    private func applyVowelToEQ(_ eq: AVAudioUnitEQ, vowel: String) {
        let key = vowel.lowercased()
        guard let formants = vowelFormants[key] else { return }
        let freqs = [formants.f1, formants.f2, formants.f3]
        for i in 0..<3 {
            let b = eq.bands[i]
            b.frequency = freqs[i]
            b.bypass    = false
        }
    }

    // MARK: - Buffer loading

    /// Formato canónico de todos los buffers de sample. El banco mezcla formatos
    /// (tr909/bd estéreo 16-bit, tr909/hh mono 24-bit, tr808 mono...) y un
    /// AVAudioPlayerNode lanza NSException si el formato del buffer no coincide
    /// con el de su conexión — así que TODO se normaliza al cargar.
    static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

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
            buffers[name] = Self.normalizedBuffer(buf)
        }
    }

    /// Convierte cualquier buffer al formato canónico (float32 deinterleaved,
    /// estéreo, 44.1kHz). Mono se duplica a ambos canales (mapeo por defecto
    /// de AVAudioConverter). Devuelve el original si ya es canónico.
    static func normalizedBuffer(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let fmt = canonicalFormat
        let f = buf.format
        if f.channelCount == fmt.channelCount,
           f.sampleRate == fmt.sampleRate,
           f.commonFormat == .pcmFormatFloat32,
           !f.isInterleaved {
            return buf
        }
        guard let converter = AVAudioConverter(from: f, to: fmt) else { return buf }
        let ratio = fmt.sampleRate / f.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return buf }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buf
        }
        if status == .error {
            print("[PatternScheduler] normalizedBuffer conversion failed: \(err?.localizedDescription ?? "?")")
            return buf
        }
        return out
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
