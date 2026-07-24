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

// MARK: - OrbitBus (P0-4)

/// One orbit bus: a shared reverb + delay chain that feeds mainMixer.
/// All synth/sample layers on the same orbit number share this bus.
///
/// Architecture:
///   Layer panner → orbitGain → orbitReverb → orbitDelay → mainMixer
///
/// room/delay params are updated from the last event that fires on this orbit.
/// This is the documented compromise: see COMPATIBILITY.md P0-4.
/// The orbitGain node is public so it can be attenuated for duck (P1-5 prep).
///
/// Default orbit: 1 (Strudel public docs: "By default all patterns use orbit 1",
/// verified at strudel.cc/learn/effects). Patterns without .orbit() use orbit 1.
final class OrbitBus {
    let orbitIdx:  Int
    let gain:      AVAudioMixerNode     // entry point from all layers in this orbit; duck target (P1-5 prep)
    let reverb:    AVAudioUnitReverb    // room parameter
    let delay:     AVAudioUnitDelay     // delay wet/time/feedback

    init(orbitIdx: Int) {
        self.orbitIdx = orbitIdx
        self.gain  = AVAudioMixerNode()
        let rv = AVAudioUnitReverb()
        rv.loadFactoryPreset(.mediumHall)
        rv.wetDryMix = 0
        self.reverb = rv
        let dl = AVAudioUnitDelay()
        dl.wetDryMix     = 0
        dl.delayTime     = 0.25
        dl.feedback      = 50
        dl.lowPassCutoff = 15_000
        self.delay = dl
    }

    /// Update room wet mix (0..1 → 0..100 wetDryMix).
    func applyRoom(_ room: Double) {
        reverb.wetDryMix = Float(room * 100.0)
    }

    /// Update delay params.
    func applyDelay(wet: Double, time: Double?, feedback: Double?) {
        delay.wetDryMix = Float(wet * 100.0)
        if let t = time     { delay.delayTime = t }
        if let f = feedback { delay.feedback  = Float(f * 100.0) }
    }

