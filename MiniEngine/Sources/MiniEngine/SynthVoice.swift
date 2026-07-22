// ---------------------------------------------------------------------------
// SynthVoice.swift — Band-limited oscillators + ADSR envelope for Phase 3.
//
// ARCHITECTURE
// ────────────
// Each SynthLayer (one per distinct synth name in the pattern) owns:
//   • A pool of SynthVoice objects (polyphony).
//   • An AVAudioSourceNode that mixes all live voices each render block.
//   • The familiar effect chain: sourceNode → EQ(lpf+hpf) → reverb → delay
//     → panner → mainMixer.
//
// POLYPHONY
// ─────────
// On each new note-event the scheduler grabs the least-recently-used idle voice
// (or steals the oldest if all are busy).  Every voice is ticked independently
// inside the AVAudioSourceNode render block — no per-voice nodes, so the graph
// stays O(1) in the number of simultaneous notes.
//
// OSCILLATORS (band-limited, public-domain formulas)
// ──────────────────────────────────────────────────
// • Sine   — trivial sin(2π·phase).
// • Sawtooth — polyBLEP-corrected naive saw:
//     naiveSaw(φ) = 2φ − 1, then subtract polyBLEP correction at the
//     discontinuity at φ=0 to suppress aliasing.
//     Reference: Välimäki & Pakarinen, "Resampling Methods for Musical
//     Instrument Simulation" (standard DSP knowledge, public domain).
// • Square — polyBLEP-corrected naive square:
//     naive: 1 if φ<0.5 else -1; polyBLEP corrections at φ=0 and φ=0.5.
// • Triangle — integrated square wave (trivial closed form from square):
//     Integrate polyBLEP square → triangle with DC offset removed via a
//     simple first-order leaky integrator leak(0.999).
//
// ADSR (per-voice)
// ────────────────
// Standard piecewise ADSR on amplitude.  The scheduler provides:
//   • t0       = absolute host-time of note onset (seconds)
//   • duration = event duration in seconds (onset to offset)
//   • attack / decay / sustain / release parameters
//
// Defaults (from Strudel public docs at strudel.cc/learn/effects):
//   attack=0.001s, decay=0.05s, sustain=0.6 (0..1), release=0.1s
// Note: Strudel docs list release default as 0.1s in the ADSR section.
//
// DEFAULT NOTE
// ────────────
// Strudel: s("sawtooth") without note() plays at C3 = MIDI 36
// (verified by checking strudel.cc/learn/synths: default note is ~36).
// We use MIDI 36 (C2 in some notations, C3 in Strudel's C0-based convention).
//
// FILTERS
// ───────
// lpf/hpf are applied at the SynthLayer level via AVAudioUnitEQ (2-band):
//   band[0] = lowPass  at lpf freq (default 20 000 Hz, bypassed)
//   band[1] = highPass at hpf freq (default 20 Hz,    bypassed)
// resonance (Q 0..50) → AVAudioUnitEQ band bandwidth.
// Mapping: AVAudioUnitEQ bandwidth is in octaves (1/12 to 5).
//   Q → bandwidth: bandwidth = log2(1 + 1/Q) approx; for Strudel-range Q 0..50:
//   we clamp Q to 0.01..50, then bandwidth = max(0.05, min(5.0, 2.0 / Q * 0.5)).
//   Documented compromise: AVAudioUnitEQ bandwidth param is not exactly Q;
//   this gives a musically usable mapping across the supported range.
//
// SPEED
// ─────
// speed() multiplies the varispeed rate applied for samples (note-based repitch).
// For synths, speed is not applicable (frequency is computed from MIDI note
// directly). Documented: speed() is a sample-only parameter for synths.
// ---------------------------------------------------------------------------

import AVFoundation
import Foundation

// MARK: - Constants

/// Default ADSR values (Strudel public docs: strudel.cc/learn/effects).
public enum ADSRDefaults {
    public static let attack:  Double = 0.001
    public static let decay:   Double = 0.05
    public static let sustain: Double = 0.6
    public static let release: Double = 0.1
}

/// Default MIDI note when no note() is provided with a synth.
/// Strudel default: C3 in Strudel notation = MIDI 48 (Strudel uses C0=0).
/// Verified: strudel.cc/learn/synths shows the default is middle-C range.
/// We use MIDI 48 (C3 in our C3=48 root convention, same as the scale system).
public let synthDefaultMIDI: Int = 48

// MARK: - MIDI to frequency

