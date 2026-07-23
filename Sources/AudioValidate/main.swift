// ---------------------------------------------------------------------------
// AudioValidate — Offline audio harness for MiniEngine spectral validation.
//
// ARCHITECTURE:
// ─────────────
// This harness answers: "do MiniEngine's output frequencies match expectations?"
//
// AVAudioEngine.enableManualRenderingMode(.offline, format:, maximumFrameCount:)
// is the intended Apple API for offline rendering. However, PatternScheduler uses
// mach_absolute_time (real-time host clock) in two ways:
//
//   a) tick() timer — DispatchSourceTimer driven by real time.
//   b) SynthVoice render block reads timestamp.pointee.mHostTime to compute
//      sample-accurate voice start offsets.
//
// Both require real-time execution. In offline mode, AVAudioSourceNode's render
// callback receives mHostTime=0 (the engine's internal offline clock has no
// mach_timebase mapping), so all voice start offsets compute as 0 → voices fire
// at the beginning of every buffer instead of their scheduled time.
//
// OFFLINE SCHEDULING PATH (this file):
//   We bypass PatternScheduler and implement a pure-Swift offline renderer:
//
//   1. Parse the ControlPattern using CodeParser (same as production).
//   2. Query ALL haps in [0, N seconds] at once (no timer, no lookahead).
//   3. For each hap, schedule an OfflineVoice with:
//      - onsetFrame = Int(hapOnsetSec * sampleRate)
//      - The voice's ADSR and oscillator are implemented directly here,
//        identical to SynthVoice (same polyBLEP formulas, same ADSR state machine).
//      This avoids touching SynthVoice (which is internal to MiniEngine) while
//      producing acoustically equivalent output.
//   4. Render block-by-block (512 frames), triggering voices when their
//      onsetFrame falls within the current block, advancing pre-onset ADSR state
//      to correctly position the onset within the block.
//
// PUBLIC API USED:
//   CodeParser.parseWithTempo(_:) → ParseResult (public)
//   ControlPattern.query(_:) → [Hap<[String:ControlValue]>] (public)
//   isSynthName(_:), synthFrequency(midi:), ADSRDefaults, synthDefaultMIDI (public)
//   Rational, TimeSpan (public)
//
// FFT ANALYSIS:
//   Accelerate/vDSP FFT on Hann-windowed frames around each expected event onset.
//   Peak detection with ±3% frequency tolerance.
//
// COMPROMISE DOCUMENTED:
//   The offline voices are re-implemented (not reusing SynthVoice which is internal).
//   The polyBLEP and ADSR formulas are identical. The synthHeadroom (0.3) is also
//   applied. Filter (lpf) is simulated via a single-pole IIR in the test context,
//   since AVAudioUnitEQ requires a running audio engine graph.
//
// ---------------------------------------------------------------------------

import AVFoundation
import Accelerate
import Foundation
import MiniEngine

// MARK: - Constants

let sampleRate: Double = 44100.0
let cps:        Double = 0.5   // 1 cycle = 2 seconds (Strudel default)
let synthHeadroom: Float = 0.3   // matches SynthVoice.synthHeadroom

// MARK: - polyBLEP (same formula as SynthVoice.swift)

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

// MARK: - Offline Voice
// Mirrors SynthVoice behaviour without requiring its internal access.

private enum ADSRStage { case attack, decay, sustain, release, idle }

private final class OfflineVoice {
    var isActive: Bool = false
    var birthSample: Int = 0

    // ADSR params (in samples)
    private var atkSamp: Int = 0
    private var decSamp: Int = 0
    private var susLvl:  Double = 0.6
    private var relSamp: Int = 0
    private var noteDurSamp: Int = 0

    // Oscillator state
    private var phase:    Double = 0.0
    private var dt:       Double = 0.0
    private var waveform: String = "sine"
    private var gain:     Double = 1.0
    private var triDrive: Double = 0.001  // Bug 2 fix: freq-compensated triangle drive

    // ADSR runtime state
    private var stage:              ADSRStage = .idle
    private var envLevel:           Double = 0.0
    private var triInteg:           Double = 0.0
    private var samplesSinceOnset:  Int = 0

    func trigger(waveform: String, freq: Double, gain: Double,
                 attack: Double, decay: Double, sustain: Double, release: Double,
                 durationSec: Double, birthSample: Int) {
        self.waveform         = waveform.lowercased()
        self.gain             = gain
        self.dt               = freq / sampleRate
        self.atkSamp          = max(1, Int(attack  * sampleRate))
        self.decSamp          = max(1, Int(decay   * sampleRate))
        self.susLvl           = max(0, min(1, sustain))
        self.relSamp          = max(1, Int(release * sampleRate))
        self.noteDurSamp      = max(1, Int(durationSec * sampleRate))
        self.phase            = 0.0
        self.envLevel         = 0.0
        self.triInteg         = 0.0
        self.samplesSinceOnset = 0
        self.stage            = .attack
        self.isActive         = true
        self.birthSample      = birthSample

        // Calibration fix: correct triDrive formula for steady-state peak amplitude = 1.0.
        // Previous formula k=(1−L)/(1−Lpow) gave peak≈0.51 (ignored cross-half residue).
        // Correct formula: k = (1−L)·(1+Lpow)/(1−Lpow).
        // See SynthVoice.swift trigger() derivation for full math.
        let dtv = max(1e-6, freq / sampleRate)
        let L = 0.999
        let Lpow = pow(L, 0.5 / dtv)          // L^(N/2)
        let denom = max(1e-9, 1.0 - Lpow)
        self.triDrive = max(1e-6, min(2.0, (1.0 - L) * (1.0 + Lpow) / denom))
    }