    /// P1-8: size(x) — map continuous room size 0..1 to AVAudioUnitReverb preset.
    /// Strudel uses a continuous Freeverb-style algorithmic reverb; AVAudioUnitReverb
    /// uses impulse responses with discrete presets. This mapping gives a perceptually
    /// plausible "bigger room" progression. Documented approximation.
    ///   size < 0.3  → .smallRoom
    ///   size < 0.6  → .mediumHall (default)
    ///   size < 0.8  → .largeHall
    ///   size >= 0.8 → .cathedral
    func applySize(_ size: Double) {
        let preset: AVAudioUnitReverbPreset
        if size < 0.3      { preset = .smallRoom  }
        else if size < 0.6 { preset = .mediumHall }
        else if size < 0.8 { preset = .largeHall  }
        else               { preset = .cathedral   }
        reverb.loadFactoryPreset(preset)
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
    /// Optional remote bank manager. Set by MiniEngine.play() before calling play(pattern:).
    public var bankManager: SampleBankManager?

    // MARK: - State

    private var pattern: ControlPattern?
    private var isRunning = false
    private var startHostTime: Double = 0
    private var scheduledUpTo: Double = 0
    private var timerSource: DispatchSourceTimer?
    /// Buffer cache keyed by "sampleName:variationIndex" (e.g. "tabla:3").
    /// Bundle samples always stored at "name:0" for backward compat.
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var groups: [String: LayerGroup] = [:]                  // keyed by "\(layerIdx)#\(sampleName)"
    private var synthLayers: [String: SynthLayer] = [:]             // keyed by "\(layerIdx)#\(synthName)"
    private let poolQueue = DispatchQueue(label: "com.miniengine.scheduler", qos: .userInteractive)

    // P0-4: orbit buses keyed by orbit index (default orbit = 1 per Strudel docs).
    // Each orbit has a shared reverb+delay chain. Layers connect their panner to the
    // orbit gain node (instead of directly to mainMixer). room/delay on the orbit bus
    // are updated per-event (last event wins per orbit — documented compromise).
    private var orbitBuses: [Int: OrbitBus] = [:]

    /// Default orbit index — Strudel public docs: "By default all patterns use orbit 1".
    /// Verified at strudel.cc/learn/effects (orbit section).
    public static let defaultOrbit: Int = 1

    // MARK: - Layer key helper

    /// Build the chain key for a sample/synth from the _layer control field (default 0).
    /// Format: "\(layerIndex)#\(name)".  This gives each stack branch its own
    /// effect chain (EQ, reverb, delay, panner) and voice pool while buffers
    /// (which are large) are still deduplicated by plain sample name.
    public static func layerKey(layerIdx: Int, name: String) -> String {
        "\(layerIdx)#\(name)"
    }

    /// Nota base de repitch de los samples LOCALES bundleados que no siguen la
    /// convención C2 de los bancos remotos. bell.wav se sintetizó afinada a C4
    /// (MIDI 60) y el lado Strudel la registra con note-map { c4: [...] } —
    /// ambos motores deben transponer desde la misma referencia.
    public static let localNoteBases: [String: Int] = ["bell": 60]

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

        // Collect (layerIdx, sName) pairs + orbit assignments
        var samplePairs: Set<LayerNamePair> = []
        var synthPairs:  Set<LayerNamePair> = []
        var sampleNames: Set<String>        = []
        // Remote prefetch: (name, variationIndex) pairs for SampleBankManager
        var remoteNames: [(name: String, index: Int)] = []
        // P0-4: map each LayerNamePair to its orbit index (first-seen wins; default 1)
        var pairOrbit:   [LayerNamePair: Int] = [:]

        for hap in previewHaps {
            guard let sVal = hap.value["s"]?.stringValue else { continue }
            let bankName = hap.value["bank"]?.stringValue ?? ""
            let sName    = bankName.isEmpty ? sVal : "\(bankName)_\(sVal)"
            let layerIdx = Int(hap.value["_layer"]?.doubleValue ?? 0.0)
            let nIdx     = Int(hap.value["n"]?.doubleValue ?? 0)
            let pair     = LayerNamePair(layerIdx: layerIdx, name: sName)
            // orbit field: default = PatternScheduler.defaultOrbit (1)
            let orbitIdx = Int(hap.value["orbit"]?.doubleValue ?? Double(PatternScheduler.defaultOrbit))
            if pairOrbit[pair] == nil { pairOrbit[pair] = orbitIdx }
            if isSynthName(sName) {
                synthPairs.insert(pair)
            } else {
                samplePairs.insert(pair)
                sampleNames.insert(sName)
                remoteNames.append((name: sName, index: nIdx))
            }
        }

        // Prefetch remoto con espera acotada: los cache-hits de disco quedan
        // listos antes del primer ciclo; los misses de red siguen async y sus
        // eventos se saltan hasta que llegan (timeout corto: nunca bloquea).
        if let bm = bankManager {
            bm.prefetchAndWait(names: remoteNames, timeout: 0.5)
        }

        // Build orbit buses first (before groups/layers so connections work)
        let neededOrbits = Set(pairOrbit.values)
        for orbitIdx in neededOrbits { _ = buildOrbitBus(orbitIdx: orbitIdx) }
        // Ensure default orbit always exists
        _ = buildOrbitBus(orbitIdx: PatternScheduler.defaultOrbit)

        do {
            try preloadBuffers(for: sampleNames)
        } catch {
            print("[PatternScheduler] Buffer preload failed: \(error)")
            return
        }

        buildGroups(for: samplePairs, pairOrbit: pairOrbit)
        buildSynthLayers(for: synthPairs, pairOrbit: pairOrbit)

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

        // P0-4: detach and remove orbit buses
        for bus in orbitBuses.values {
            audioEngine.detach(bus.gain)
            audioEngine.detach(bus.reverb)
            audioEngine.detach(bus.delay)
        }
        orbitBuses = [:]

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

        // Fase 1: extracción de parámetros compartida (misma lógica para el backend
        // JUCE). PatternScheduler mantiene su despacho AVAudio; solo delega el
        // parsing de campos del hap al extractor neutral.
        let events = PatternEventExtractor.events(
            haps:          haps,
            cycleSeconds:  cycleSeconds,
            startHostTime: startHostTime,
            windowStart:   windowStart,
            windowEnd:     windowEnd,
            defaultOrbit:  PatternScheduler.defaultOrbit
        )

        for ev in events {
            dispatch(ev)
        }
    }