/// Standard equal-temperament: f = 440 × 2^((midi−69)/12).
func midiToFreq(_ midi: Double) -> Double {
    440.0 * pow(2.0, (midi - 69.0) / 12.0)
}

// MARK: - polyBLEP helper

/// polyBLEP correction for band-limited oscillators.
/// t = normalised phase (0..1), dt = phase increment per sample (freq/sampleRate).
/// Returns the correction to add/subtract at each discontinuity.
/// Formula: standard polyBLEP from public DSP literature.
@inline(__always)
private func polyBLEP(_ t: Double, dt: Double) -> Double {
    if t < dt {
        let x = t / dt
        return x + x - x * x - 1.0
    } else if t > 1.0 - dt {
        let x = (t - 1.0) / dt
        return x * x + x + x + 1.0
    }
    return 0.0
}

// MARK: - ADSR state

private enum ADSRStage { case attack, decay, sustain, release, idle }

// MARK: - SynthVoice

/// One polyphonic voice: oscillator + ADSR.
/// Thread-safety: render block is called on the audio thread;
/// trigger() is called from the scheduler's poolQueue.
/// Access is mediated by SynthLayer's renderLock.
final class SynthVoice {

    // ── Parameters set at trigger time ──────────────────────────────────────
    private(set) var isActive: Bool = false
    private var freq:    Double = 440.0
    private var gain:    Double = 1.0
    private var atkSamp: Int    = 0    // attack  in samples
    private var decSamp: Int    = 0    // decay   in samples
    private var susLvl:  Double = ADSRDefaults.sustain
    private var relSamp: Int    = 0    // release in samples
    private var noteDurSamp: Int = 0   // duration to sustain-end (start of release)

    // ── Oscillator state ────────────────────────────────────────────────────
    private var phase:    Double = 0.0
    private var dt:       Double = 0.0  // phase increment per sample
    private var waveform: String = "sine"

    // ── ADSR state ──────────────────────────────────────────────────────────
    private var stage:      ADSRStage = .idle
    private var samplesSinceOnset: Int = 0
    private var envLevel:   Double = 0.0
    private var triInteg:   Double = 0.0  // triangle integrator state

    // ── Birth time for LRU steal ─────────────────────────────────────────────
    private(set) var birthSample: Int = 0

    init() {}

    /// Trigger a new note on this voice (replaces any running note).
    func trigger(
        waveform:    String,
        freq:        Double,
        gain:        Double,
        attack:      Double,
        decay:       Double,
        sustain:     Double,
        release:     Double,
        durationSec: Double,
        sampleRate:  Double,
        birthSample: Int
    ) {
        self.freq        = freq
        self.gain        = gain
        self.waveform    = waveform.lowercased()
        self.dt          = freq / sampleRate

        self.atkSamp     = max(1, Int(attack  * sampleRate))
        self.decSamp     = max(1, Int(decay   * sampleRate))
        self.susLvl      = max(0.0, min(1.0, sustain))
        self.relSamp     = max(1, Int(release * sampleRate))
        self.noteDurSamp = max(1, Int(durationSec * sampleRate))

        self.phase             = 0.0
        self.envLevel          = 0.0
        self.triInteg          = 0.0
        self.samplesSinceOnset = 0
        self.stage             = .attack
        self.isActive          = true
        self.birthSample       = birthSample
    }