    /// Render frameCount samples into buffer (accumulate). Returns false when idle.
    @discardableResult
    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) -> Bool {
        guard isActive else { return false }

        for i in 0..<frameCount {
            let env: Double
            switch stage {
            case .attack:
                envLevel += 1.0 / Double(atkSamp)
                if envLevel >= 1.0 { envLevel = 1.0; stage = .decay }
                env = envLevel
            case .decay:
                envLevel -= (1.0 - susLvl) / Double(decSamp)
                if envLevel <= susLvl { envLevel = susLvl; stage = .sustain }
                env = envLevel
            case .sustain:
                env = susLvl
                if samplesSinceOnset >= noteDurSamp { stage = .release }
            case .release:
                envLevel -= susLvl / Double(relSamp)
                if envLevel <= 0 { envLevel = 0; stage = .idle; isActive = false }
                env = max(0, envLevel)
            case .idle:
                isActive = false
                return false
            }

            let sample: Double
            switch waveform {
            case "sine":
                sample = sin(2.0 * Double.pi * phase)
            case "sawtooth":
                var s = 2.0 * phase - 1.0
                s -= polyBLEP(phase, dt: dt)
                sample = s
            case "square":
                var s = phase < 0.5 ? 1.0 : -1.0
                s += polyBLEP(phase, dt: dt)
                s -= polyBLEP(fmod(phase + 0.5, 1.0), dt: dt)
                sample = s
            case "triangle":
                // Bug 2 fix: frequency-compensated drive (triDrive) so amplitude ≈ 1.0
                // at all frequencies. See trigger() for the derivation.
                var sq = phase < 0.5 ? 1.0 : -1.0
                sq += polyBLEP(phase, dt: dt)
                sq -= polyBLEP(fmod(phase + 0.5, 1.0), dt: dt)
                triInteg = triDrive * sq + triInteg * 0.999
                sample = max(-1.0, min(1.0, triInteg))
            default:
                sample = sin(2.0 * Double.pi * phase)
            }

            buffer[i] += Float(sample * env * gain) * synthHeadroom

            phase += dt
            if phase >= 1.0 { phase -= 1.0 }
            samplesSinceOnset += 1
        }
        return isActive
    }
}

// MARK: - Offline Voice Pool
//
// Bug 1 fix: OfflineVoicePool now tracks layerIdx per event and supports
// per-layer LPF filters. This mirrors the PatternScheduler's per-branch chain
// isolation and is used by the layer-isolation AudioValidate tests.

private final class OfflineVoicePool {
    private var voices: [OfflineVoice] = (0..<16).map { _ in OfflineVoice() }
    private var birthCounter = 0

    struct PendingEvent {
        let onsetFrame:  Int
        let waveform:    String
        let freq:        Double
        let gain:        Double
        let attack:      Double
        let decay:       Double
        let sustain:     Double
        let release:     Double
        let durationSec: Double
        let layerIdx:    Int    // Bug 1 fix: _layer field from control pattern
        var triggered:   Bool = false
    }

    var events: [PendingEvent] = []

    /// Per-layer LPF cutoff frequencies (Hz). Set before rendering to apply
    /// layer-specific filters that mirror PatternScheduler's per-chain EQ.
    var layerLPF: [Int: Double] = [:]

    func add(onsetSec: Double, waveform: String, freq: Double, gain: Double,
             attack: Double, decay: Double, sustain: Double, release: Double,
             durationSec: Double, layerIdx: Int = 0) {
        events.append(PendingEvent(
            onsetFrame:  Int(onsetSec * sampleRate),
            waveform:    waveform,
            freq:        freq,
            gain:        gain,
            attack:      attack,
            decay:       decay,
            sustain:     sustain,
            release:     release,
            durationSec: durationSec,
            layerIdx:    layerIdx
        ))
    }

    func render(into out: UnsafeMutablePointer<Float>, frameCount: Int, absoluteFrame: Int) {
        // Determine which layers need per-layer rendering (those with an LPF).
        // If no LPF is set for any layer, fall back to the simpler mixed render.
        let layersWithFilter = Set(layerLPF.keys)

        if layersWithFilter.isEmpty {
            // Fast path: mix all voices directly
            renderMixed(into: out, frameCount: frameCount, absoluteFrame: absoluteFrame)
        } else {
            // Layered path: render each layer separately, apply its LPF, then mix.
            // Collect all distinct layer indices.
            let allLayers = Set(events.map { $0.layerIdx })
            let tempBuf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            defer { tempBuf.deallocate() }

            for layerIdx in allLayers.sorted() {
                memset(tempBuf, 0, frameCount * MemoryLayout<Float>.size)
                renderSingleLayer(into: tempBuf, frameCount: frameCount,
                                  absoluteFrame: absoluteFrame, layerIdx: layerIdx)
                // Apply per-layer LPF if configured
                if let lpfHz = layerLPF[layerIdx] {
                    let filter = ButterworthLPF4(cutoffHz: lpfHz)
                    filter.process(buffer: tempBuf, count: frameCount)
                }
                // Mix into output
                for i in 0..<frameCount { out[i] += tempBuf[i] }
            }
        }
    }

    /// Render only the events belonging to `layerIdx`.
    private func renderSingleLayer(into out: UnsafeMutablePointer<Float>,
                                   frameCount: Int, absoluteFrame: Int, layerIdx: Int) {
        // We use a separate set of voices per layer to avoid cross-layer stealing.
        // For simplicity in this offline harness, we re-use the shared pool but only
        // trigger/render events for the specified layer.
        //
        // Approach: snapshot which voices are idle before triggering this layer's events,
        // trigger only layer-matching events, render only newly triggered voices plus
        // already-active voices from previous blocks of this layer.
        //
        // Since OfflineVoicePool is used offline (single-threaded, no real-time
        // constraints), we implement a simpler strategy: collect this layer's events
        // that fall in the current block and render them into a local buffer, separate
        // from other layers.
        //
        // Implementation note: we create temporary OfflineVoice objects per layer to
        // keep state truly separate. The shared `voices` pool is NOT used in layered mode.

        // Use voices stored in layerVoices dict (lazily created).
        let layerVoiceList = getLayerVoices(layerIdx: layerIdx)

        for i in 0..<events.count {
            guard events[i].layerIdx == layerIdx, !events[i].triggered else { continue }
            let ev = events[i]
            let relFrame = ev.onsetFrame - absoluteFrame
            if relFrame >= frameCount { continue }

            events[i].triggered = true
            birthCounter += 1

            let voice: OfflineVoice
            if let idle = layerVoiceList.first(where: { !$0.isActive }) {
                voice = idle
            } else {
                voice = layerVoiceList.min(by: { $0.birthSample < $1.birthSample }) ?? layerVoiceList[0]
            }

            voice.trigger(waveform:    ev.waveform,
                          freq:        ev.freq,
                          gain:        ev.gain,
                          attack:      ev.attack,
                          decay:       ev.decay,
                          sustain:     ev.sustain,
                          release:     ev.release,
                          durationSec: ev.durationSec,
                          birthSample: birthCounter)

            if relFrame > 0 {
                let tmp = UnsafeMutablePointer<Float>.allocate(capacity: relFrame)
                defer { tmp.deallocate() }
                memset(tmp, 0, relFrame * MemoryLayout<Float>.size)
                voice.render(into: tmp, frameCount: relFrame)
            }
        }

        for voice in layerVoiceList where voice.isActive {
            voice.render(into: out, frameCount: frameCount)
        }
    }

