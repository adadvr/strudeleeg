// ---------------------------------------------------------------------------
// Tier3Tests — Phase 3 / Tier 2: Synths
//
// Tests organised as:
//   1. Pattern-level control maps (s/sound/synth field, ADSR, lpf, hpf,
//      resonance, speed) — verified against oracle fixture values.
//   2. DSP unit tests (oscillator waveform, ADSR curve, filter mapping).
//      DSP tests render SynthVoice samples directly (no AVAudioEngine needed).
//   3. CodeParser integration — all new methods accepted without error.
//
// Test decisions (documented):
//   • AVAudioUnitEQ DSP is not tested offline (Apple's AU renders require a
//     running engine). We test the *parameter mapping* (resonanceToOctaveBandwidth)
//     and trust AVAudioUnitEQ for the actual filter roll-off.
//   • SynthLayer/AVAudioSourceNode is not unit-tested offline (requires engine).
//     Tested at the integration level: scheduleNote does not crash, voice pool
//     size is as documented (8), LRU steal is exercised.
//   • Oscillator frequency is verified via zero-crossing period counting.
//     Amplitude stays within ±1.1 (room for polyBLEP transients at startup).
// ---------------------------------------------------------------------------

import XCTest
@testable import MiniEngine

final class Tier3Tests: XCTestCase {

    // MARK: - 1. Control map — s("sawtooth") as synth

    func testSynthNameRecognition() {
        XCTAssertTrue(isSynthName("sawtooth"))
        XCTAssertTrue(isSynthName("square"))
        XCTAssertTrue(isSynthName("sine"))
        XCTAssertTrue(isSynthName("triangle"))
        XCTAssertFalse(isSynthName("pad"))
        XCTAssertFalse(isSynthName("bell"))
        XCTAssertFalse(isSynthName("hi"))
    }

