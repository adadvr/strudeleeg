// ---------------------------------------------------------------------------
// P03P04Tests — Tests for P0-3 (per-event biquad filters) and P0-4 (orbit buses).
//
// P0-3 Biquads:
//   • Correct biquad LPF coefficients (frequency response at DC and Nyquist).
//   • Correct biquad HPF coefficients.
//   • High-Q resonance peak: LPF at fc with Q=10 should peak near fc.
//   • Two simultaneous voices with different LPF → independently filtered output.
//   • Per-event LPF on sample buffer: biquadLPF attenuates above-cutoff energy.
//   • SynthVoice trigger() sets biquad filters correctly.
//
// P0-4 Orbit:
//   • orbit() control field parsed from CodeParser.
//   • Default orbit = 1 (no explicit orbit → orbit field absent or 1).
//   • orbit key appears in hap control map.
//   • PatternScheduler.defaultOrbit == 1.
//
// ---------------------------------------------------------------------------

import XCTest
import AVFoundation
@testable import MiniEngine

final class P03P04Tests: XCTestCase {

    // MARK: - P0-3: Biquad coefficient correctness

    /// LPF at 1 kHz with Q=0.707 (Butterworth).
    /// At DC (f=0): gain should be ≈ 1.0 (pass).
    /// At Nyquist (f=22050): gain should be ≈ 0 (stop).
    func testBiquadLPFCoefficients() {
        let fs = 44100.0
        let fc = 1000.0
        let q  = 0.707
        let f = biquadLPF(fc: fc, q: q, fs: fs)

        // H(z) at z=1 (DC, f=0): H(1) = (b0+b1+b2)/(1+a1+a2) (using our sign convention)
        // Our convention: y = nb0*x + nb1*x1 + nb2*x2 - na1*y1 - na2*y2
        // H(z=1) = (nb0+nb1+nb2)/(1+na1+na2)
        let hDC = (f.nb0 + f.nb1 + f.nb2) / (1 + f.na1 + f.na2)
        XCTAssertEqual(hDC, 1.0, accuracy: 0.01, "LPF gain at DC should be ~1.0")

        // H(z=-1) at Nyquist (f=fs/2): H(-1) = (nb0-nb1+nb2)/(1-na1+na2)
        let hNyq = (f.nb0 - f.nb1 + f.nb2) / (1 - f.na1 + f.na2)
        XCTAssertEqual(hNyq, 0.0, accuracy: 0.01, "LPF gain at Nyquist should be ~0")

        XCTAssertFalse(f.bypass, "LPF should not be bypassed")
    }

    /// HPF at 1 kHz with Q=0.707.
    /// At DC: gain should be ≈ 0.
    /// At Nyquist: gain should be ≈ 1.
    func testBiquadHPFCoefficients() {
        let fs = 44100.0
        let fc = 1000.0
        let q  = 0.707
        let f = biquadHPF(fc: fc, q: q, fs: fs)

        let hDC = (f.nb0 + f.nb1 + f.nb2) / (1 + f.na1 + f.na2)
        XCTAssertEqual(hDC, 0.0, accuracy: 0.01, "HPF gain at DC should be ~0")

        let hNyq = (f.nb0 - f.nb1 + f.nb2) / (1 - f.na1 + f.na2)
        XCTAssertEqual(hNyq, 1.0, accuracy: 0.01, "HPF gain at Nyquist should be ~1.0")

        XCTAssertFalse(f.bypass, "HPF should not be bypassed")
    }

    /// High-Q LPF (Q=10) at fc: the gain at fc should be significantly above 1.0
    /// (resonance peak). This validates that Q is correctly wired.
    func testBiquadLPFHighQResonancePeak() {
        let fs = 44100.0
        let fc = 2000.0
        let q  = 10.0
        var f = biquadLPF(fc: fc, q: q, fs: fs)

        // Process a sine wave at fc through the filter for a while, measure output amplitude.
        let nSamples = 4096
        let dt = fc / fs
        var phase = 0.0
        var maxOut: Double = 0.0
        for _ in 0..<nSamples {
            let s = sin(2.0 * Double.pi * phase)
            let y = f.process(s)
            if abs(y) > maxOut { maxOut = abs(y) }
            phase += dt
            if phase >= 1.0 { phase -= 1.0 }
        }
        // With Q=10, peak gain = Q ≈ 10 at fc.
        // We don't check the exact peak (it depends on transient settling),
        // but maxOut should be >> 1 (at least 3×).
        XCTAssertGreaterThan(maxOut, 3.0, "High-Q LPF at fc should have resonance peak > 3×")
    }