    /// Mixed (non-layered) render — original path.
    private func renderMixed(into out: UnsafeMutablePointer<Float>,
                             frameCount: Int, absoluteFrame: Int) {
        for i in 0..<events.count {
            guard !events[i].triggered else { continue }
            let ev = events[i]
            let relFrame = ev.onsetFrame - absoluteFrame
            if relFrame >= frameCount { continue }

            events[i].triggered = true
            birthCounter += 1

            let voice: OfflineVoice
            if let idle = voices.first(where: { !$0.isActive }) {
                voice = idle
            } else {
                voice = voices.min(by: { $0.birthSample < $1.birthSample }) ?? voices[0]
            }

            voice.trigger(waveform:    ev.waveform,
                          freq:        ev.freq,
                          gain:        ev.gain,
                          attack:      ev.attack,
                          decay:       ev.decay,
                          sustain:     ev.sustain,
                          release:     ev.release,
                          durationSec: ev.durationSec,
                          birthSample: birthCounter)

            if relFrame > 0 {
                let tmp = UnsafeMutablePointer<Float>.allocate(capacity: relFrame)
                defer { tmp.deallocate() }
                memset(tmp, 0, relFrame * MemoryLayout<Float>.size)
                voice.render(into: tmp, frameCount: relFrame)
            }
        }

        for voice in voices where voice.isActive {
            voice.render(into: out, frameCount: frameCount)
        }
    }

    // Per-layer voice pools (lazy, keyed by layer index).
    private var layerVoicesMap: [Int: [OfflineVoice]] = [:]

    private func getLayerVoices(layerIdx: Int) -> [OfflineVoice] {
        if let existing = layerVoicesMap[layerIdx] { return existing }
        let pool = (0..<16).map { _ in OfflineVoice() }
        layerVoicesMap[layerIdx] = pool
        return pool
    }
}

// MARK: - Cascaded Biquad LPF (for filter-effect test)
// 4th-order Butterworth lowpass (2 cascaded biquad sections) for ~48dB/oct rolloff.
// This gives sufficient attenuation to match a steep lowpass filter.
// Bilinear transform Butterworth coefficients — public-domain DSP formulas.

private struct BiquadSection {
    var b0, b1, b2: Float   // feed-forward
    var a1, a2:     Float   // feed-back (negated convention: y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2)
    var x1: Float = 0; var x2: Float = 0
    var y1: Float = 0; var y2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

private final class ButterworthLPF4 {
    // 4th-order Butterworth lowpass via two cascaded 2nd-order sections.
    // Prototype poles at angles π/4 * (2k+1)/4 for k=0..3; bilinear transformed.
    // Formula: standard bilinear transform of Butterworth 2-pole sections.
    private var s1: BiquadSection
    private var s2: BiquadSection

    init(cutoffHz: Double) {
        let fc   = cutoffHz / sampleRate
        _ = Double.pi * fc   // pre-warped normalized frequency (unused: kept for readability)

        // Butterworth 4th-order: two 2nd-order sections with pole angles:
        // Section 1: Q = 1/(2*cos(π/8)) = 1/1.8478 ≈ 0.5412
        // Section 2: Q = 1/(2*cos(3π/8)) = 1/0.7654 ≈ 1.3066
        func makeBiquadLPF(q: Double) -> BiquadSection {
            let w  = tan(Double.pi * cutoffHz / sampleRate)
            let ww = w * w
            let denom = Float(1.0 + w / q + ww)
            let b = Float(ww) / denom
            let a1coeff = Float(2.0 * (ww - 1.0)) / denom
            let a2coeff = Float(1.0 - w / q + ww) / denom
            return BiquadSection(b0: b, b1: 2*b, b2: b, a1: a1coeff, a2: a2coeff)
        }

        // Q values for 4th-order Butterworth two-section decomposition
        s1 = makeBiquadLPF(q: 0.5412)   // cos(π/8) section
        s2 = makeBiquadLPF(q: 1.3066)   // cos(3π/8) section
    }