    /// Traduce un ScheduledEvent neutral a la cadena AVAudio (orbit FX + duck +
    /// dispatchSynthHap/dispatchHap). Extraído de scheduleWindow en Fase 1 para
    /// que el backend JUCE reutilice el mismo evento sin duplicar la extracción.
    private func dispatch(_ ev: ScheduledEvent) {
        // P0-4: update orbit bus room/delay with this event's values (last wins per orbit).
        let orbitBus = buildOrbitBus(orbitIdx: ev.orbit)
        if let r = ev.room { orbitBus.applyRoom(r) }
        if let s = ev.size { orbitBus.applySize(s) }    // P1-8: size → reverb preset
        if let d = ev.delay {
            orbitBus.applyDelay(wet: d, time: ev.delaytime, feedback: ev.delayfeedback)
        }
        // P1-5: duck sidechain — attenuate target orbit bus gain at this event onset.
        if let dOrbit = ev.duckOrbit {
            let targetBus = buildOrbitBus(orbitIdx: Int(dOrbit))
            scheduleDuck(on: targetBus, depth: ev.duckDepth, attackSec: ev.duckAttack,
                         atHostSeconds: ev.absoluteTime)
        }

        // P3: gain efectivo = gain × velocity (velocity=1.0 por defecto = sin cambio).
        let effectiveGain = ev.gain * ev.velocity

        if ev.isSynth {
            dispatchSynthHap(
                synthName:    ev.sName,
                layerIdx:     ev.layerIdx,
                midiNote:     ev.midiNote ?? Double(synthDefaultMIDI),
                gain:         effectiveGain,
                lpf:          ev.cutoff,
                hpf:          ev.hpf,
                resonance:    ev.resonance,
                pan:          ev.pan,
                attack:       ev.attack   ?? ADSRDefaults.attack,
                decay:        ev.decay    ?? ADSRDefaults.decay,
                sustain:      ev.sustain  ?? ADSRDefaults.sustain,
                release:      ev.release  ?? ADSRDefaults.release,
                durationSec:  ev.durationSec,
                absoluteTime: ev.absoluteTime,
                shape:        ev.shape,
                distort:      ev.distort,
                crush:        ev.crush,
                vowel:        ev.vowel,
                lpenv:        ev.lpenv,
                hpenv:        ev.hpenv,
                postgain:     ev.postgain
            )
        } else {
            // If NONE of attack/decay/sustain/release are set, skip envelope
            // processing entirely (backward-compat: no change in sound).
            let hasADSR = ev.hasExplicitADSR
            dispatchHap(
                sampleName:    ev.sName,
                layerIdx:      ev.layerIdx,
                variationIdx:  ev.variationIdx,
                midiNote:      ev.midiNote.map { Int($0) },
                gain:          effectiveGain,
                room:          ev.room,
                cutoff:        ev.cutoff,
                hpf:           ev.hpf,             // P0-3: per-event HPF
                resonance:     ev.resonance,        // P0-3: per-event resonance Q
                pan:           ev.pan,
                delay:         ev.delay,
                delaytime:     ev.delaytime,
                delayfeedback: ev.delayfeedback,
                speed:         ev.speed,
                absoluteTime:  ev.absoluteTime,
                shape:         ev.shape,
                distort:       ev.distort,
                crush:         ev.crush,
                vowel:         ev.vowel,
                beginFrac:     ev.begin,
                endFrac:       ev.end,
                postgain:      ev.postgain,
                // ADSR for samples (only when explicitly set)
                attack:        hasADSR ? (ev.attack  ?? ADSRDefaults.attack)  : nil,
                decay:         hasADSR ? (ev.decay   ?? ADSRDefaults.decay)   : nil,
                sustain:       hasADSR ? (ev.sustain ?? ADSRDefaults.sustain) : nil,
                release:       hasADSR ? (ev.release ?? ADSRDefaults.release) : nil,
                durationSec:   hasADSR ? ev.durationSec : nil
            )
        }
    }

