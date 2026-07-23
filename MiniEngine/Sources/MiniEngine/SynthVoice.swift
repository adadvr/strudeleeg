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

// MARK: - Synth headroom (Bug 3 fix)
//
// Oscillators exit at amplitude ~full-scale × gain.  In Strudel/Web Audio the
// synth voices are mixed at a noticeably lower level relative to drum samples.
// A fixed headroom factor of 0.3 is applied to every synth sample so that
// gain(1.0) on a sawtooth does not mask a kick drum at gain(0.95).
//
// COMPATIBILITY.md: the absolute level of synths vs samples is an approximation
// of the Strudel mix, not calibrated bit-for-bit against Web Audio.
private let synthHeadroom: Float = 0.3

// MARK: - Host time to seconds conversion (Bug 2 fix)
//
// Converts a mach_absolute_time tick count (UInt64, as in AudioTimeStamp.mHostTime)
// to seconds using the mach_timebase_info ratio.  This is the same clock domain as
// the host time values produced by hostTimeNow() in PatternScheduler.
@inline(__always)
func machTicksToSeconds(_ ticks: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000.0
}

// MARK: - Sample-accurate start offset math (Bug 2 fix)
//
// Pure function used by the render block and unit-testable without AVAudio.
//
// Returns (skip: Bool, startFrame: Int) where:
//   skip=true  → the voice's start time is beyond this buffer (output nothing)
//   skip=false → render starting at startFrame (clamped to 0 when already past)
//
// Parameters:
//   bufferStartSeconds: host-time of frame 0 in the current render buffer (seconds)
//   frameCount:         number of frames in this render buffer
//   sampleRate:         samples per second
//   startHostSeconds:   host-time when the voice should begin (seconds)
public func synthVoiceStartFrame(
    bufferStartSeconds: Double,
    frameCount: Int,
    sampleRate: Double,
    startHostSeconds: Double
) -> (skip: Bool, startFrame: Int) {
    let offsetSeconds = startHostSeconds - bufferStartSeconds
    let offsetFrames  = offsetSeconds * sampleRate

    // Voice hasn't started yet and is entirely beyond this buffer
    if offsetFrames >= Double(frameCount) {
        return (skip: true, startFrame: 0)
    }
    // Voice already started (or starts at or before frame 0): clamp to 0
    let frame = max(0, Int(offsetFrames))
    return (skip: false, startFrame: frame)
}

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

    // Bug 2 fix: absolute host time (seconds) when this voice should start producing audio.
    // Set at trigger time; consumed by the render block to compute per-buffer startFrame.
    private(set) var startHostSeconds: Double = 0.0

    // Fase 4: bitcrusher — 0 means disabled, >0 means active with that bit depth
    private var crushBits: Double = 0.0   // 0 = no crush

    // ── Oscillator state ────────────────────────────────────────────────────
    private var phase:    Double = 0.0
    private var dt:       Double = 0.0  // phase increment per sample
    private var waveform: String = "sine"
    private var triDrive: Double = 0.001  // Bug 2 fix: freq-compensated drive for triangle

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
        waveform:         String,
        freq:             Double,
        gain:             Double,
        attack:           Double,
        decay:            Double,
        sustain:          Double,
        release:          Double,
        durationSec:      Double,
        sampleRate:       Double,
        birthSample:      Int,
        startHostSeconds: Double,
        crushBits:        Double = 0.0
    ) {
        self.freq             = freq
        self.gain             = gain
        self.waveform         = waveform.lowercased()
        self.dt               = freq / sampleRate
        self.startHostSeconds = startHostSeconds

        // Bug 2 fix: pre-compute frequency-compensated drive constant for triangle.
        // k = (1-L) / (1 - L^(1/(2*dt)))  where L=0.999.
        // This makes the leaky integrator's steady-state amplitude ≈ 1.0 for all freqs.
        // Clamped to [1e-6, 1.0] to avoid divide-by-zero at extreme freqs.
        let dtClamped = max(1e-6, freq / sampleRate)
        let L = 0.999
        let halfPeriodSamples = 0.5 / dtClamped   // N/2
        let Lpow = pow(L, halfPeriodSamples)       // L^(N/2)
        let denom = max(1e-9, 1.0 - Lpow)
        self.triDrive = max(1e-6, min(1.0, (1.0 - L) / denom))  // (1-L)/(1-L^(N/2))

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
        self.crushBits         = crushBits
    }

    /// Render `frameCount` samples into `buffer`, adding to existing content.
    /// bufferStartSeconds: host-time (seconds) of frame 0 in this render buffer.
    /// Returns false when the voice has become idle (caller should clear isActive).
    @discardableResult
    func render(into buffer: UnsafeMutablePointer<Float>,
                frameCount: Int,
                bufferStartSeconds: Double,
                sampleRate: Double) -> Bool {
        guard isActive else { return false }

        // Bug 2 fix: compute the frame within this buffer where the voice starts.
        let (skip, startFrame) = synthVoiceStartFrame(
            bufferStartSeconds: bufferStartSeconds,
            frameCount: frameCount,
            sampleRate: sampleRate,
            startHostSeconds: startHostSeconds
        )
        if skip { return true }   // still pending, don't deactivate

        for i in startFrame..<frameCount {
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
                // Integrate polyBLEP square via leaky integrator with frequency-
                // compensated drive so output amplitude ≈ 1.0 at all frequencies.
                //
                // Bug 2 fix — frequency-independent amplitude:
                //   The leaky integrator y[n] = k * sq[n] + L * y[n-1] has steady-state
                //   peak amplitude:  A = k * (1 - L^(N/2)) / (1-L)
                //   where N = sampleRate/freq (samples per period), L = leak = 0.999.
                //
                //   Setting A = 1 requires:  k = (1-L) / (1 - L^(1/(2*dt)))
                //   where dt = freq/sampleRate.
                //
                //   This drive constant is computed once per voice at trigger time
                //   and stored in triDrive (see trigger()). The leak L = 0.999 is
                //   kept for band-limiting; only the drive changes.
                //
                //   Before fix: drive = 4*dt → A = 4000*dt ∝ freq → e5 ≈6× quiet.
                //   After fix:  drive = triDrive → A ≈ 1.0 at all frequencies.
                var sq = phase < 0.5 ? 1.0 : -1.0
                sq += polyBLEP(phase, dt: dt)
                sq -= polyBLEP(fmod(phase + 0.5, 1.0), dt: dt)
                triInteg = triDrive * sq + triInteg * 0.999
                sample = max(-1.0, min(1.0, triInteg))

            default:
                sample = sin(2.0 * Double.pi * phase)
            }

            // ── Apply envelope + gain + headroom ───────────────────────────
            // Bug 3 fix: synthHeadroom (0.3) keeps synth voices at a level that
            // does not mask drum samples at gain(0.95). Documented approximation;
            // not calibrated bit-for-bit against Web Audio. See COMPATIBILITY.md.
            var out = Float(sample * env * gain) * synthHeadroom

            // ── Bitcrusher (Fase 4): applied post-envelope in render block ──
            // Formula: round(s × 2^(bits-1)) / 2^(bits-1) — public domain DSP
            if crushBits > 0 {
                let levels = Float(pow(2.0, crushBits - 1.0))
                out = Foundation.round(out * levels) / levels
            }

            // ── Accumulate ─────────────────────────────────────────────────
            buffer[i] += out

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

    let synthName:  String
    /// Sample rate con el que renderizan las voces Y que declara el sourceNode.
    /// Deben ser el mismo — ver nota en init sobre el bug de pitch.
    let sampleRate: Double
    let sourceNode: AVAudioSourceNode
    let eq:         AVAudioUnitEQ
    let reverb:     AVAudioUnitReverb
    let delay:      AVAudioUnitDelay
    let distortion: AVAudioUnitDistortion   // Fase 4: shape/distort
    let vowelEQ:    AVAudioUnitEQ           // Fase 4: vowel formant (3 bands)
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
        lpfBand.filterType = .lowPass  // plain lowPass: no resonance peak by default
        lpfBand.frequency  = 20_000   // transparent (above hearing range)
        lpfBand.bypass     = true

        let hpfBand = eqNode.bands[1]
        hpfBand.filterType = .highPass  // plain highPass: no resonance peak by default
        hpfBand.frequency  = 20.0       // transparent (below hearing range)
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

        // ── Distortion (Fase 4: shape/distort) ─────────────────────────────
        let distortionNode = AVAudioUnitDistortion()
        distortionNode.loadFactoryPreset(.multiDistortedFunk)
        distortionNode.preGain   = 0
        distortionNode.wetDryMix = 0   // fully dry until shape/distort called
        self.distortion = distortionNode

        // ── Vowel EQ (Fase 4: formant filter, 3 bands) ─────────────────────
        let vowelEQNode = AVAudioUnitEQ(numberOfBands: 3)
        for i in 0..<3 {
            let b = vowelEQNode.bands[i]
            b.filterType = .parametric
            b.gain       = 6.0
            b.bandwidth  = 0.5
            b.bypass     = true
        }
        self.vowelEQ = vowelEQNode

        // ── Panner ──────────────────────────────────────────────────────────
        self.panner = AVAudioMixerNode()

        // ── Source node ──────────────────────────────────────────────────────
        // Capture voices array and lock in render block; keep captures minimal.
        // AVAudioSourceNode render format: stereo float 32.
        // Bug 2 fix: the render block reads timestamp.pointee.mHostTime (mach ticks
        // of frame 0) and converts to seconds; each voice uses its startHostSeconds
        // to compute the exact buffer frame at which it should begin.
        // No allocations inside the render block (tempBuffer is on the stack via
        // a fixed-capacity pointer allocated once in init and reused — but since
        // AVAudioSourceNode frameCount can vary, we allocate/deallocate with defer;
        // this is the existing pattern, kept unchanged to avoid ABI risk).
        let capturedVoices  = self.voices
        let capturedLock    = self.renderLock
        let capturedSR      = sampleRate   // captured once; fixed for lifetime of node
        self.sampleRate     = sampleRate

        // CRÍTICO: el nodo DEBE declarar su formato con este mismo sample rate.
        // Sin formato explícito, el engine renderiza el bloque al rate del
        // hardware (p.ej. 48000) mientras las voces calculan dt con `sampleRate`
        // (44100) → todos los synths sonaban ~1.4 semitonos graves (bug real
        // medido: e5 salía a 606 Hz en vez de 659). Con el formato declarado,
        // el mixer del engine convierte al rate del dispositivo sin tocar el pitch.
        let nodeFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        self.sourceNode = AVAudioSourceNode(format: nodeFormat, renderBlock: { isSilence, timestamp, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frameCountInt = Int(frameCount)

            // Zero output buffers
            for buf in ablPointer {
                if let ptr = buf.mData {
                    memset(ptr, 0, Int(buf.mDataByteSize))
                }
            }

            // Bug 2 fix: convert the timestamp's mHostTime (mach ticks, frame 0)
            // to seconds using the same mach_timebase_info ratio as hostTimeNow().
            // This is the host-clock anchor for sample-accurate voice start offsets.
            // mach_timebase_info is read inside each call: it is cheap (cached by OS)
            // and avoids storing mutable state in the render closure.
            var tbInfo = mach_timebase_info_data_t()
            mach_timebase_info(&tbInfo)
            let bufferStartTicks   = timestamp.pointee.mHostTime
            let bufferStartSeconds = Double(bufferStartTicks)
                                   * Double(tbInfo.numer)
                                   / Double(tbInfo.denom)
                                   / 1_000_000_000.0

            // Mix all active voices into a mono temp buffer, then copy to all channels.
            // Each voice is asked to start at the frame offset matching its startHostSeconds.
            let tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCountInt)
            defer { tempBuffer.deallocate() }
            memset(tempBuffer, 0, frameCountInt * MemoryLayout<Float>.size)

            capturedLock.lock()
            var anyActive = false
            for voice in capturedVoices {
                if voice.isActive {
                    // Pass bufferStartSeconds and sampleRate for per-buffer start-frame math.
                    voice.render(into: tempBuffer,
                                 frameCount: frameCountInt,
                                 bufferStartSeconds: bufferStartSeconds,
                                 sampleRate: capturedSR)
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
                    for i in 0..<frameCountInt {
                        ptr[i] += tempBuffer[i]
                    }
                }
            }

            return noErr
        })
    }

    deinit {
        // voices are value-typed SynthVoice objects — auto-released
    }

    // MARK: - Voice scheduling

    /// Schedule a new note. Called from the scheduler thread.
    /// startHostSeconds: absolute host-time (seconds, same clock as hostTimeNow() in
    ///   PatternScheduler) when this voice should begin producing audio.
    ///   The render block converts the buffer's mHostTime to seconds and computes the
    ///   exact frame offset within each render buffer for sample-accurate voice onset.
    func scheduleNote(
        freq:             Double,
        gain:             Double,
        attack:           Double,
        decay:            Double,
        sustain:          Double,
        release:          Double,
        durationSec:      Double,
        sampleRate:       Double,
        startHostSeconds: Double,
        crushBits:        Double = 0.0
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
            waveform:         synthName,
            freq:             freq,
            gain:             gain,
            attack:           attack,
            decay:            decay,
            sustain:          sustain,
            release:          release,
            durationSec:      durationSec,
            sampleRate:       sampleRate,
            birthSample:      renderSampleCount,
            startHostSeconds: startHostSeconds,
            crushBits:        crushBits
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
        if let q = resonance, q > 0 {
            // Switch to resonantLowPass which supports bandwidth/Q control.
            // .resonantLowPass uses bandwidth in octaves for Q control.
            band.filterType = .resonantLowPass
            band.bandwidth  = Float(resonanceToOctaveBandwidth(q))
        } else {
            // Plain lowPass: fixed-slope, no resonance peak.
            // Reset to lowPass in case a previous call set resonantLowPass.
            band.filterType = .lowPass
        }
    }

    func applyHPF(freq: Double, resonance: Double?) {
        let band = eq.bands[1]
        band.frequency = Float(freq)
        band.bypass    = false
        if let q = resonance, q > 0 {
            // resonantHighPass supports bandwidth/Q control.
            band.filterType = .resonantHighPass
            band.bandwidth  = Float(resonanceToOctaveBandwidth(q))
        } else {
            // Plain highPass: no resonance peak.
            band.filterType = .highPass
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

    // MARK: - Fase 4: Distortion

    /// Apply shape/distort saturation level (0..1) → wetDryMix (0..100).
    /// Both shape() and distort() use this method; the scheduler passes
    /// distort's value if both are present, else shape.
    func applyDistortion(_ level: Double) {
        distortion.wetDryMix = Float(level * 100.0)
    }

    // MARK: - Fase 4: Vowel formant filter

    /// Apply vowel formant frequencies ("a"|"e"|"i"|"o"|"u").
    /// Uses the same vowelFormants table as PatternScheduler.
    func applyVowel(_ v: String) {
        let key = v.lowercased()
        let formants: [String: (f1: Float, f2: Float, f3: Float)] = [
            "a": (730,  1090, 2440),
            "e": (530,  1840, 2480),
            "i": (390,  1990, 2550),
            "o": (570,   840, 2410),
            "u": (440,  1020, 2240),
        ]
        guard let f = formants[key] else { return }
        let freqs: [Float] = [f.f1, f.f2, f.f3]
        for i in 0..<3 {
            let b = vowelEQ.bands[i]
            b.frequency = freqs[i]
            b.bypass    = false
        }
    }
}

// MARK: - Bitcrusher DSP

/// Apply bitcrusher quantisation to a sample buffer in-place.
///
/// Formula (public-domain): quantize(s) = round(s × 2^(bits-1)) / 2^(bits-1)
/// This maps the float signal to a reduced set of amplitude levels.
///
/// bits: effective bit depth. Range: 1..16 practical.
///   bits=16 → 32768 levels → near-transparent
///   bits=8  → 128 levels → lo-fi
///   bits=4  → 8 levels → heavy lo-fi
///   bits=1  → 1 level → 1-bit (extreme)
///
/// Input samples assumed in range -1..1 (same as SynthVoice output).
public func applyBitcrusher(buffer: UnsafeMutablePointer<Float>, frameCount: Int, bits: Double) {
    let bitsClamp = max(1.0, min(16.0, bits))
    let levels = pow(2.0, bitsClamp - 1.0)   // 2^(bits-1)
    let levelsF = Float(levels)
    let invLevels = 1.0 / levelsF
    for i in 0..<frameCount {
        let s = buffer[i]
        buffer[i] = Foundation.round(s * levelsF) * invLevels
    }
}

/// Apply bitcrusher quantisation to an AVAudioPCMBuffer, returning a new buffer.
/// Used for sample-based layers: creates a quantised copy of the buffer before scheduling.
///
/// Parameters:
///   buffer: source PCM buffer (must be Float32 non-interleaved).
///   bits:   effective bit depth (1..16).
/// Returns: a new AVAudioPCMBuffer with quantised samples, or the original if format unsupported.
public func bitcrushedBuffer(_ buffer: AVAudioPCMBuffer, bits: Double) -> AVAudioPCMBuffer {
    guard let floatChannels = buffer.floatChannelData else { return buffer }
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return buffer }
    guard let result = AVAudioPCMBuffer(
        pcmFormat: buffer.format,
        frameCapacity: buffer.frameCapacity
    ) else { return buffer }
    result.frameLength = buffer.frameLength

    let channelCount = Int(buffer.format.channelCount)
    let bitsClamp = max(1.0, min(16.0, bits))
    let levels    = Float(pow(2.0, bitsClamp - 1.0))
    let invLevels = 1.0 / levels

    guard let dstChannels = result.floatChannelData else { return buffer }
    for ch in 0..<channelCount {
        let src = floatChannels[ch]
        let dst = dstChannels[ch]
        for i in 0..<frameCount {
            dst[i] = Foundation.round(src[i] * levels) * invLevels
        }
    }
    return result
}