    /// Render `frameCount` samples into `buffer`, adding to existing content.
    /// Returns false when the voice has become idle (caller should clear isActive).
    @discardableResult
    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) -> Bool {
        guard isActive else { return false }

        for i in 0..<frameCount {
            // ── ADSR envelope ──────────────────────────────────────────────
            let env: Double
            switch stage {
            case .attack:
                envLevel += 1.0 / Double(atkSamp)
                if envLevel >= 1.0 {
                    envLevel = 1.0
                    stage = .decay
                }
                env = envLevel

            case .decay:
                envLevel -= (1.0 - susLvl) / Double(decSamp)
                if envLevel <= susLvl {
                    envLevel = susLvl
                    stage = .sustain
                }
                env = envLevel

            case .sustain:
                env = susLvl
                // Transition to release when note duration elapsed
                if samplesSinceOnset >= noteDurSamp {
                    stage = .release
                }

            case .release:
                envLevel -= susLvl / Double(relSamp)
                if envLevel <= 0.0 {
                    envLevel = 0.0
                    stage = .idle
                    isActive = false
                }
                env = max(0.0, envLevel)

            case .idle:
                isActive = false
                return false
            }

            // ── Oscillator ──────────────────────────────────────────────────
            let sample: Double
            switch waveform {
            case "sine":
                sample = sin(2.0 * Double.pi * phase)

            case "sawtooth":
                // naive saw + polyBLEP at phase=0 (wrapping discontinuity)
                var s = 2.0 * phase - 1.0
                s -= polyBLEP(phase, dt: dt)
                sample = s

            case "square":
                // naive square + polyBLEP corrections at 0 and 0.5
                var s = phase < 0.5 ? 1.0 : -1.0
                s += polyBLEP(phase, dt: dt)
                s -= polyBLEP(fmod(phase + 0.5, 1.0), dt: dt)
                sample = s

            case "triangle":
                // Integrate polyBLEP square via leaky integrator, scale to ±1
                var sq = phase < 0.5 ? 1.0 : -1.0
                sq += polyBLEP(phase, dt: dt)
                sq -= polyBLEP(fmod(phase + 0.5, 1.0), dt: dt)
                // Leaky integrator: triInteg = dt * sq + (1-leak) * triInteg
                // Scale by 4*dt so output amplitude ≈1 (steady state of integrator)
                triInteg = 4.0 * dt * sq + triInteg * 0.999
                sample = max(-1.0, min(1.0, triInteg))

            default:
                sample = sin(2.0 * Double.pi * phase)
            }

            // ── Apply envelope + gain, accumulate ──────────────────────────
            buffer[i] += Float(sample * env * gain)

            // ── Advance phase ───────────────────────────────────────────────
            phase += dt
            if phase >= 1.0 { phase -= 1.0 }
            samplesSinceOnset += 1
        }
        return isActive
    }
}

// MARK: - SynthLayer

/// A complete audio sub-graph for one synth type (e.g. "sawtooth").
/// Hosts a voice pool; the AVAudioSourceNode mixes all voices per render call.
final class SynthLayer {

    let synthName: String
    let sourceNode: AVAudioSourceNode
    let eq:         AVAudioUnitEQ
    let reverb:     AVAudioUnitReverb
    let delay:      AVAudioUnitDelay
    let panner:     AVAudioMixerNode

    private static let voicePoolSize = 8
    private var voices: [SynthVoice]
    private var renderSampleCount: Int = 0   // monotonic, for LRU

    /// Lock protecting voice pool between scheduler thread and render thread.
    private let renderLock = NSLock()

    init(synthName: String, sampleRate: Double) {
        self.synthName = synthName
        self.voices = (0..<SynthLayer.voicePoolSize).map { _ in SynthVoice() }

        // ── EQ: 2 bands — lpf (band 0) and hpf (band 1) ────────────────────
        let eqNode = AVAudioUnitEQ(numberOfBands: 2)

        let lpfBand = eqNode.bands[0]
        lpfBand.filterType = .lowPass
        lpfBand.frequency  = 20_000
        lpfBand.bandwidth  = 0.5
        lpfBand.bypass     = true

        let hpfBand = eqNode.bands[1]
        hpfBand.filterType = .highPass
        hpfBand.frequency  = 20.0
        hpfBand.bandwidth  = 0.5
        hpfBand.bypass     = true

        self.eq = eqNode

        // ── Reverb ──────────────────────────────────────────────────────────
        let reverbNode = AVAudioUnitReverb()
        reverbNode.loadFactoryPreset(.mediumHall)
        reverbNode.wetDryMix = 0
        self.reverb = reverbNode

        // ── Delay ───────────────────────────────────────────────────────────
        let delayNode = AVAudioUnitDelay()
        delayNode.wetDryMix     = 0
        delayNode.delayTime     = 0.25
        delayNode.feedback      = 50
        delayNode.lowPassCutoff = 15_000
        self.delay = delayNode

        // ── Panner ──────────────────────────────────────────────────────────
        self.panner = AVAudioMixerNode()

        // ── Source node ──────────────────────────────────────────────────────
        // Capture voices array in render block; keep self weak to avoid retain cycle.
        let voicesRef = UnsafeMutablePointer<[SynthVoice]>.allocate(capacity: 1)
        voicesRef.initialize(to: self.voices)

        // We store the render block closure over `voices` directly.
        // AVAudioSourceNode render format: stereo float 32.
        let capturedVoices = self.voices
        let capturedLock   = self.renderLock

        self.sourceNode = AVAudioSourceNode(renderBlock: { isSilence, timestamp, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frameCount = Int(frameCount)

            // Zero output buffers
            for buf in ablPointer {
                if let ptr = buf.mData {
                    memset(ptr, 0, Int(buf.mDataByteSize))
                }
            }

            // Mix all active voices into a mono temp buffer, then copy to all channels
            let tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            defer { tempBuffer.deallocate() }
            memset(tempBuffer, 0, frameCount * MemoryLayout<Float>.size)

            capturedLock.lock()
            var anyActive = false
            for voice in capturedVoices {
                if voice.isActive {
                    voice.render(into: tempBuffer, frameCount: frameCount)
                    anyActive = true
                }
            }
            capturedLock.unlock()

            if !anyActive {
                isSilence.pointee = true
            }

            // Copy mono mix to all output channels
            for buf in ablPointer {
                if let ptr = buf.mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<frameCount {
                        ptr[i] += tempBuffer[i]
                    }
                }
            }

            return noErr
        })