    /// Two independent BiquadFilter instances with different cutoffs should produce
    /// different outputs for the same input.
    func testTwoBiquadsIndependent() {
        var lpf200 = biquadLPF(fc: 200.0, q: 0.707, fs: 44100.0)
        var lpf8000 = biquadLPF(fc: 8000.0, q: 0.707, fs: 44100.0)

        // Feed a 1kHz sine through both
        let nSamples = 512
        let dt = 1000.0 / 44100.0
        var phase = 0.0
        var out200: [Double] = []
        var out8k: [Double] = []
        for _ in 0..<nSamples {
            let s = sin(2.0 * Double.pi * phase)
            out200.append(lpf200.process(s))
            out8k.append(lpf8000.process(s))
            phase += dt
            if phase >= 1.0 { phase -= 1.0 }
        }

        // LPF at 200 Hz should attenuate 1 kHz heavily.
        // LPF at 8 kHz should pass 1 kHz with near unity gain.
        let rms200 = sqrt(out200.suffix(256).map { $0 * $0 }.reduce(0, +) / 256.0)
        let rms8k  = sqrt(out8k.suffix(256).map { $0 * $0 }.reduce(0, +) / 256.0)

        // rms8k should be much larger than rms200 (roughly 40× for a 2nd-order filter
        // at f=5×fc — theoretical ~(fc/f)^2 attenuation)
        XCTAssertGreaterThan(rms8k / max(rms200, 1e-9), 5.0,
                             "LPF 8kHz should pass 1kHz much better than LPF 200Hz")

        // Also verify they're truly independent (state is separate)
        XCTAssertNotEqual(rms200, rms8k, accuracy: 0.001, "Two different LPFs should give different output")
    }

    // MARK: - P0-3: Per-event sample biquad (lpfBuffer / hpfBufferApply)

    func testLpfBufferAttenuatesHighFreqs() throws {
        // Create a synthetic stereo buffer with white noise
        let sr = 44100.0
        let nFrames = 4096
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(nFrames)) else {
            XCTFail("Could not create buffer"); return
        }
        buf.frameLength = AVAudioFrameCount(nFrames)
        guard let ch = buf.floatChannelData else { XCTFail("No channel data"); return }
        // Fill with pseudo-noise (deterministic)
        var phase = 0.0
        for i in 0..<nFrames {
            // Mix of 200 Hz + 5000 Hz to have energy at both frequencies
            let s = Float(0.5 * sin(2.0 * .pi * 200.0 * Double(i) / sr)
                        + 0.5 * sin(2.0 * .pi * 5000.0 * Double(i) / sr))
            ch[0][i] = s
            ch[1][i] = s
            phase += 1.0 / sr
        }

        // Apply LPF at 500 Hz (should pass 200 Hz, cut 5 kHz)
        let filtered = lpfBuffer(buf, cutoffHz: 500.0, q: 0.707)
        guard let fch = filtered.floatChannelData else { XCTFail("No filtered channel data"); return }

        // Measure energy at the two frequency bands by counting sign-changes approximate
        // (simpler: measure RMS of filtered vs unfiltered)
        var rmsOrig: Float = 0; var rmsFilt: Float = 0
        for i in 0..<nFrames {
            rmsOrig += ch[0][i] * ch[0][i]
            rmsFilt += fch[0][i] * fch[0][i]
        }
        rmsOrig = sqrt(rmsOrig / Float(nFrames))
        rmsFilt = sqrt(rmsFilt / Float(nFrames))