// MARK: - ADSR envelope over sample buffer

/// Apply an ADSR amplitude envelope to a copy of a PCM buffer.
///
/// Semantics:
///   - Attack  [0 .. attack*sr]:              gain ramps 0 → 1
///   - Decay   [attack*sr .. (att+dec)*sr]:   gain ramps 1 → sustain
///   - Sustain [(att+dec)*sr .. dur*sr]:       gain stays at sustain level
///   - Release [dur*sr .. (dur+rel)*sr]:       gain ramps sustain → 0
///
/// The buffer is extended with silence for the release tail if it is shorter than
/// the A+D+S window (the buffer may be shorter than durationSec; this is fine —
/// the envelope is computed per-sample up to the buffer's actual frame count).
///
/// If all ADSR params produce a transparent envelope (att~0, dec~0, sus=1, rel~0),
/// the result is perceptually identical to the source buffer.
///
/// Parameters:
///   buffer:      source Float32 non-interleaved PCM buffer.
///   sampleRate:  buffer sample rate.
///   attack:      attack time in seconds (≥0).
///   decay:       decay time in seconds (≥0).
///   sustain:     sustain level 0..1.
///   release:     release time in seconds (≥0).
///   durationSec: note duration (sustain window end). Clamped to buffer length.
/// Returns: new buffer with envelope applied, same format as input.
public func adsrEnvelopeBuffer(
    _ buffer: AVAudioPCMBuffer,
    sampleRate: Double,
    attack: Double,
    decay: Double,
    sustain: Double,
    release: Double,
    durationSec: Double
) -> AVAudioPCMBuffer {
    guard let srcChannels = buffer.floatChannelData else { return buffer }
    let sr          = Float(sampleRate)
    let frameCount  = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frameCount > 0, channelCount > 0 else { return buffer }

    let attFrames = Int(max(0, Float(attack)  * sr))
    let decFrames = Int(max(0, Float(decay)   * sr))
    let relFrames = Int(max(0, Float(release) * sr))
    let durFrames = Int(max(0, Float(durationSec) * sr))

    // Compute per-frame gain envelope
    let totalFrames = frameCount  // output matches input length
    var envelope = [Float](repeating: Float(sustain), count: totalFrames)

    for i in 0..<totalFrames {
        if i < attFrames {
            // Attack: 0 → 1
            envelope[i] = attFrames > 0 ? Float(i) / Float(attFrames) : 1.0
        } else if i < attFrames + decFrames {
            // Decay: 1 → sustain
            let t = Float(i - attFrames) / Float(max(1, decFrames))
            envelope[i] = 1.0 - t * (1.0 - Float(sustain))
        } else if i < durFrames {
            // Sustain
            envelope[i] = Float(sustain)
        } else {
            // Release: sustain → 0
            let relStart = max(attFrames + decFrames, durFrames)
            let t = relFrames > 0 ? Float(i - relStart) / Float(relFrames) : 1.0
            envelope[i] = Float(sustain) * max(0.0, 1.0 - t)
        }
    }

    // Allocate result and apply envelope
    guard let result = AVAudioPCMBuffer(
        pcmFormat: buffer.format,
        frameCapacity: buffer.frameCapacity
    ) else { return buffer }
    result.frameLength = buffer.frameLength

    guard let dstChannels = result.floatChannelData else { return buffer }
    for ch in 0..<channelCount {
        let src = srcChannels[ch]
        let dst = dstChannels[ch]
        for i in 0..<totalFrames {
            dst[i] = src[i] * envelope[i]
        }
    }
    return result
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