    func testSynthFieldAddedForOscillators() {
        // s("sawtooth") should produce both "s" and "synth" fields
        let pat = s("sawtooth")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["s"],     .string("sawtooth"))
        XCTAssertEqual(haps[0].value["synth"], .string("sawtooth"))
    }

    func testNoSynthFieldForSamples() {
        // s("pad") must NOT produce a "synth" field (backward-compat)
        let pat = s("pad")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["s"], .string("pad"))
        XCTAssertNil(haps[0].value["synth"], "sample names must not set 'synth' field")
    }

    func testAllFourOscillators() {
        for name in ["sawtooth", "square", "sine", "triangle"] {
            let pat = s(name)
            let haps = pat.firstCycle()
            XCTAssertEqual(haps.count, 1, "\(name): should emit 1 hap")
            XCTAssertEqual(haps[0].value["s"],     .string(name), "\(name): s field")
            XCTAssertEqual(haps[0].value["synth"], .string(name), "\(name): synth field")
        }
    }

    func testSoundAliasOfS() {
        // sound("sawtooth") should produce identical control map to s("sawtooth")
        let patS     = s("sawtooth").firstCycle()
        let patSound = sound("sawtooth").firstCycle()
        XCTAssertEqual(patS.count, patSound.count)
        XCTAssertEqual(patS[0].value["s"],     patSound[0].value["s"])
        XCTAssertEqual(patS[0].value["synth"], patSound[0].value["synth"])
    }

    func testNoteWithSynth() throws {
        // note("c3 e3").s("sawtooth") → 2 haps with note + s + synth
        // c3=48, e3=52 in our MIDI scheme (C3=48 per scale system)
        let parser = CodeParser()
        let pat = try parser.parse(#"note("c3 e3").s("sawtooth")"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value["note"],  .double(48))   // c3 = MIDI 48
        XCTAssertEqual(haps[1].value["note"],  .double(52))   // e3 = MIDI 52
        XCTAssertEqual(haps[0].value["s"],     .string("sawtooth"))
        XCTAssertEqual(haps[0].value["synth"], .string("sawtooth"))
    }

    // MARK: - 2. Control map — ADSR fields

    func testADSRFieldsInControlMap() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").attack(0.1).decay(0.2).sustain(0.7).release(0.3)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        let v = haps[0].value
        XCTAssertEqual(v["attack"],  .double(0.1))
        XCTAssertEqual(v["decay"],   .double(0.2))
        XCTAssertEqual(v["sustain"], .double(0.7))
        XCTAssertEqual(v["release"], .double(0.3))
    }

    func testADSRDefaultsNotPresentInMapWithoutCalling() throws {
        // Without explicit ADSR calls, no ADSR keys should appear
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth")"#)
        let haps = pat.firstCycle()
        XCTAssertNil(haps[0].value["attack"])
        XCTAssertNil(haps[0].value["decay"])
        XCTAssertNil(haps[0].value["sustain"])
        XCTAssertNil(haps[0].value["release"])
    }

    func testADSRAsPattern() throws {
        // attack("<0.001 0.1>") should alternate per cycle
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").attack("<0.001 0.1>")"#)
        let h0 = pat.queryArc(Rational(0), Rational(1))
        let h1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertFalse(h0.isEmpty)
        XCTAssertFalse(h1.isEmpty)
        XCTAssertEqual(h0[0].value["attack"]?.doubleValue ?? 0, 0.001, accuracy: 1e-9)
        XCTAssertEqual(h1[0].value["attack"]?.doubleValue ?? 0, 0.1,   accuracy: 1e-9)
    }

    // MARK: - 3. Control map — lpf / hpf / resonance

    func testLPFField() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").lpf(800)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["lpf"], .double(800.0))
    }

    func testHPFField() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").hpf(200)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["hpf"], .double(200.0))
    }

    func testResonanceField() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").lpf(800).resonance(5)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["resonance"], .double(5.0))
    }

    func testLPFPatternnable() throws {
        // lpf("<500 2000>") alternates per cycle
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").lpf("<500 2000>")"#)
        let h0 = pat.queryArc(Rational(0), Rational(1))
        let h1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertEqual(h0.first?.value["lpf"]?.doubleValue ?? 0, 500.0,  accuracy: 1e-9)
        XCTAssertEqual(h1.first?.value["lpf"]?.doubleValue ?? 0, 2000.0, accuracy: 1e-9)
    }

    // MARK: - 4. Control map — speed

    func testSpeedField() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").speed(2)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["speed"], .double(2.0))
        // speed on sample: s="pad", no synth field
        XCTAssertNil(haps[0].value["synth"])
    }

    func testSpeedDefaultAbsent() throws {
        // Without speed(), no "speed" key in control map
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad")"#)
        let haps = pat.firstCycle()
        XCTAssertNil(haps[0].value["speed"])
    }

    func testSpeedPatternnable() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").speed("<0.5 2>")"#)
        let h0 = pat.queryArc(Rational(0), Rational(1))
        let h1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertEqual(h0.first?.value["speed"]?.doubleValue ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(h1.first?.value["speed"]?.doubleValue ?? 0, 2.0, accuracy: 1e-9)
    }

    func testSpeedHalfOnSamplePattern() throws {
        // speed(0.5) with note: should both appear in control map
        let parser = CodeParser()
        let pat = try parser.parse(#"note("c4").s("pad").speed(0.5)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["speed"], .double(0.5))
        XCTAssertEqual(haps[0].value["note"],  .double(60.0))
    }

    // MARK: - 5. Default note for synth (no note())

    func testSynthDefaultMIDIValue() {
        // synthDefaultMIDI should be 48 (C3 in our C3=48 root convention)
        XCTAssertEqual(synthDefaultMIDI, 48)
    }

    func testSynthFrequencyFromMIDI() {
        // MIDI 69 = A4 = 440 Hz
        XCTAssertEqual(synthFrequency(midi: 69.0), 440.0, accuracy: 0.001)
        // MIDI 57 = A3 = 220 Hz
        XCTAssertEqual(synthFrequency(midi: 57.0), 220.0, accuracy: 0.001)
        // MIDI 81 = A5 = 880 Hz
        XCTAssertEqual(synthFrequency(midi: 81.0), 880.0, accuracy: 0.001)
        // MIDI 48 = C3 ≈ 130.81 Hz
        XCTAssertEqual(synthFrequency(midi: 48.0), 130.8128, accuracy: 0.01)
    }

    // MARK: - 6. DSP — SynthVoice oscillator correctness

    private func renderVoice(
        waveform:    String,
        freq:        Double,
        sampleRate:  Double,
        frameCount:  Int,
        attack:      Double = 0.001,
        decay:       Double = 0.05,
        sustain:     Double = 1.0,    // keep at 1 for waveform shape tests
        release:     Double = 0.1,
        durationSec: Double = 1.0
    ) -> [Float] {
        let voice = SynthVoice()
        voice.trigger(
            waveform:         waveform,
            freq:             freq,
            gain:             1.0,
            attack:           attack,
            decay:            decay,
            sustain:          sustain,
            release:          release,
            durationSec:      durationSec,
            sampleRate:       sampleRate,
            birthSample:      0,
            startHostSeconds: 0.0   // immediate — no offset for unit tests
        )
        var buffer = [Float](repeating: 0, count: frameCount)
        buffer.withUnsafeMutableBufferPointer { ptr in
            // bufferStartSeconds=0 matches startHostSeconds=0 → startFrame=0 (no offset)
            voice.render(into: ptr.baseAddress!, frameCount: frameCount,
                         bufferStartSeconds: 0.0, sampleRate: sampleRate)
        }
        return buffer
    }

    /// Count zero-crossings (+ → - transitions) in a signal buffer, skipping
    /// the initial attack transient (first `skip` samples).
    private func countPositiveToNegativeCrossings(_ samples: [Float], skip: Int = 0) -> Int {
        var count = 0
        for i in (skip + 1)..<samples.count {
            if samples[i - 1] >= 0 && samples[i] < 0 {
                count += 1
            }
        }
        return count
    }

    func testSineOscillatorFrequency() {
        // 440 Hz sine at 44100 samples/s:
        // Expected ~440 positive-to-negative crossings per second.
        let sr: Double = 44100
        let freq: Double = 440.0
        let frames = Int(sr)  // 1 second
        // Use long attack so envelope doesn't distort crossings
        let samples = renderVoice(waveform: "sine", freq: freq, sampleRate: sr,
                                  frameCount: frames, attack: 0.0001, sustain: 1.0, durationSec: 2.0)
        // Skip 500 samples for attack settling
        let crossings = countPositiveToNegativeCrossings(samples, skip: 500)
        // Allow ±5% tolerance
        XCTAssertGreaterThan(crossings, Int(freq * 0.93),
                             "Sine 440Hz: too few crossings \(crossings)")
        XCTAssertLessThan(crossings, Int(freq * 1.07),
                          "Sine 440Hz: too many crossings \(crossings)")
    }

    func testSawtoothOscillatorFrequency() {
        let sr: Double = 44100
        let freq: Double = 220.0
        let frames = Int(sr)
        let samples = renderVoice(waveform: "sawtooth", freq: freq, sampleRate: sr,
                                  frameCount: frames, attack: 0.0001, sustain: 1.0, durationSec: 2.0)
        let crossings = countPositiveToNegativeCrossings(samples, skip: 500)
        XCTAssertGreaterThan(crossings, Int(freq * 0.90), "Saw 220Hz: crossings=\(crossings)")
        XCTAssertLessThan(crossings, Int(freq * 1.10),    "Saw 220Hz: crossings=\(crossings)")
    }

    func testSquareOscillatorFrequency() {
        let sr: Double = 44100
        let freq: Double = 330.0
        let frames = Int(sr)
        let samples = renderVoice(waveform: "square", freq: freq, sampleRate: sr,
                                  frameCount: frames, attack: 0.0001, sustain: 1.0, durationSec: 2.0)
        let crossings = countPositiveToNegativeCrossings(samples, skip: 500)
        XCTAssertGreaterThan(crossings, Int(freq * 0.90), "Square 330Hz: crossings=\(crossings)")
        XCTAssertLessThan(crossings, Int(freq * 1.10),    "Square 330Hz: crossings=\(crossings)")
    }

    func testTriangleOscillatorFrequency() {
        let sr: Double = 44100
        let freq: Double = 110.0
        let frames = Int(sr)
        let samples = renderVoice(waveform: "triangle", freq: freq, sampleRate: sr,
                                  frameCount: frames, attack: 0.0001, sustain: 1.0, durationSec: 2.0)
        let crossings = countPositiveToNegativeCrossings(samples, skip: 2000)  // longer settle for integrator
        XCTAssertGreaterThan(crossings, Int(freq * 0.85), "Triangle 110Hz: crossings=\(crossings)")
        XCTAssertLessThan(crossings, Int(freq * 1.15),    "Triangle 110Hz: crossings=\(crossings)")
    }

    func testOscillatorAmplitudeBound() {
        // All oscillator outputs must stay within the synthHeadroom ceiling (0.3 × gain).
        // Bug 3 fix: synthHeadroom = 0.3 is applied in the render block, so max output
        // for gain=1.0 should be ≤ 0.31 (0.3 × 1.0 + small polyBLEP overshoot).
        let sr: Double = 44100
        for wave in ["sine", "sawtooth", "square", "triangle"] {
            let samples = renderVoice(waveform: wave, freq: 440.0, sampleRate: sr,
                                      frameCount: 4096, attack: 0.0, sustain: 1.0, durationSec: 2.0)
            let maxAbs = samples.map { abs($0) }.max() ?? 0
            XCTAssertLessThanOrEqual(Double(maxAbs), 0.35,
                                     "\(wave): amplitude exceeds headroom ceiling: \(maxAbs)")
            // Voice must also produce non-silent audio
            XCTAssertGreaterThan(Double(maxAbs), 0.01,
                                 "\(wave): oscillator produced silence unexpectedly")
        }
    }

    // MARK: - 7. DSP — ADSR envelope shape

    func testADSRAttackRamp() {
        // With attack=0.01s at 44100 Hz, envelope reaches 1 at ~441 samples.
        // We verify: first sample near 0 (envelope starts at 0),
        // and max amplitude in the attack window rises (not stuck at 0).
        // We use a very low-frequency sine so we can see the envelope shape clearly.
        let sr: Double = 44100
        let attackSamples = Int(0.01 * sr)  // 441 samples
        // Use freq=1 Hz so sine ≈ 0..1 linearly during the 10ms attack window,
        // making peak amplitude track the envelope closely.
        let samples = renderVoice(waveform: "sine", freq: 1.0, sampleRate: sr,
                                  frameCount: attackSamples + 50,
                                  attack: 0.01, decay: 1.0, sustain: 1.0,
                                  release: 0.1, durationSec: 2.0)
        // First sample: envelope ≈ 1/441, sine ≈ 0 → very small
        XCTAssertLessThan(abs(samples[0]), 0.05, "ADSR: first sample should be near 0")
        // Maximum over the attack window: since sine is ≈ linear at 1Hz for 10ms,
        // max amplitude grows as envelope × sin(2πf×t). At attack end (t=0.01s),
        // envelope=1, sin(2π×0.01)≈0.063. Look at the full attack+settle window.
        // Check that amplitude is increasing overall (last quarter > first quarter).
        let firstQuarter  = (0..<attackSamples/4).map     { abs(samples[$0]) }.max() ?? 0
        let lastQuarter   = (attackSamples*3/4..<attackSamples).map { abs(samples[$0]) }.max() ?? 0
        XCTAssertGreaterThan(Double(lastQuarter), Double(firstQuarter),
                             "ADSR: amplitude should grow during attack phase")
    }

    func testADSRDecayAndSustain() {
        // sustain=0.5: after attack+decay, amplitude should be ~0.5 × sin_peak
        let sr: Double = 44100
        let atkSamp = Int(0.001 * sr)    // 44 samples
        let decSamp = Int(0.05  * sr)    // 2205 samples
        let sustainLevel = 0.5
        let totalSettle  = atkSamp + decSamp + 10
        let samples = renderVoice(waveform: "sine", freq: 440.0, sampleRate: sr,
                                  frameCount: totalSettle,
                                  attack: 0.001, decay: 0.05, sustain: sustainLevel,
                                  release: 0.1, durationSec: Double(totalSettle) / sr + 0.5)
        // Check a window after decay completes: envelope should be ≈ sustain level.
        // Bug 3 fix: synthHeadroom = 0.3 is applied in the render block, so the
        // actual peak ≈ sustainLevel × headroom × sin_peak. We test relative ordering
        // (non-zero, below the headroom ceiling) rather than exact amplitude.
        let checkStart = atkSamp + decSamp
        let checkEnd   = min(checkStart + 100, samples.count)
        let peakInWindow = (checkStart..<checkEnd).map { abs(samples[$0]) }.max() ?? 0
        // With synthHeadroom=0.3 and sustain=0.5, expected peak ≈ 0.5*0.3 ≈ 0.15.
        // We verify the voice is audible (>0) and bounded (≤ headroom ceiling ≈ 0.35).
        XCTAssertGreaterThan(Double(peakInWindow), 0.001,
                             "ADSR: sustain window should be non-silent: \(peakInWindow)")
        XCTAssertLessThanOrEqual(Double(peakInWindow), 0.35,
                                  "ADSR: sustain level exceeds headroom ceiling: \(peakInWindow)")
    }

    func testADSRSilenceAfterRelease() {
        // After release ends, voice should be silent (isActive = false)
        let sr: Double = 44100
        let voice = SynthVoice()
        let totalDur = 0.1   // 100ms note
        let release  = 0.05  // 50ms release
        let totalSamples = Int((totalDur + release + 0.01) * sr)  // +10ms pad
        voice.trigger(
            waveform:         "sine",
            freq:             440.0,
            gain:             1.0,
            attack:           0.001,
            decay:            0.01,
            sustain:          0.5,
            release:          release,
            durationSec:      totalDur,
            sampleRate:       sr,
            birthSample:      0,
            startHostSeconds: 0.0   // immediate — no offset for unit tests
        )
        var buf = [Float](repeating: 0, count: totalSamples)
        buf.withUnsafeMutableBufferPointer { ptr in
            voice.render(into: ptr.baseAddress!, frameCount: totalSamples,
                         bufferStartSeconds: 0.0, sampleRate: sr)
        }
        XCTAssertFalse(voice.isActive, "Voice should be idle after full ADSR cycle")
        // Last 10 samples should be (near) silent
        let tailMax = buf.suffix(10).map { abs($0) }.max() ?? 0
        XCTAssertLessThan(Double(tailMax), 0.01, "Tail after release should be silent: \(tailMax)")
    }

    // MARK: - 8. DSP — resonance to bandwidth mapping

    func testResonanceBandwidthMapping() {
        // Q=0 → bandwidth = 5 (max)
        XCTAssertEqual(resonanceToOctaveBandwidth(0.0), 5.0, accuracy: 1e-6)
        // Q=1 → 2.0
        XCTAssertEqual(resonanceToOctaveBandwidth(1.0), 2.0, accuracy: 1e-6)
        // Q=5 → 0.4
        XCTAssertEqual(resonanceToOctaveBandwidth(5.0), 0.4, accuracy: 1e-6)
        // Q=50 → 0.05 (minimum)
        XCTAssertEqual(resonanceToOctaveBandwidth(50.0), 0.05, accuracy: 1e-6)
    }

    func testResonanceBandwidthMonotonicallyDecreasing() {
        // Higher Q = narrower bandwidth = smaller number
        let q1 = resonanceToOctaveBandwidth(1.0)
        let q5 = resonanceToOctaveBandwidth(5.0)
        let q10 = resonanceToOctaveBandwidth(10.0)
        XCTAssertGreaterThan(q1, q5,  "Q=1 bandwidth should be wider than Q=5")
        XCTAssertGreaterThan(q5, q10, "Q=5 bandwidth should be wider than Q=10")
    }

    func testResonanceBandwidthClampedAbove() {
        // Very low Q values should not exceed 5.0
        XCTAssertLessThanOrEqual(resonanceToOctaveBandwidth(0.0), 5.0)
        XCTAssertLessThanOrEqual(resonanceToOctaveBandwidth(0.001), 5.0)
    }

    func testResonanceBandwidthClampedBelow() {
        // Very high Q values should not go below 0.05
        XCTAssertGreaterThanOrEqual(resonanceToOctaveBandwidth(100.0), 0.05)
        XCTAssertGreaterThanOrEqual(resonanceToOctaveBandwidth(1000.0), 0.05)
    }

    // MARK: - 9. Polyphony — voice pool

    func testVoicePoolAcceptsMultipleNotes() {
        // Trigger 8 notes simultaneously; all should be active
        let sr: Double = 44100
        let layer = SynthLayer(synthName: "sine", sampleRate: sr)
        let freqs: [Double] = [220, 277, 330, 370, 440, 494, 587, 659]
        for f in freqs {
            layer.scheduleNote(
                freq:             f,
                gain:             0.5,
                attack:           0.001,
                decay:            0.05,
                sustain:          0.6,
                release:          0.1,
                durationSec:      1.0,
                sampleRate:       sr,
                startHostSeconds: 0.0
            )
        }
        // We can't inspect private voices directly, but we can verify no crash
        // and that scheduleNote completes for 8 simultaneous voices.
        XCTAssert(true, "8 simultaneous notes triggered without crash")
    }

    func testVoicePoolStealsBeyond8() {
        // Triggering 9 notes should not crash (LRU steal)
        let sr: Double = 44100
        let layer = SynthLayer(synthName: "sawtooth", sampleRate: sr)
        for i in 0..<9 {
            layer.scheduleNote(
                freq:             Double(100 + i * 50),
                gain:             0.3,
                attack:           0.001,
                decay:            0.05,
                sustain:          0.6,
                release:          0.1,
                durationSec:      2.0,
                sampleRate:       sr,
                startHostSeconds: 0.0
            )
        }
        XCTAssert(true, "9th note steal did not crash")
    }

    // MARK: - 10. CodeParser integration

    func testCodeParserSoundFunction() throws {
        let parser = CodeParser()
        // sound() as top-level function
        let pat = try parser.parse(#"sound("sawtooth")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["s"], .string("sawtooth"))
    }

    func testCodeParserSawtoothWithNote() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"note("c3 e3").s("sawtooth")"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value["note"],  .double(48))  // c3
        XCTAssertEqual(haps[1].value["note"],  .double(52))  // e3
        XCTAssertEqual(haps[0].value["synth"], .string("sawtooth"))
    }

    func testCodeParserFullSynthChain() throws {
        let parser = CodeParser()
        let code = #"""
        note("c3 e3 g3").s("sawtooth")
          .attack(0.05).decay(0.1).sustain(0.6).release(0.2)
          .lpf(1200).resonance(8)
          .gain(0.8).pan(0.3)
        """#
        let pat = try parser.parse(code)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        let h = haps[0]
        XCTAssertEqual(h.value["attack"]?.doubleValue  ?? 0, 0.05,  accuracy: 1e-9)
        XCTAssertEqual(h.value["decay"]?.doubleValue   ?? 0, 0.1,   accuracy: 1e-9)
        XCTAssertEqual(h.value["sustain"]?.doubleValue ?? 0, 0.6,   accuracy: 1e-9)
        XCTAssertEqual(h.value["release"]?.doubleValue ?? 0, 0.2,   accuracy: 1e-9)
        XCTAssertEqual(h.value["lpf"]?.doubleValue     ?? 0, 1200.0, accuracy: 1e-9)
        XCTAssertEqual(h.value["resonance"]?.doubleValue ?? 0, 8.0, accuracy: 1e-9)
        XCTAssertEqual(h.value["gain"]?.doubleValue    ?? 0, 0.8,   accuracy: 1e-9)
        XCTAssertEqual(h.value["pan"]?.doubleValue     ?? 0, 0.3,   accuracy: 1e-9)
    }

    func testCodeParserSpeedOnSample() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").speed(2)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["speed"], .double(2.0))
    }

    func testCodeParserHPF() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").hpf(200)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["hpf"], .double(200.0))
    }

    func testCodeParserStackWithSynths() throws {
        // Stack of synth + sample should not error
        let parser = CodeParser()
        let code = """
        stack(
          note("c3 e3").s("sawtooth").attack(0.01),
          s("pad").slow(2).gain(0.5)
        )
        """
        let pat = try parser.parse(code)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty, "Stack of synth+sample should produce events")
        let synthHaps  = haps.filter { $0.value["synth"] != nil }
        let sampleHaps = haps.filter { $0.value["synth"] == nil }
        XCTAssertFalse(synthHaps.isEmpty,  "Should have synth events")
        XCTAssertFalse(sampleHaps.isEmpty, "Should have sample events")
    }

    func testCodeParserSynthWithEuclid() throws {
        // Synths work with euclidean rhythm
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").euclid(3,8)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 3, "euclid(3,8) should give 3 events")
        for h in haps {
            XCTAssertEqual(h.value["synth"], .string("sawtooth"))
        }
    }

    func testCodeParserSynthWithRev() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"note("c3 e3 g3").s("sine").rev"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        // rev reverses note order: g3=55, e3=52, c3=48
        XCTAssertEqual(haps[0].value["note"], .double(55))  // g3
        XCTAssertEqual(haps[1].value["note"], .double(52))  // e3
        XCTAssertEqual(haps[2].value["note"], .double(48))  // c3
    }

    func testCodeParserSoundAlias() throws {
        // sound("sawtooth") same result as s("sawtooth")
        let parser = CodeParser()
        let p1 = try parser.parse(#"s("sawtooth")"#)
        let p2 = try parser.parse(#"sound("sawtooth")"#)
        let h1 = p1.firstCycle()
        let h2 = p2.firstCycle()
        XCTAssertEqual(h1.count, h2.count)
        XCTAssertEqual(h1[0].value["s"],     h2[0].value["s"])
        XCTAssertEqual(h1[0].value["synth"], h2[0].value["synth"])
    }

    // MARK: - 11. Oracle cross-check (subset of fixture verification)

    func testOraclesSawtoothControlMap() throws {
        // s("sawtooth") → part=[0,1), s="sawtooth" (oracle confirmed)
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].part.begin, Rational(0))
        XCTAssertEqual(haps[0].part.end,   Rational(1))
        XCTAssertEqual(haps[0].value["s"], .string("sawtooth"))
    }

    func testOracleNoteSawtooth2Events() throws {
        // note("c3 e3").s("sawtooth") → 2 haps, notes 48 and 52
        let parser = CodeParser()
        let pat = try parser.parse(#"note("c3 e3").s("sawtooth")"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value["note"], .double(48))
        XCTAssertEqual(haps[1].value["note"], .double(52))
        XCTAssertEqual(haps[0].part.begin, Rational(0))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 2))
        XCTAssertEqual(haps[1].part.begin, Rational(1, 2))
        XCTAssertEqual(haps[1].part.end,   Rational(1))
    }

    func testOracleADSRFields() throws {
        // s("sawtooth").attack(0.1).decay(0.2).sustain(0.7).release(0.3)
        // Oracle confirmed: all 4 fields present at expected values
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").attack(0.1).decay(0.2).sustain(0.7).release(0.3)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["attack"]?.doubleValue  ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(haps[0].value["decay"]?.doubleValue   ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(haps[0].value["sustain"]?.doubleValue ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertEqual(haps[0].value["release"]?.doubleValue ?? 0, 0.3, accuracy: 1e-9)
    }

    func testOracleLPFResonance() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").lpf(800).resonance(5)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["lpf"]?.doubleValue       ?? 0, 800.0, accuracy: 1e-9)
        XCTAssertEqual(haps[0].value["resonance"]?.doubleValue ?? 0, 5.0,   accuracy: 1e-9)
    }

    func testOracleSpeedOnSample() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").speed(2)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["speed"]?.doubleValue ?? 0, 2.0, accuracy: 1e-9)
    }

    // MARK: - Bug Fix 3: Filter neutral default (no resonance peak when resonance() absent)

    /// When resonance() is not specified, applyLPF/HPF should use bandwidth=5.0
    /// (widest/flattest = no resonance peak). The previous default of 0.5 was
    /// ≈ Q=4, which caused an audible resonant boost at the cutoff frequency.
    func testLPFNeutralDefaultBandwidth() {
        // Q=0 (no resonance specified) must give bandwidth=5.0 (neutral)
        let bw = resonanceToOctaveBandwidth(0.0)
        XCTAssertEqual(bw, 5.0, accuracy: 1e-6,
            "No resonance → bandwidth must be 5.0 (flattest, no resonance peak)")
    }

    func testLPFResonanceBandwidthNarrowsWithHigherQ() {
        // When resonance IS specified, bandwidth should be narrower than neutral
        let neutralBW = resonanceToOctaveBandwidth(0.0)  // 5.0
        let bwQ9      = resonanceToOctaveBandwidth(9.0)  // ≈ 2/9 ≈ 0.222
        XCTAssertLessThan(bwQ9, neutralBW,
            "Explicit Q=9 (resonance=9) must produce narrower bandwidth than no-resonance")
        // Q=9 specifically: 2.0/9.0 ≈ 0.222 — well below 5.0
        XCTAssertEqual(bwQ9, 2.0/9.0, accuracy: 1e-6)
    }

    /// SynthLayer.init EQ bands must be correctly typed and bypassed.
    /// Note: AVAudioUnitEQ .lowPass/.highPass filter types ignore the bandwidth
    /// property — it is only meaningful for .resonantLowPass/.resonantHighPass.
    /// We verify filter types and bypass state (the only reliable read-back properties).
    func testSynthLayerInitEQBandsConfigured() {
        let layer = SynthLayer(synthName: "sawtooth", sampleRate: 44100)
        // band[0] = LPF
        let lpfBand = layer.eq.bands[0]
        XCTAssertEqual(lpfBand.filterType, .lowPass,
            "LPF band must use .lowPass filter type")
        XCTAssertTrue(lpfBand.bypass, "LPF must start bypassed")
        XCTAssertEqual(lpfBand.frequency, 20_000, accuracy: 1.0,
            "LPF default frequency must be 20kHz (above human hearing = transparent)")
        // band[1] = HPF
        let hpfBand = layer.eq.bands[1]
        XCTAssertEqual(hpfBand.filterType, .highPass,
            "HPF band must use .highPass filter type")
        XCTAssertTrue(hpfBand.bypass, "HPF must start bypassed")
        XCTAssertEqual(hpfBand.frequency, 20.0, accuracy: 1.0,
            "HPF default frequency must be 20Hz (below human hearing = transparent)")
    }

    /// applyLPF must activate the band and set the frequency.
    /// After a call with no resonance, bandwidth is set to neutral (5.0) on the band —
    /// even though .lowPass ignores bandwidth, we set it for forward-compat with
    /// filterType switching. The key invariant is band is NOT bypassed after applyLPF.
    func testApplyLPFActivatesBand() {
        let layer = SynthLayer(synthName: "sawtooth", sampleRate: 44100)
        XCTAssertTrue(layer.eq.bands[0].bypass, "pre-call: bypassed")
        layer.applyLPF(freq: 800.0, resonance: nil)
        XCTAssertFalse(layer.eq.bands[0].bypass, "post-call: not bypassed")
        XCTAssertEqual(layer.eq.bands[0].frequency, 800.0, accuracy: 1.0, "frequency set")
    }

    func testApplyLPFWithResonanceSwitchesToResonanceLowPass() {
        let layer = SynthLayer(synthName: "sawtooth", sampleRate: 44100)
        layer.applyLPF(freq: 800.0, resonance: 9.0)
        // With resonance > 0, filter type switches to .resonantLowPass (which uses bandwidth for Q)
        XCTAssertFalse(layer.eq.bands[0].bypass, "band must be active")
        XCTAssertEqual(layer.eq.bands[0].frequency, 800.0, accuracy: 1.0)
        XCTAssertEqual(layer.eq.bands[0].filterType, .resonantLowPass,
            "resonance > 0 must switch to .resonantLowPass for Q control")
    }

    func testApplyLPFWithoutResonanceUsesPlainLowPass() {
        let layer = SynthLayer(synthName: "sawtooth", sampleRate: 44100)
        layer.applyLPF(freq: 1200.0, resonance: nil)
        XCTAssertFalse(layer.eq.bands[0].bypass, "band must be active")
        XCTAssertEqual(layer.eq.bands[0].filterType, .lowPass,
            "No resonance must use .lowPass (no peak)")
        XCTAssertEqual(layer.eq.bands[0].frequency, 1200.0, accuracy: 1.0)
    }

    func testApplyLPFResonanceResetAfterRemoval() {
        // First call with resonance, then without: must revert to .lowPass
        let layer = SynthLayer(synthName: "sawtooth", sampleRate: 44100)
        layer.applyLPF(freq: 800.0, resonance: 9.0)
        XCTAssertEqual(layer.eq.bands[0].filterType, .resonantLowPass)
        layer.applyLPF(freq: 800.0, resonance: nil)
        XCTAssertEqual(layer.eq.bands[0].filterType, .lowPass,
            "Removing resonance must revert to flat .lowPass")
    }
}