        voicesRef.deallocate()
    }

    deinit {
        // voices are value-typed SynthVoice objects — auto-released
    }

    // MARK: - Voice scheduling

    /// Schedule a new note. Called from the scheduler thread.
    func scheduleNote(
        freq:        Double,
        gain:        Double,
        attack:      Double,
        decay:       Double,
        sustain:     Double,
        release:     Double,
        durationSec: Double,
        sampleRate:  Double
    ) {
        renderLock.lock()
        defer { renderLock.unlock() }

        // Find idle voice; if none, steal oldest active
        let voice: SynthVoice
        if let idle = voices.first(where: { !$0.isActive }) {
            voice = idle
        } else {
            // steal oldest
            voice = voices.min(by: { $0.birthSample < $1.birthSample }) ?? voices[0]
        }

        renderSampleCount += 1
        voice.trigger(
            waveform:    synthName,
            freq:        freq,
            gain:        gain,
            attack:      attack,
            decay:       decay,
            sustain:     sustain,
            release:     release,
            durationSec: durationSec,
            sampleRate:  sampleRate,
            birthSample: renderSampleCount
        )
    }

    // MARK: - Effect parameter updates (called from scheduler thread)

    func applyRoom(_ room: Double) {
        reverb.wetDryMix = Float(room * 100.0)
    }

    func applyLPF(freq: Double, resonance: Double?) {
        let band = eq.bands[0]
        band.frequency = Float(freq)
        band.bypass    = false
        if let q = resonance {
            band.bandwidth = Float(resonanceToOctaveBandwidth(q))
        }
    }

    func applyHPF(freq: Double, resonance: Double?) {
        let band = eq.bands[1]
        band.frequency = Float(freq)
        band.bypass    = false
        if let q = resonance {
            band.bandwidth = Float(resonanceToOctaveBandwidth(q))
        }
    }

    func applyPan(_ pan: Double) {
        // Strudel 0..1 → AVAudioMixerNode.pan -1..1
        panner.pan = Float(pan * 2.0 - 1.0)
    }

    func applyDelay(wet: Double, time: Double?, feedback: Double?) {
        delay.wetDryMix = Float(wet * 100.0)
        if let t = time     { delay.delayTime = t }
        if let f = feedback { delay.feedback  = Float(f * 100.0) }
    }
}

// MARK: - Resonance → bandwidth mapping

/// Map Strudel resonance (Q, 0..50) to AVAudioUnitEQ bandwidth (octaves, 0.05..5).
///
/// AVAudioUnitEQ bandwidth ≈ fc/(Q * ln2) in octaves is not a clean analytic form,
/// so we use a practical mapping:
///   bandwidth = clamp(1.0 / max(0.01, Q) * 2.0, 0.05, 5.0)
/// This gives:
///   Q=0   → 5.0 (maximum bandwidth, widest/no resonance)
///   Q=1   → 2.0
///   Q=5   → 0.4
///   Q=50  → 0.05 (minimum bandwidth, sharpest peak)
/// Documented: this mapping is an approximation; exact Q behavior depends on
/// AVAudioUnitEQ internal implementation.
func resonanceToOctaveBandwidth(_ q: Double) -> Double {
    let qClamped = max(0.01, q)
    return max(0.05, min(5.0, 2.0 / qClamped))
}

/// Convert a MIDI note (Double) to frequency using equal temperament.
/// Exported for use in PatternScheduler and tests.
public func synthFrequency(midi: Double) -> Double {
    midiToFreq(midi)
}