        // After LPF at 500 Hz, 5 kHz component is heavily attenuated.
        // The 200 Hz component passes. Expected: filtered RMS much lower than original
        // (original has both components contributing equally).
        // The 5 kHz contribution to RMS at 4th-order roll-off is ≈ (500/5000)^2 = 0.01.
        // So filtered should be approximately rmsFilt ≈ 0.5*sin_rms(200Hz) ≈ 0.35.
        // Original ≈ sqrt(0.5^2 + 0.5^2)/sqrt(2) ≈ 0.5.
        // Ratio rmsFilt/rmsOrig should be < 0.8 (significant attenuation of 5kHz component).
        XCTAssertLessThan(rmsFilt / rmsOrig, 0.9,
                          "LPF at 500 Hz should reduce RMS (5kHz component attenuated)")
    }

    func testHpfBufferAttenuatesLowFreqs() throws {
        let sr = 44100.0
        let nFrames = 4096
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(nFrames)) else {
            XCTFail("Could not create buffer"); return
        }
        buf.frameLength = AVAudioFrameCount(nFrames)
        guard let ch = buf.floatChannelData else { XCTFail("No channel data"); return }
        for i in 0..<nFrames {
            let s = Float(0.5 * sin(2.0 * .pi * 100.0 * Double(i) / sr)
                        + 0.5 * sin(2.0 * .pi * 8000.0 * Double(i) / sr))
            ch[0][i] = s
            ch[1][i] = s
        }

        // Apply HPF at 1000 Hz (should pass 8 kHz, cut 100 Hz)
        let filtered = hpfBufferApply(buf, cutoffHz: 1000.0, q: 0.707)
        guard let fch = filtered.floatChannelData else { XCTFail("No filtered channel data"); return }

        var rmsOrig: Float = 0; var rmsFilt: Float = 0
        for i in 0..<nFrames {
            rmsOrig += ch[0][i] * ch[0][i]
            rmsFilt += fch[0][i] * fch[0][i]
        }
        rmsOrig = sqrt(rmsOrig / Float(nFrames))
        rmsFilt = sqrt(rmsFilt / Float(nFrames))

        // After HPF at 1 kHz, 100 Hz component is attenuated.
        // Filtered RMS should be < original (low-freq removed).
        XCTAssertLessThan(rmsFilt / rmsOrig, 0.9,
                          "HPF at 1 kHz should reduce RMS (100 Hz component attenuated)")
    }

    // MARK: - P0-3: SynthVoice per-voice biquad via direct render

    /// Two SynthVoice instances triggered with different lpfHz values should produce
    /// different output for the same frequency/gain input.
     /// Two SynthVoice instances triggered with different filter settings should produce
    /// different output — verifying independent per-voice biquad state.
    func testTwoSimultaneousVoicesIndependentLPF() {
        let sr = 44100.0
        let nFrames = 8192

        let voice1 = SynthVoice()
        let voice2 = SynthVoice()

        // voice1: 110 Hz sawtooth, lpf at 200 Hz (only ~fundamental passes)
        // voice2: 110 Hz sawtooth, no lpf (all harmonics pass)
        voice1.trigger(
            waveform: "sawtooth", freq: 110.0, gain: 1.0,
            attack: 0.001, decay: 0.001, sustain: 0.99, release: 0.1,
            durationSec: 2.0, sampleRate: sr, birthSample: 1, startHostSeconds: 0.0,
            lpfHz: 200.0, resonanceQ: 0.707)

        voice2.trigger(
            waveform: "sawtooth", freq: 110.0, gain: 1.0,
            attack: 0.001, decay: 0.001, sustain: 0.99, release: 0.1,
            durationSec: 2.0, sampleRate: sr, birthSample: 2, startHostSeconds: 0.0)
        // No lpfHz → bypass

        let buf1 = UnsafeMutablePointer<Float>.allocate(capacity: nFrames)
        let buf2 = UnsafeMutablePointer<Float>.allocate(capacity: nFrames)
        defer { buf1.deallocate(); buf2.deallocate() }
        buf1.initialize(repeating: 0, count: nFrames)
        buf2.initialize(repeating: 0, count: nFrames)

        voice1.render(into: buf1, frameCount: nFrames, bufferStartSeconds: 0, sampleRate: sr)
        voice2.render(into: buf2, frameCount: nFrames, bufferStartSeconds: 0, sampleRate: sr)

        // Skip first 2048 samples (transient settling)
        let skipFrames = 2048
        var rms1: Float = 0; var rms2: Float = 0
        for i in skipFrames..<nFrames {
            rms1 += buf1[i] * buf1[i]
            rms2 += buf2[i] * buf2[i]
        }
        let n = Float(nFrames - skipFrames)
        rms1 = sqrt(rms1 / n)
        rms2 = sqrt(rms2 / n)

        // Both should have signal
        XCTAssertGreaterThan(rms1, 0.001, "Filtered voice should have non-trivial output")
        XCTAssertGreaterThan(rms2, 0.001, "Unfiltered voice should have non-trivial output")

        // Primary assertion: the two outputs differ (independent biquad states).
        // With lpf=200Hz on 110Hz saw: 2nd harmonic (220Hz) is at cutoff → attenuated.
        // Without filter: all harmonics present. Outputs must differ.
        XCTAssertNotEqual(rms1, rms2, accuracy: 0.001,
            "Two voices with different LPF settings must produce different output (independent biquad state)")
    }

    func testVoiceLPFBypassHasMoreHarmonics() {
        let sr = 44100.0
        let nFrames = 8192

        let voiceFull = SynthVoice()
        let voiceFiltered = SynthVoice()

        voiceFull.trigger(
            waveform: "sawtooth", freq: 220.0, gain: 1.0,
            attack: 0.001, decay: 0.05, sustain: 0.9, release: 0.1,
            durationSec: 2.0, sampleRate: sr, birthSample: 1, startHostSeconds: 0.0)
        // lpfHz nil → bypass

        voiceFiltered.trigger(
            waveform: "sawtooth", freq: 220.0, gain: 1.0,
            attack: 0.001, decay: 0.05, sustain: 0.9, release: 0.1,
            durationSec: 2.0, sampleRate: sr, birthSample: 2, startHostSeconds: 0.0,
            lpfHz: 400.0, resonanceQ: 0.707)

        let bufFull = UnsafeMutablePointer<Float>.allocate(capacity: nFrames)
        let bufFilt = UnsafeMutablePointer<Float>.allocate(capacity: nFrames)
        defer { bufFull.deallocate(); bufFilt.deallocate() }
        bufFull.initialize(repeating: 0, count: nFrames)
        bufFilt.initialize(repeating: 0, count: nFrames)

        voiceFull.render(into: bufFull, frameCount: nFrames, bufferStartSeconds: 0, sampleRate: sr)
        voiceFiltered.render(into: bufFilt, frameCount: nFrames, bufferStartSeconds: 0, sampleRate: sr)

        // Measure high-frequency energy (above 1 kHz) in both outputs.
        // For 220 Hz saw: harmonics at 440, 660, 880, 1100, 1320...
        // After LPF at 400 Hz, harmonics >= 5th (1100 Hz) are significantly attenuated.
        // Simple proxy: compare values at sample offsets corresponding to high-freq cycles.
        // Use variance as a proxy for high-frequency content.
        let skipFrames = 1024
        var var_full: Float = 0; var var_filt: Float = 0
        var mean_full: Float = 0; var mean_filt: Float = 0
        let ns = nFrames - skipFrames
        for i in skipFrames..<nFrames {
            mean_full += bufFull[i]
            mean_filt += bufFilt[i]
        }
        mean_full /= Float(ns)
        mean_filt /= Float(ns)
        for i in skipFrames..<nFrames {
            var_full += (bufFull[i] - mean_full) * (bufFull[i] - mean_full)
            var_filt += (bufFilt[i] - mean_filt) * (bufFilt[i] - mean_filt)
        }
        // Both should have signal (variance > 0)
        XCTAssertGreaterThan(var_full, 0.001, "Full voice should have non-zero variance")
        XCTAssertGreaterThan(var_filt, 0.001, "Filtered voice should have non-zero variance")

        // Full voice (no LPF) should have higher or similar RMS than filtered
        // (filtering can only reduce energy)
        let rms_full = sqrt(var_full / Float(ns))
        let rms_filt = sqrt(var_filt / Float(ns))
        XCTAssertGreaterThanOrEqual(rms_full, rms_filt * 0.9,
            "Full voice (no LPF) should have >= RMS of filtered voice")
    }

    // MARK: - P0-4: orbit control in ControlPattern

    func testOrbitControlFieldParsed() throws {
        let pat = try CodeParser().parse(#"s("bd").orbit(2)"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty, "orbit(2) pattern should produce haps")
        guard let hap = haps.first else { return }
        let orbitVal = hap.value["orbit"]?.doubleValue
        XCTAssertNotNil(orbitVal, "orbit field should be present in control map")
        XCTAssertEqual(orbitVal ?? -1, 2.0, accuracy: 1e-9, "orbit value should be 2")
    }

    func testOrbitDefaultAbsentMeansDefault() throws {
        // Without .orbit(), no orbit field in the map (scheduler defaults to 1)
        let pat = try CodeParser().parse(#"s("bd")"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty, "s(bd) pattern should produce haps")
        guard let hap = haps.first else { return }
        // No orbit field present — scheduler defaults to PatternScheduler.defaultOrbit
        let orbitVal = hap.value["orbit"]?.doubleValue
        // Either nil or 1 is acceptable; scheduler uses defaultOrbit if nil
        if let v = orbitVal {
            XCTAssertEqual(v, 1.0, accuracy: 1e-9, "If orbit is set without explicit call, default should be 1")
        }
        // No assertion for nil — nil is expected (no .orbit() call)
    }

    func testOrbitDefaultOrbitConstant() {
        XCTAssertEqual(PatternScheduler.defaultOrbit, 1,
                       "Default orbit should be 1 per Strudel docs")
    }

    func testOrbitPatternableAlternates() throws {
        // .orbit("<1 2>") should produce orbit=1 in cycle 0 and orbit=2 in cycle 1
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd").orbit("<1 2>")"#)

        let haps0 = pat.query(TimeSpan(Rational(0), Rational(1)))
        let haps1 = pat.query(TimeSpan(Rational(1), Rational(2)))

        let orbit0 = haps0.first?.value["orbit"]?.doubleValue
        let orbit1 = haps1.first?.value["orbit"]?.doubleValue

        XCTAssertEqual(orbit0 ?? -1, 1.0, accuracy: 1e-9, "Cycle 0: orbit should be 1")
        XCTAssertEqual(orbit1 ?? -1, 2.0, accuracy: 1e-9, "Cycle 1: orbit should be 2")
    }

    func testOrbitStackDistinctOrbits() throws {
        let pat = try CodeParser().parse("""
            stack(
                s("bd").orbit(1),
                s("sd").orbit(2)
            )
            """)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 2, "stack with 2 elements should produce 2 haps")
        let orbits = Set(haps.compactMap { $0.value["orbit"]?.doubleValue })
        XCTAssertEqual(orbits, [1.0, 2.0], "Should have orbits 1 and 2")
    }

    // MARK: - P0-3 regression: existing LPF semantics still work (control field)

    func testLpfControlFieldStillPresentInControlMap() throws {
        let pat = try CodeParser().parse(#"s("sawtooth").lpf(400)"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty, "lpf pattern should produce haps")
        let lpfVal = haps.first?.value["lpf"]?.doubleValue
        XCTAssertNotNil(lpfVal, "lpf field should be present in control map")
        XCTAssertEqual(lpfVal ?? -1, 400.0, accuracy: 1e-9, "lpf value should be 400")
    }

    func testHpfControlFieldPresentInControlMap() throws {
        let pat = try CodeParser().parse(#"s("sawtooth").hpf(200)"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        let hpfVal = haps.first?.value["hpf"]?.doubleValue
        XCTAssertNotNil(hpfVal, "hpf field should be present")
        XCTAssertEqual(hpfVal ?? -1, 200.0, accuracy: 1e-9)
    }

    func testResonanceControlFieldPresentInControlMap() throws {
        let pat = try CodeParser().parse(#"s("sawtooth").resonance(10)"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        let resVal = haps.first?.value["resonance"]?.doubleValue
        XCTAssertNotNil(resVal, "resonance field should be present")
        XCTAssertEqual(resVal ?? -1, 10.0, accuracy: 1e-9)
    }

    // MARK: - P0-3: biquad bypass flag

    func testBiquadBypassIsDefaultTrue() {
        let f = BiquadFilter()
        XCTAssertTrue(f.bypass, "Default BiquadFilter should be bypass=true (no effect)")
    }

    func testBiquadLPFBypassFalse() {
        let f = biquadLPF(fc: 1000, q: 0.707, fs: 44100)
        XCTAssertFalse(f.bypass, "biquadLPF() should return bypass=false")
    }

    func testBiquadHPFBypassFalse() {
        let f = biquadHPF(fc: 1000, q: 0.707, fs: 44100)
        XCTAssertFalse(f.bypass, "biquadHPF() should return bypass=false")
    }

    func testBiquadBypassPassesInputUnchanged() {
        var f = BiquadFilter()  // bypass=true
        let xs: [Double] = [0.5, -0.3, 0.1, 0.9, -0.7]
        for x in xs {
            let y = f.process(x)
            XCTAssertEqual(y, x, accuracy: 1e-12, "Bypass filter should pass input unchanged")
        }
    }

    // MARK: - P0-3: biquad state reset

    func testBiquadResetStateClearsDelayLines() {
        var f = biquadLPF(fc: 1000, q: 5.0, fs: 44100)
        // Process some samples to get z1/z2 non-zero
        for _ in 0..<100 { _ = f.process(0.5) }
        // Reset
        f.resetState()
        XCTAssertEqual(f.z1, 0.0, accuracy: 1e-12, "z1 should be reset to 0")
        XCTAssertEqual(f.z2, 0.0, accuracy: 1e-12, "z2 should be reset to 0")
    }
}