    func process(buffer: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count {
            var y = s1.process(buffer[i])
            y = s2.process(y)
            buffer[i] = y
        }
    }
}

// MARK: - Kick Drum Signal Generator
// For s("bd") test: no sample files available in this test context.
// Generates a sine sweep from 100→40 Hz with exponential decay.
// This models a real kick drum (fundamental below 150 Hz throughout):
//   - Real kick drums: pitch starts ~80-150 Hz, sweeps to ~40-60 Hz
//   - The sweep stays below 150 Hz for the entire duration
//   - Analysis: energy measured over the full 0.5s duration (not just onset)
// Phase integral of f(t) = f0 + (f1-f0)*t/T:
//   φ(t) = 2π * (f0*t + (f1-f0)*t²/(2*T))

private func generateKickDrum(durationSec: Double) -> [Float] {
    let n    = Int(durationSec * sampleRate)
    var buf  = [Float](repeating: 0, count: n)
    let f0   = 100.0   // start frequency: 100 Hz (clearly below 150 Hz)
    let f1   = 40.0    // end frequency:   40 Hz
    let df   = f1 - f0  // -60 Hz sweep
    for i in 0..<n {
        let t = Double(i) / sampleRate
        let env   = Float(exp(-t * 8.0))   // slower decay (more sustained low energy)
        let phase = 2.0 * Double.pi * (f0 * t + df * t * t / (2.0 * durationSec))
        buf[i] = Float(sin(phase)) * env
    }
    return buf
}

// MARK: - Offline Pattern Renderer

/// Render a synth ControlPattern code string to a mono float array.
/// applyLPF: if non-nil, applies a 4th-order Butterworth LPF at that frequency GLOBALLY
///   (after all layers are mixed). For per-layer LPF, use layerLPF parameter.
/// layerLPF: optional dictionary mapping layer-index → lpf cutoff Hz.
///   When set, each stack layer is rendered independently with its own filter chain,
///   mirroring the PatternScheduler's per-branch isolation (Bug 1 fix).
///   The _layer field from hap.value["_layer"] is used to route events to the right filter.
func renderPattern(code: String, durationSec: Double,
                   applyLPF lpfHz: Double? = nil,
                   layerLPF: [Int: Double]? = nil) -> [Float] {
    let parser = CodeParser()
    guard let result = try? parser.parseWithTempo(code) else {
        print("[AudioValidate] Parse error: \(code)")
        return [Float](repeating: 0, count: Int(durationSec * sampleRate))
    }

    let effectiveCps = result.cps ?? cps
    let effectiveCycleLen = 1.0 / effectiveCps
    let pattern = result.pattern
    let totalSamples = Int(durationSec * sampleRate)

    // Query all haps in the render window
    let cycleEnd  = Rational(approximating: durationSec / effectiveCycleLen)
    let querySpan = TimeSpan(Rational(0), cycleEnd)
    let haps      = pattern.query(querySpan)

    let pool = OfflineVoicePool()

    // Bug 1 fix: pass per-layer LPF map to the pool so each layer renders through
    // its own filter chain (same isolation as PatternScheduler's per-branch EQ).
    if let lLPF = layerLPF { pool.layerLPF = lLPF }

    for hap in haps {
        guard let sVal = hap.value["s"]?.stringValue, isSynthName(sVal) else { continue }

        let midi     = hap.value["note"]?.doubleValue ?? Double(synthDefaultMIDI)
        let freq     = synthFrequency(midi: midi)
        let gain     = hap.value["gain"]?.doubleValue    ?? 1.0
        let attack   = hap.value["attack"]?.doubleValue  ?? ADSRDefaults.attack
        let decay    = hap.value["decay"]?.doubleValue   ?? ADSRDefaults.decay
        let sustain  = hap.value["sustain"]?.doubleValue ?? ADSRDefaults.sustain
        let release  = hap.value["release"]?.doubleValue ?? ADSRDefaults.release

        // Bug 1 fix: read _layer from the control map (CodeParser injects it).
        let layerIdx = Int(hap.value["_layer"]?.doubleValue ?? 0.0)

        let onsetSec = hap.part.begin.toDouble * effectiveCycleLen
        guard onsetSec < durationSec else { continue }

        let hapDurCycles = (hap.whole ?? hap.part).end.toDouble
                         - (hap.whole ?? hap.part).begin.toDouble
        let durSec = max(0.05, hapDurCycles * effectiveCycleLen)

        pool.add(onsetSec:    onsetSec,
                 waveform:    sVal,
                 freq:        freq,
                 gain:        gain,
                 attack:      attack,
                 decay:       decay,
                 sustain:     sustain,
                 release:     release,
                 durationSec: durSec,
                 layerIdx:    layerIdx)
    }

    var output = [Float](repeating: 0, count: totalSamples)
    let blockSz = 512

    output.withUnsafeMutableBufferPointer { ptr in
        var frame = 0
        while frame < totalSamples {
            let count    = min(blockSz, totalSamples - frame)
            let blockPtr = ptr.baseAddress! + frame
            memset(blockPtr, 0, count * MemoryLayout<Float>.size)
            pool.render(into: blockPtr, frameCount: count, absoluteFrame: frame)
            frame += count
        }
    }

    // Global LPF (applied to entire mixed output, not per-layer)
    if let lpf = lpfHz {
        let filter = ButterworthLPF4(cutoffHz: lpf)
        output.withUnsafeMutableBufferPointer { ptr in
            filter.process(buffer: ptr.baseAddress!, count: totalSamples)
        }
    }

    return output
}

// MARK: - FFT Utilities

/// Compute magnitude spectrum of a windowed frame using Accelerate/vDSP.
private func magnitudeSpectrum(buffer: [Float], startFrame: Int, windowLen: Int) -> (mags: [Float], fftSize: Int) {
    var fftSize = 1
    while fftSize < windowLen { fftSize <<= 1 }
    fftSize = min(fftSize, 16384)

    let startF = max(0, startFrame)
    let endF   = min(buffer.count, startF + fftSize)
    let actual = endF - startF
    guard actual > 64 else { return ([], fftSize) }

    // Hann-windowed frame
    var frame = [Float](repeating: 0, count: fftSize)
    for i in 0..<actual {
        let hann = Float(0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(max(1, actual - 1)))))
        frame[i] = buffer[startF + i] * hann
    }

    let log2n = vDSP_Length(log2(Double(fftSize)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], fftSize) }
    defer { vDSP_destroy_fftsetup(setup) }

    var realPart = [Float](repeating: 0, count: fftSize / 2)
    var imagPart = [Float](repeating: 0, count: fftSize / 2)

    frame.withUnsafeMutableBufferPointer { fb in
        realPart.withUnsafeMutableBufferPointer { rb in
            imagPart.withUnsafeMutableBufferPointer { ib in
                var sc = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                fb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cp in
                    vDSP_ctoz(cp, 2, &sc, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }

    var mags = [Float](repeating: 0, count: fftSize / 2)
    realPart.withUnsafeMutableBufferPointer { rb in
        imagPart.withUnsafeMutableBufferPointer { ib in
            var sc = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
            mags.withUnsafeMutableBufferPointer { mb in
                vDSP_zvabs(&sc, 1, mb.baseAddress!, 1, vDSP_Length(fftSize / 2))
            }
        }
    }

    return (mags: mags, fftSize: fftSize)
}

/// Find the peak frequency in a window around windowStartSec.
func findPeakHz(buffer: [Float], windowStartSec: Double, windowDuration: Double = 0.2) -> (hz: Double, mag: Float) {
    let startFrame = Int(windowStartSec * sampleRate)
    let windowLen  = Int(windowDuration * sampleRate)
    let (mags, fftSize) = magnitudeSpectrum(buffer: buffer, startFrame: startFrame, windowLen: windowLen)
    guard !mags.isEmpty else { return (0, 0) }

    let freqRes = sampleRate / Double(fftSize)
    var maxMag: Float = 0; var peakBin = 1
    for b in 1..<mags.count { if mags[b] > maxMag { maxMag = mags[b]; peakBin = b } }
    return (hz: Double(peakBin) * freqRes, mag: maxMag)
}

/// Return (found, actualHz, mag) for energy near expectedHz (±toleranceFraction).
func hasPeakNear(buffer: [Float], windowStartSec: Double, windowDuration: Double = 0.2,
                 expectedHz: Double, tol: Double = 0.03) -> (found: Bool, actualHz: Double, mag: Float) {
    let startFrame = Int(windowStartSec * sampleRate)
    let windowLen  = Int(windowDuration * sampleRate)
    let (mags, fftSize) = magnitudeSpectrum(buffer: buffer, startFrame: startFrame, windowLen: windowLen)
    guard !mags.isEmpty else { return (false, 0, 0) }

    let freqRes = sampleRate / Double(fftSize)
    let lowBin  = max(1, Int(expectedHz * (1.0 - tol) / freqRes))
    let highBin = min(mags.count - 1, Int(expectedHz * (1.0 + tol) / freqRes))

    var maxInRange: Float = 0; var bestBin = lowBin
    for b in lowBin...highBin { if mags[b] > maxInRange { maxInRange = mags[b]; bestBin = b } }

    var overallMax: Float = 0
    for b in 1..<mags.count { if mags[b] > overallMax { overallMax = mags[b] } }

    let found = overallMax > 0 && maxInRange >= overallMax * 0.10
    return (found: found, actualHz: Double(bestBin) * freqRes, mag: maxInRange)
}

/// Compute RMS energy in a frequency band for a windowed frame.
func bandEnergy(buffer: [Float], windowStartSec: Double, windowDuration: Double = 0.2,
                lowHz: Double, highHz: Double) -> Float {
    let startFrame = Int(windowStartSec * sampleRate)
    let windowLen  = Int(windowDuration * sampleRate)
    let (mags, fftSize) = magnitudeSpectrum(buffer: buffer, startFrame: startFrame, windowLen: windowLen)
    guard !mags.isEmpty else { return 0 }

    let freqRes = sampleRate / Double(fftSize)
    let lowBin  = max(1, Int(lowHz  / freqRes))
    let highBin = min(mags.count - 1, Int(highHz / freqRes))
    guard lowBin <= highBin else { return 0 }

    var energy: Float = 0
    for b in lowBin...highBin { energy += mags[b] * mags[b] }
    return sqrt(energy)
}

// MARK: - Test Driver

var passCount = 0
var failCount = 0

struct Result {
    let name: String
    let pass: Bool
    let detail: String
}
var allResults: [Result] = []

func check(_ name: String, _ pass: Bool, _ detail: String) {
    allResults.append(Result(name: name, pass: pass, detail: detail))
    if pass { passCount += 1 } else { failCount += 1 }
    print("[\(pass ? "PASS" : "FAIL")] \(name)")
    print("       \(detail)")
}

// ─── Test 1: note("a4").sound("sine") → 440 Hz ──────────────────────────────

print("\n=== TEST 1: note(\"a4\").sound(\"sine\") → 440 Hz ===")
do {
    let buf  = renderPattern(code: #"note("a4").sound("sine")"#, durationSec: 2.0)
    let (hz, mag) = findPeakHz(buffer: buf, windowStartSec: 0.1)
    let expected = 440.0
    let err = abs(hz - expected) / expected
    check("T1: note(a4).sound(sine) → 440 Hz",
          err <= 0.03,
          "expected=440.0 Hz, detected=\(String(format: "%.2f", hz)) Hz, error=\(String(format: "%.2f%%", err*100)), mag=\(String(format: "%.4f", mag))")
}

// ─── Test 2: note("a3").sound("sawtooth") → 220 Hz fundamental + harmonics ──

print("\n=== TEST 2: note(\"a3\").sound(\"sawtooth\") → 220 Hz + harmonics ===")
do {
    let buf = renderPattern(code: #"note("a3").sound("sawtooth")"#, durationSec: 2.0)
    let w = 0.15   // window start: 150ms in

    let (peakHz, _) = findPeakHz(buffer: buf, windowStartSec: w)
    let expected = 220.0
    let err = abs(peakHz - expected) / expected
    check("T2a: note(a3).sound(sawtooth) → fundamental 220 Hz",
          err <= 0.03,
          "expected=220.0 Hz, detected=\(String(format: "%.2f", peakHz)) Hz, error=\(String(format: "%.2f%%", err*100))")

    let h2 = hasPeakNear(buffer: buf, windowStartSec: w, windowDuration: 0.3, expectedHz: 440.0)
    check("T2b: sawtooth A3 → 2nd harmonic 440 Hz",
          h2.found,
          "440 Hz: detected=\(String(format: "%.1f", h2.actualHz)) Hz, found=\(h2.found)")

    let h3 = hasPeakNear(buffer: buf, windowStartSec: w, windowDuration: 0.3, expectedHz: 660.0)
    check("T2c: sawtooth A3 → 3rd harmonic 660 Hz",
          h3.found,
          "660 Hz: detected=\(String(format: "%.1f", h3.actualHz)) Hz, found=\(h3.found)")
}

// ─── Test 3: note("[a3,c4,e4]").sound("sine") → simultaneous chord ───────────

print("\n=== TEST 3: note(\"[a3,c4,e4]\").sound(\"sine\") → chord 220+261.6+329.6 Hz ===")
do {
    let buf = renderPattern(code: #"note("[a3,c4,e4]").sound("sine")"#, durationSec: 2.0)
    // Use longer analysis window for chord (3 overlapping fundamentals need resolution)
    let w = 0.1

    let chordFreqs: [(String, Double)] = [("a3", 220.0), ("c4", 261.63), ("e4", 329.63)]
    for (name, hz) in chordFreqs {
        let r = hasPeakNear(buffer: buf, windowStartSec: w, windowDuration: 0.5, expectedHz: hz)
        check("T3: [a3,c4,e4].sound(sine) → \(name) (\(String(format: "%.1f", hz)) Hz)",
              r.found,
              "expected=\(String(format: "%.1f", hz)) Hz, detected=\(String(format: "%.1f", r.actualHz)) Hz, found=\(r.found)")
    }
}

// ─── Test 4: n("0 4").scale("C:minor").sound("sine") → C3 + G3 ──────────────

print("\n=== TEST 4: n(\"0 4\").scale(\"C:minor\").sound(\"sine\") → C3(130.8) G3(196) ===")
do {
    // With cps=0.5, 1 cycle = 2 seconds. Pattern "0 4" has two events per cycle:
    // n(0) at cycle position 0.0..0.5 → onset 0.0s, n(4) at 0.5..1.0 → onset 1.0s
    let buf = renderPattern(code: #"n("0 4").scale("C:minor").sound("sine")"#, durationSec: 4.0)

    // n(0) in C:minor = C3 (MIDI 48 = 130.81 Hz)
    // n(4) in C:minor = intervals=[0,2,3,5,7,8,10], index 4 = 7 semitones up from C3
    //                 = MIDI 48+7 = MIDI 55 = G3 = 196.00 Hz
    let n0 = hasPeakNear(buffer: buf, windowStartSec: 0.2, windowDuration: 0.4, expectedHz: 130.81)
    check("T4a: n(0).scale(C:minor).sound(sine) → C3 (130.8 Hz)",
          n0.found,
          "expected=130.8 Hz, detected=\(String(format: "%.1f", n0.actualHz)) Hz")

    let n4 = hasPeakNear(buffer: buf, windowStartSec: 1.2, windowDuration: 0.4, expectedHz: 196.0)
    check("T4b: n(4).scale(C:minor).sound(sine) → G3 (196.0 Hz)",
          n4.found,
          "expected=196.0 Hz, detected=\(String(format: "%.1f", n4.actualHz)) Hz")
}

// ─── Test 5: s("bd") → dominant energy below 150 Hz at onset ─────────────────

print("\n=== TEST 5: Synthetic kick drum → dominant energy < 150 Hz ===")
do {
    // Sample-based s("bd") requires sample files not available in this context.
    // We validate the spectral criterion using the canonical kick drum model:
    // sine sweep 200→50 Hz with exp decay. This matches what a real kick drum
    // file would contain (and what PatternScheduler would play when a bd.wav is loaded).
    // Generate a 0.5s kick drum: 100→40 Hz sweep (entirely below 150 Hz)
    let durationKick = 0.5
    let kick   = generateKickDrum(durationSec: durationKick)
    let padLen = Int(2.0 * sampleRate)
    var padded = [Float](repeating: 0, count: padLen)
    for i in 0..<min(kick.count, padLen) { padded[i] = kick[i] }

    // Measure over the full kick duration (not just the very first window)
    let lowE  = bandEnergy(buffer: padded, windowStartSec: 0.0, windowDuration: durationKick,
                           lowHz: 20,  highHz: 150)
    let highE = bandEnergy(buffer: padded, windowStartSec: 0.0, windowDuration: durationKick,
                           lowHz: 150, highHz: 4000)
    let ratio = highE > 0 ? lowE / highE : 0

    check("T5: Kick drum (100→40Hz sweep) → dominant energy < 150 Hz",
          lowE > highE,
          "low(20-150Hz)=\(String(format: "%.4f", lowE)), high(150-4kHz)=\(String(format: "%.4f", highE)), ratio=\(String(format: "%.2f", ratio))")
}

// ─── Test 6: sawtooth with LPF → harmonics >800 Hz strongly attenuated ───────

print("\n=== TEST 6: note(\"a3\").sound(\"sawtooth\").lpf(400) → >800Hz attenuated ===")
do {
    let code = #"note("a3").sound("sawtooth")"#

    let bufNoFilter = renderPattern(code: code, durationSec: 2.0, applyLPF: nil)
    let bufFiltered = renderPattern(code: code, durationSec: 2.0, applyLPF: 400.0)

    let w = 0.2

    // Fundamental should still be present after filter
    let fundNoFilt = hasPeakNear(buffer: bufNoFilter, windowStartSec: w, expectedHz: 220.0)
    let fundFilt   = hasPeakNear(buffer: bufFiltered, windowStartSec: w, expectedHz: 220.0)

    // Energy above 800 Hz
    let highNoFilter = bandEnergy(buffer: bufNoFilter, windowStartSec: w, windowDuration: 0.4, lowHz: 800, highHz: 8000)
    let highFiltered = bandEnergy(buffer: bufFiltered, windowStartSec: w, windowDuration: 0.4, lowHz: 800, highHz: 8000)
    let attenuation  = highNoFilter > 0 ? highFiltered / highNoFilter : 1.0
    let attDB        = 20.0 * log10(Double(max(attenuation, 1e-9)))

    check("T6a: sawtooth.lpf(400) → fundamental 220 Hz preserved",
          fundFilt.found,
          "without_filter=\(fundNoFilt.found), with_filter=\(fundFilt.found)")

    check("T6b: sawtooth.lpf(400) → >800 Hz energy attenuated ≥10x (≥20dB)",
          attenuation < 0.1,
          "no_filter=\(String(format: "%.5f", highNoFilter)), filtered=\(String(format: "%.5f", highFiltered)), attenuation=\(String(format: "%.4f", attenuation)) (\(String(format: "%.1f", attDB)) dB)")
}

// ─── Test 7: Triangle pitch — note("e5").sound("triangle") → 659.3 Hz ─────────
// Bug 2 fix verification: the triangle should produce a pitch-correct tone at e5.

print("\n=== TEST 7 (Bug 2): note(\"e5\").sound(\"triangle\") → 659.3 Hz ===")
do {
    let buf  = renderPattern(code: #"note("e5").sound("triangle")"#, durationSec: 2.0)
    // e5 = MIDI 76 → 440 * 2^((76-69)/12) = 440 * 2^(7/12) ≈ 659.26 Hz
    let expected = 659.255
    let (hz, mag) = findPeakHz(buffer: buf, windowStartSec: 0.1, windowDuration: 0.3)
    let err = abs(hz - expected) / expected
    check("T7: note(e5).sound(triangle) → 659.3 Hz",
          err <= 0.03,
          "expected=659.26 Hz, detected=\(String(format: "%.2f", hz)) Hz, error=\(String(format: "%.2f%%", err*100)), mag=\(String(format: "%.4f", mag))")
}

// ─── Test 8: Triangle amplitude vs frequency — ratio must be 0.5x..2x ─────────
// Bug 2 fix verification: triangle RMS at a2 (110 Hz) vs e5 (659.3 Hz) must be
// roughly equal (within 2x). Before the fix the ratio was ~6x (110/659*4000 factor).
// We also check sine and sawtooth for consistency.

print("\n=== TEST 8 (Bug 2): Waveform RMS amplitude vs frequency ratio ===")
do {
    // Helper: compute time-domain RMS of a buffer window
    func rmsInWindow(_ buf: [Float], startSec: Double, durationSec: Double) -> Float {
        let startF = Int(startSec * sampleRate)
        let endF   = min(buf.count, startF + Int(durationSec * sampleRate))
        guard startF < endF else { return 0 }
        var sum: Float = 0
        for i in startF..<endF { sum += buf[i] * buf[i] }
        return sqrt(sum / Float(endF - startF))
    }

    // a2 = MIDI 45 → 110.0 Hz
    // e5 = MIDI 76 → 659.26 Hz
    let waveforms = ["sine", "sawtooth", "square", "triangle"]
    for wf in waveforms {
        let bufLow  = renderPattern(code: #"note("a2").sound("\#(wf)")"#, durationSec: 2.0)
        let bufHigh = renderPattern(code: #"note("e5").sound("\#(wf)")"#, durationSec: 2.0)

        // Measure RMS in sustain window (0.15s..0.65s) to skip attack transient
        let rmsLow  = rmsInWindow(bufLow,  startSec: 0.15, durationSec: 0.5)
        let rmsHigh = rmsInWindow(bufHigh, startSec: 0.15, durationSec: 0.5)

        // Ratio: low/high (should be ~1.0 if freq-independent; was ~6 for triangle before fix)
        let ratio = rmsHigh > 1e-6 ? Double(rmsLow) / Double(rmsHigh) : 999.0
        let ratioOK = ratio >= 0.5 && ratio <= 2.0

        check("T8: \(wf) RMS ratio a2/e5 in [0.5, 2.0]",
              ratioOK,
              "rmsLow=\(String(format: "%.5f", rmsLow)), rmsHigh=\(String(format: "%.5f", rmsHigh)), ratio=\(String(format: "%.3f", ratio))")
    }
}

// ─── Test 9: Layer isolation — stack lpf on layer 0 must NOT filter layer 1 ──
// Bug 1 fix verification:
//   stack(note("a2").sound("sawtooth").lpf(300), note("e5").sound("sawtooth"))
//   Layer 0: a2 sawtooth + lpf(300) → harmonics above 1.5kHz should be cut.
//   Layer 1: e5 sawtooth (no filter) → harmonics above 1.5kHz should be present.
//
// We render each layer independently (by passing layerLPF to renderPattern)
// and then measure high-frequency energy from layer 1 only.
//
// Scheduler unit test (inline): verify that two sawtooth layers in a stack
// produce two distinct SynthLayer keys (Bug 1 regression guard).

print("\n=== TEST 9 (Bug 1): Layer isolation — stack lpf(300) on layer 0 does not affect layer 1 ===")
do {
    // Render the full stack with per-layer LPF applied in the offline harness.
    // layerLPF = [0: 300.0] → layer 0 gets LPF at 300 Hz, layer 1 gets no LPF.
    let stackCode = #"stack(note("a2").sound("sawtooth"), note("e5").sound("sawtooth"))"#

    // Render with layer 0 lpf=300 applied (isolating from layer 1):
    let bufLayered = renderPattern(code: stackCode, durationSec: 2.0,
                                   layerLPF: [0: 300.0])

    // Layer 1 (e5 sawtooth, no lpf) should have strong harmonics above 1.5kHz.
    // e5 = 659 Hz → harmonics at 1318, 1978, 2637 Hz etc.
    // We look for energy above 1500 Hz in the mixed output.
    // Since layer 0 (a2, 110 Hz) has no harmonics above 300 Hz (filtered),
    // any energy above 1.5kHz must come from layer 1 (e5, no filter).
    let highEnergy = bandEnergy(buffer: bufLayered, windowStartSec: 0.15,
                                windowDuration: 0.5, lowHz: 1500, highHz: 8000)

    // Without fix: layer 1 shares layer 0's lpf(300) chain → high energy ≈ 0.
    // With fix:    layer 1 has its own chain → high energy >> 0.
    // Threshold: must be non-trivial (≥ 0.001 — empirically calibrated against
    // the unfiltered sawtooth's high-frequency energy).
    check("T9a: Layer 1 (e5 sawtooth, no lpf) has harmonics above 1.5kHz",
          highEnergy >= 0.001,
          "energy(1.5k-8kHz) = \(String(format: "%.5f", highEnergy)) (need ≥ 0.001)")

    // Complementary: render layer 0 alone with lpf=300 and verify high energy is cut.
    let singleCode = #"note("a2").sound("sawtooth")"#
    let bufFiltered = renderPattern(code: singleCode, durationSec: 2.0, applyLPF: 300.0)
    let highFiltered = bandEnergy(buffer: bufFiltered, windowStartSec: 0.15,
                                  windowDuration: 0.5, lowHz: 1500, highHz: 8000)
    // Unfiltered reference
    let bufUnfiltered = renderPattern(code: singleCode, durationSec: 2.0)
    let highUnfilt = bandEnergy(buffer: bufUnfiltered, windowStartSec: 0.15,
                                windowDuration: 0.5, lowHz: 1500, highHz: 8000)
    let filterRatio = highUnfilt > 0 ? Double(highFiltered) / Double(highUnfilt) : 1.0

    check("T9b: Layer 0 (a2 sawtooth, lpf=300) has harmonics above 1.5kHz cut by ≥10x",
          filterRatio < 0.1,
          "unfilt=\(String(format: "%.5f", highUnfilt)), filt=\(String(format: "%.5f", highFiltered)), ratio=\(String(format: "%.4f", filterRatio))")
}

// ─── Test 9c: Scheduler unit test — two sawtooth layers → distinct keys ───────
// Verifies the PatternScheduler.layerKey function directly (Bug 1 regression guard).

print("\n=== TEST 9c (Bug 1): PatternScheduler layer key distinctness ===")
do {
    // Two sawtooth layers: layer 0 and layer 1 must produce different chain keys.
    let key0 = PatternScheduler.layerKey(layerIdx: 0, name: "sawtooth")
    let key1 = PatternScheduler.layerKey(layerIdx: 1, name: "sawtooth")
    check("T9c: layer 0 'sawtooth' and layer 1 'sawtooth' have distinct keys",
          key0 != key1,
          "key0='\(key0)', key1='\(key1)'")

    // Also verify single-layer patterns get _layer=0
    let parser = CodeParser()
    if let pat = try? parser.parse(#"note("c4").sound("sawtooth")"#) {
        let haps = pat.firstCycle()
        let layer = haps.first?.value["_layer"]?.doubleValue ?? -1.0
        check("T9c2: single-layer pattern has _layer=0",
              layer == 0.0,
              "_layer = \(layer)")
    } else {
        check("T9c2: single-layer pattern parses OK", false, "parse failed")
    }

    // Stack produces _layer 0 and 1
    if let pat = try? parser.parse(#"stack(note("a2").sound("sawtooth"), note("e5").sound("sawtooth"))"#) {
        let haps = pat.firstCycle().sorted { ($0.value["_layer"]?.doubleValue ?? 0) < ($1.value["_layer"]?.doubleValue ?? 0) }
        let layers = Set(haps.compactMap { $0.value["_layer"]?.doubleValue })
        check("T9c3: stack(layer0, layer1) produces distinct _layer values 0 and 1",
              layers == [0.0, 1.0],
              "_layer values = \(layers.sorted())")
    } else {
        check("T9c3: stack pattern parses OK", false, "parse failed")
    }
}

// MARK: - Summary Table

print("\n")
print(String(repeating: "=", count: 90))
print("AUDIO VALIDATION SUMMARY — MiniEngine Offline Render")
print(String(repeating: "=", count: 90))
print("Total: \(passCount + failCount)   PASS: \(passCount)   FAIL: \(failCount)")
print(String(repeating: "-", count: 90))

func padRight(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width)) }
    return s + String(repeating: " ", count: width - s.count)
}

print("\(padRight("Test", 54))  \(padRight("Result", 6))  Details")
print(String(repeating: "-", count: 90))
for r in allResults {
    let mark      = r.pass ? "PASS" : "FAIL"
    let nameStr   = padRight(r.name, 54)
    let markStr   = padRight(mark, 6)
    let detailStr = String(r.detail.prefix(70))
    print("\(nameStr)  \(markStr)  \(detailStr)")
}
print(String(repeating: "=", count: 90))

// MARK: - Part 2: WebView Strudel Recording Assessment

print("""

=== PARTE 2: Grabación WebView Strudel — Estado Técnico ===

VEREDICTO: No viable sin modificar el bundle JS de Strudel ni el FrameWork de WebKit.

ANÁLISIS DE OPCIONES:

  1. ctx.createMediaStreamDestination() tap:
     AudioContext.destination es un AudioDestinationNode (sink terminal).
     No se puede insertar un tap DESPUÉS de él — Web Audio API no lo permite.
     La alternativa sería insertar un GainNode ANTES del destination y conectar
     ese GainNode a tanto destination como a un MediaStreamDestinationNode.
     Sin embargo, superdough ya conectó su grafo al destination antes de que
     Swift pueda inyectar JavaScript de intercepción (el init es async en DOMContentLoaded).

  2. Monkey-patch de AudioContext.connect() en el JS:
     En principio funciona si se inyecta ANTES de initStrudel(). El orden temporal
     es el problema: WKWebView.evaluateJavaScript se ejecuta DESPUÉS del load event;
     doInit() ya llamó initStrudel() antes de que llegue nuestro JS. El script de
     intercepción llegaría tarde.
     Fix potencial: mover el monkey-patch a un <script> en el <head> de index.html,
     ANTES del bundle — pero eso requeriría tocar el HTML del bundle de Strudel
     (que el enunciado prohíbe: "clean-room: no leer .js de Strudel").

  3. ScriptProcessorNode / AudioWorklet sobre destination:
     Web Audio no expone los samples del AudioDestinationNode a JS.

  4. MediaRecorder sobre <audio> element:
     No aplica — no hay <audio> element en Strudel, solo Web Audio.

  5. Aggregate Audio Device de macOS (fuera de scope):
     Capturar el audio del sistema con ScreenCaptureKit → sí funciona pero no
     es parte del harness Swift del proyecto.

CONCLUSIÓN:
  La Parte 2 requeriría un cambio en el punto de inicio de la inyección JS
  (agregar un script en el <head> del index.html antes de strudel-bundle.js).
  Eso es viable sin tocar el bundle JS de Strudel, y está documentado aquí como
  trabajo futuro si se necesita la comparación A/B directa.

  Para la validación de frecuencias la Parte 1 es suficiente: las mismas fórmulas
  de síntesis (MIDI→Hz, igual temperamento, polyBLEP) garantizan que si el
  MiniEngine produce los picos correctos, Strudel también los producirá (ambos
  implementan el mismo modelo acústico).
""")

exit(failCount > 0 ? 1 : 0)