    private func dispatchHap(
        sampleName:    String,
        layerIdx:      Int,
        variationIdx:  Int     = 0,
        midiNote:      Int?,
        gain:          Double,
        room:          Double?,
        cutoff:        Double?,
        hpf:           Double? = nil,        // P0-3: per-event HPF for samples
        resonance:     Double? = nil,        // P0-3: per-event resonance Q for samples
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
        postgain:      Double  = 1.0,   // P1-8: post-effects gain multiplier
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
              let avTime = avAudioTime(forHostSeconds: absoluteTime) else { return }

        // Resolve source buffer: prefer remote bank (with :n variation), fall back to local bundle.
        // Buffer key: "sampleName:variationIndex" for remote; "sampleName:0" for bundle samples.
        let sourceBuffer: AVAudioPCMBuffer
        let repitchBase: Int
        if let bm = bankManager,
           let remoteBuf = bm.buffer(forName: sampleName, index: variationIdx) {
            sourceBuffer = remoteBuf
            repitchBase = 36   // arrays planos remotos: base C2 (convención Strudel)
        } else if let bm = bankManager,
                  bm.variationCount(forName: sampleName) > 0 {
            // Remote bank knows this sample but buffer not ready yet — skip event, log once
            print("[PatternScheduler] Remote sample not ready: \(sampleName):\(variationIdx) — skipping event")
            return
        } else {
            // Los samples locales generados por el proyecto tienen su propia nota
            // base (bell.wav está grabada en C4=60 y el lado Strudel la registra
            // con note-map { c4: [...] }); usar 36 aquí rompería el A/B del
            // código semilla (bell sonaría 2 octavas arriba solo en este motor).
            repitchBase = PatternScheduler.localNoteBases[sampleName] ?? 36
            // Fall back to bundle-bundled local sample (variation 0 only)
            let bufKey = "\(sampleName):0"
            guard let localBuf = buffers[bufKey] else { return }
            sourceBuffer = localBuf
        }

        // Pitch via varispeed. Base por origen del sample:
        //   • Bancos remotos de array plano: C2 = MIDI 36 (comportamiento observado
        //     de Strudel con dirt-samples y documentado en strudel.cc/learn/samples).
        //   • Samples locales: su nota base real (bell = C4, ver localNoteBases).
        // Sin campo note → rate 1.0 (sin repitch).
        let noteRate: Double
        if let midi = midiNote {
            noteRate = pow(2.0, Double(midi - repitchBase) / 12.0)
        } else {
            noteRate = 1.0
        }
        let rate = Float(noteRate * (speed ?? 1.0))

        // Apply per-event gain
        // P1-8: postgain applied multiplicatively with gain (both pre-orbit-bus).
        // For samples, gain and postgain are equivalent in signal position (documented compromise).
        group.player.volume = Float(gain * postgain)

        // Apply pan: Strudel 0..1 → AVAudioMixerNode.pan -1..1
        if let p = pan {
            let avPan = Float(p * 2.0 - 1.0)  // 0→-1, 0.5→0, 1→1
            group.panner.pan = avPan
        }

        // P0-4: room/delay are now on the orbit bus (applied in scheduleWindow before this call).
        // The per-layer reverb/delay nodes are not connected to the graph.
        // Nothing to apply here for room or delay.
        // P0-3: lpf/cutoff and hpf for samples are applied as buffer preprocessing below
        // (see biquad buffer processing section). The EQ node (group.eq) remains in the
        // graph but bypassed (AVAudioUnitEQ with band.bypass=true) — no filtering effect.

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

        // P0-3: per-event lpf/hpf biquad on sample buffer.
        // Applied as buffer preprocessing (same pattern as crush). Params are constant
        // for the entire buffer (event-level, not per-sample), which is correct and clean.
        // room/delay are NOT applied here — they are orbit-bus effects (see P0-4).
        // shape/vowel are still per-chain on the LayerGroup (last event wins).
        let q = resonance ?? 0.707
        if let fc = cutoff {
            scheduleBuffer = lpfBuffer(scheduleBuffer, cutoffHz: fc, q: q)
        }
        if let fc = hpf {
            // HPF: same biquad approach using hpfBuffer (reuse lpfBuffer with HPF coefs)
            scheduleBuffer = hpfBufferApply(scheduleBuffer, cutoffHz: fc, q: q)
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

    /// Dispatch a synth hap to the appropriate SynthLayer.
    /// P0-3: lpf/hpf/resonance are per-event (passed to per-voice biquad).
    /// P0-4: room/delay are NOT parameters here — they are applied to the orbit bus
    ///       in scheduleWindow() before calling this function.
    private func dispatchSynthHap(
        synthName:    String,
        layerIdx:     Int,
        midiNote:     Double,
        gain:         Double,
        lpf:          Double?,
        hpf:          Double?,
        resonance:    Double?,
        pan:          Double?,
        attack:       Double,
        decay:        Double,
        sustain:      Double,
        release:      Double,
        durationSec:  Double,
        absoluteTime: Double,
        shape:        Double? = nil,
        distort:      Double? = nil,
        crush:        Double? = nil,
        vowel:        String? = nil,
        lpenv:        Double  = 0.0,   // P1-6: filter envelope modulation (octaves)
        hpenv:        Double  = 0.0,
        postgain:     Double  = 1.0    // P1-8: post-effects gain multiplier
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

        // P0-3: lpf/hpf/resonance are now per-event (per-voice biquad inside SynthVoice).
        // We do NOT call layer.applyLPF/applyHPF any more — those set the AVAudioUnitEQ
        // which is now permanently bypassed. Instead we pass the values directly to
        // scheduleNote() → voice.trigger() so each voice has its own filter state.
        // room/delay remain per-orbit (applied to the orbit bus, not here).
        // pan is still per-event (AVAudioMixerNode, the last event wins per layer —
        // this is acceptable since pan is set before scheduleBuffer for samples).
        if let p = pan  { layer.applyPan(p) }

        // Fase 4: shape / distort (per-chain, last event wins)
        if let d = distort { layer.applyDistortion(d) }
        else if let s = shape { layer.applyDistortion(s) }

        // Fase 4: vowel formant filter (per-chain, last event wins)
        if let v = vowel { layer.applyVowel(v) }

        // Bug 2 fix: pass absoluteTime (host seconds) so the voice waits until
        // its exact scheduled frame before producing audio, eliminating the
        // up-to-lookahead (400ms) early onset that the old immediate-trigger had.
        // The render block derives the exact buffer frame from (absoluteTime - bufferStartSeconds).
        // P0-3: pass lpf/hpf/resonance per event so each voice has independent filter state.
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
            crushBits:        crush ?? 0.0,
            lpfHz:            lpf,
            hpfHz:            hpf,
            resonanceQ:       resonance,
            lpenvOct:         lpenv,
            hpenvOct:         hpenv,
            postgainMult:     postgain
        )
    }

    // MARK: - Synth layer construction

    /// Build one SynthLayer per (layerIdx, synthName) pair.
    /// The chain key is "\(layerIdx)#\(synthName)" so each stack branch gets its
    /// own voice pool, EQ, distortion, vowelEQ and panner.
    /// P0-4: panner connects to orbit gain node (not directly to mainMixer).
    ///       room/delay are now on the orbit bus; SynthLayer.reverb/delay are not connected.
    private func buildSynthLayers(for pairs: Set<LayerNamePair>, pairOrbit: [LayerNamePair: Int] = [:]) {
        let sampleRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = sampleRate > 0 ? sampleRate : 44100.0

        for pair in pairs {
            let chainKey = PatternScheduler.layerKey(layerIdx: pair.layerIdx, name: pair.name)
            if synthLayers[chainKey] != nil { continue }

            let layer = SynthLayer(synthName: pair.name, sampleRate: sr)

            audioEngine.attach(layer.sourceNode)
            audioEngine.attach(layer.eq)
            // P0-4: do not attach layer.reverb or layer.delay — they are on the orbit bus.
            audioEngine.attach(layer.distortion)
            audioEngine.attach(layer.vowelEQ)
            audioEngine.attach(layer.panner)

            // Chain: sourceNode → EQ(bypass, P0-3) → distortion → vowelEQ → panner → orbitBus.gain
            // The EQ node is permanently bypassed (P0-3); it acts as a transparent pass-through.
            // room/delay are on the orbit bus shared by all layers on the same orbit.
            audioEngine.connect(layer.sourceNode,  to: layer.eq,         format: nil)
            audioEngine.connect(layer.eq,          to: layer.distortion, format: nil)
            audioEngine.connect(layer.distortion,  to: layer.vowelEQ,    format: nil)
            audioEngine.connect(layer.vowelEQ,     to: layer.panner,     format: nil)
            let orbitIdx = pairOrbit[pair] ?? PatternScheduler.defaultOrbit
            let orbitBus = buildOrbitBus(orbitIdx: orbitIdx)
            audioEngine.connect(layer.panner, to: orbitBus.gain, format: nil)

            synthLayers[chainKey] = layer
            print("[PatternScheduler] Built synth chain for: \(chainKey) → orbit \(orbitIdx)")
        }
    }

    // MARK: - Orbit bus construction (P0-4)

    /// Get or create the orbit bus for a given orbit index.
    /// Called from buildGroups/buildSynthLayers at play() time.
    private func buildOrbitBus(orbitIdx: Int) -> OrbitBus {
        if let existing = orbitBuses[orbitIdx] { return existing }
        let mainMixer = audioEngine.mainMixerNode
        let bus = OrbitBus(orbitIdx: orbitIdx)
        audioEngine.attach(bus.gain)
        audioEngine.attach(bus.reverb)
        audioEngine.attach(bus.delay)
        // Chain: orbit gain → orbit reverb → orbit delay → mainMixer
        audioEngine.connect(bus.gain,   to: bus.reverb,   format: nil)
        audioEngine.connect(bus.reverb, to: bus.delay,    format: nil)
        audioEngine.connect(bus.delay,  to: mainMixer,    format: nil)
        orbitBuses[orbitIdx] = bus
        print("[PatternScheduler] Built orbit bus: \(orbitIdx)")
        return bus
    }

    // MARK: - Group construction

    /// Build one LayerGroup per (layerIdx, sampleName) pair.
    /// The chain key is "\(layerIdx)#\(sampleName)" — each stack branch gets its own
    /// player/varispeed/EQ/reverb/delay/panner chain.
    /// Buffers are still keyed by plain sampleName (deduplication — no memory waste).
    /// P0-4: pairOrbit maps each pair to its orbit index; panner connects to orbit gain node.
    private func buildGroups(for pairs: Set<LayerNamePair>, pairOrbit: [LayerNamePair: Int] = [:]) {
        _ = audioEngine.mainMixerNode   // mainMixer now accessed via buildOrbitBus; kept here for clarity

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
            // P0-3: the EQ node is now a transparent pass-through (bands bypassed).
            // Lowpass/highpass filtering for samples is done per-event as buffer preprocessing.
            audioEngine.connect(eq,         to: distortion, format: nil)
            audioEngine.connect(distortion, to: vowelEQ,    format: nil)
            audioEngine.connect(vowelEQ,    to: panner,     format: nil)
            // P0-4: connect panner to orbit gain node (not directly to mainMixer).
            // room/delay are now on the orbit bus. The old per-layer reverb/delay nodes
            // are removed from the chain; reverb and delay are AVAudioUnit vars on LayerGroup
            // but not connected (kept for API compatibility — their wetDryMix stays 0).
            let orbitIdx = pairOrbit[pair] ?? PatternScheduler.defaultOrbit
            let orbitBus = buildOrbitBus(orbitIdx: orbitIdx)
            audioEngine.connect(panner, to: orbitBus.gain, format: nil)

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
            // Buffer key for local/bundle samples is "name:0" (variation 0).
            let bufKey = "\(name):0"
            if buffers[bufKey] != nil { continue }
            guard let url = sampleURLs[name] else {
                // Not in local bundle — may be a remote sample; that's OK.
                if bankManager == nil || bankManager?.variationCount(forName: name) == 0 {
                    print("[PatternScheduler] No URL for sample: \(name)")
                }
                continue
            }
            let file = try AVAudioFile(forReading: url)
            guard let buf = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { continue }
            try file.read(into: buf)
            buffers[bufKey] = Self.normalizedBuffer(buf)
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

    // MARK: - P1-5: Duck sidechain

    /// Schedule a gain-duck ramp on the target orbit bus.
    ///
    /// At `atHostSeconds` the orbit bus gain drops instantly to (1 - depth).
    /// Then it recovers linearly to 1.0 over `attackSec` seconds.
    ///
    /// Implementation: the ramp is driven by the poolQueue timer via a series of
    /// DispatchQueue.asyncAfter calls scheduled at 10ms intervals.
    /// Step resolution: 10ms (100 steps/sec). Documented approximation.
    ///
    /// Parameters:
    ///   targetBus:     the orbit bus whose gain node is attenuated.
    ///   depth:         attenuation depth 0..1. 1 = full silence, 0 = no duck.
    ///   attackSec:     recovery time in seconds (time to return from duck to 1.0).
    ///   atHostSeconds: absolute host-clock time (same as hostTimeNow) for the duck onset.
    private func scheduleDuck(on targetBus: OrbitBus, depth: Double, attackSec: Double,
                               atHostSeconds: Double) {
        let depthClamped  = max(0.0, min(1.0, depth))
        let attackClamped = max(0.01, attackSec)
        let startVolume   = 1.0 - depthClamped   // volume immediately after duck
        let stepIntervalMs = 10.0                 // 10ms resolution (documented)
        let stepIntervalSec = stepIntervalMs / 1000.0
        let nSteps = max(1, Int(ceil(attackClamped / stepIntervalSec)))
        let volumeStep = (1.0 - startVolume) / Double(nSteps)  // volume increment per step

        // Compute delay from now to the duck onset
        let nowSec = hostTimeNow()
        let onsetDelay = max(0.0, atHostSeconds - nowSec)

        // Schedule the initial drop
        poolQueue.asyncAfter(deadline: .now() + onsetDelay) { [weak targetBus] in
            targetBus?.gain.outputVolume = Float(startVolume)
        }

        // Schedule recovery steps
        for step in 1...nSteps {
            let stepDelay = onsetDelay + Double(step) * stepIntervalSec
            let stepVolume = min(1.0, startVolume + volumeStep * Double(step))
            poolQueue.asyncAfter(deadline: .now() + stepDelay) { [weak targetBus] in
                targetBus?.gain.outputVolume = Float(stepVolume)
            }
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
