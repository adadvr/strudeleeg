// ---------------------------------------------------------------------------
// BugFixTests — Unit tests for three production bugs fixed in the Mini Engine.
//
// Bug 1: setcpm/setcps ignored — everything plays at double speed.
//   Fix: MiniEngine.play() now calls parseWithTempo() and applies sched.setcps(cps)
//   BEFORE sched.play(pattern:).  A testable entry point makeScheduler(for:) is
//   exposed so tests can inspect the scheduler's cps without starting audio.
//
// Bug 2: Synths fire up to 400ms before their scheduled time.
//   Fix: SynthVoice.trigger() now accepts startHostSeconds; the render block
//   reads the buffer's mHostTime, converts to seconds, and starts each voice at
//   the exact buffer frame where it's due.
//   The math is in the pure function synthVoiceStartFrame(...) → (skip, startFrame).
//
// Bug 3: Synths much louder than Strudel mix ("drums get buried").
//   Fix: synthHeadroom = 0.3 applied in the render block (sample × gain × headroom).
//   Documented in COMPATIBILITY.md as an approximation, not a bit-accurate calibration.
// ---------------------------------------------------------------------------

import XCTest
import AVFoundation
@testable import MiniEngine

final class BugFixTests: XCTestCase {

    // MARK: - Bug 1: setcpm / setcps applied to scheduler

    func testSetcpm15YieldsCps025ViaParseWithTempo() throws {
        // setcpm(15) / 60 = 0.25 cps — verified directly from parseWithTempo.
        let parser = CodeParser()
        let result = try parser.parseWithTempo("""
            setcpm(15)
            s("bd")
            """)
        XCTAssertNotNil(result.cps, "setcpm should produce a non-nil cps")
        XCTAssertEqual(result.cps ?? 0, 0.25, accuracy: 1e-9,
                       "setcpm(15) should parse to cps = 0.25")
    }

    func testMakeSchedulerAppliesCpsFromSetcpm() {
        // makeScheduler(for:) must apply the parsed cps to the scheduler before
        // calling sched.play().  We inspect sched.cps after the call.
        // No real audio: we pass empty sampleURLs so the scheduler creates no chains.
        let engine = MiniEngine(sampleURLs: [:])
        let sched = engine.makeScheduler(for: "setcpm(15)\ns(\"bd\")")
        XCTAssertNotNil(sched, "makeScheduler should succeed for valid code")
        XCTAssertEqual(sched?.cps ?? 0, 0.25, accuracy: 1e-9,
                       "Scheduler cps must be 0.25 after setcpm(15)")
    }

    func testMakeSchedulerAppliesCpsFromSetcps() {
        let engine = MiniEngine(sampleURLs: [:])
        let sched = engine.makeScheduler(for: "setcps(0.6)\ns(\"bd\")")
        XCTAssertEqual(sched?.cps ?? 0, 0.6, accuracy: 1e-9,
                       "Scheduler cps must be 0.6 after setcps(0.6)")
    }

    func testMakeSchedulerUsesDefaultCpsWhenNoTempo() {
        // Without setcps/setcpm the scheduler must keep its default (0.5).
        let engine = MiniEngine(sampleURLs: [:])
        let sched = engine.makeScheduler(for: "s(\"bd\")")
        XCTAssertEqual(sched?.cps ?? 0, 0.5, accuracy: 1e-9,
                       "Default cps must be 0.5 when no tempo statement")
    }

    func testParsePatternAPIStillWorks() throws {
        // parsePattern() must continue to return a ControlPattern without crashing.
        let engine = MiniEngine(sampleURLs: [:])
        let pat = try engine.parsePattern("s(\"bd*4\")")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 4, "parsePattern should return 4 haps for bd*4")
    }

    func testUserFullPatternCps() throws {
        // The user's real pattern (from Tier1Tests.testUserFullPatternParses) must
        // parse with cps=0.25 and report that via makeScheduler.
        let code = """
        setcpm(15)
        stack(
          n("<0!8 3!4 0!4>").scale("C:minor").sound("sawtooth").attack(2).decay(1).sustain(0.6).release(2).lpf(300).gain(0.26).room(0.6),
          s("<bd*8!12 ~ [bd ~ ~ ~ bd ~ bd ~] bd*8!2>").decay(0.38).gain(0.95)
        )
        """
        // Parse without engine to check cps
        let parser = CodeParser()
        let result = try parser.parseWithTempo(code)
        XCTAssertEqual(result.cps ?? 0, 0.25, accuracy: 1e-9,
                       "User's full pattern: setcpm(15) must produce cps=0.25")

        // Also confirm via makeScheduler
        let engine = MiniEngine(sampleURLs: [:])
        let sched = engine.makeScheduler(for: code)
        XCTAssertEqual(sched?.cps ?? 0, 0.25, accuracy: 1e-9,
                       "makeScheduler must apply cps=0.25 from user's pattern")
    }

    // MARK: - Bug 2: Sample-accurate synth start (pure math tests)

    /// Voice starts exactly at the first frame of the buffer.
    func testSynthVoiceStartFrameExactlyAtBufferStart() {
        let (skip, frame) = synthVoiceStartFrame(
            bufferStartSeconds: 10.0,
            frameCount: 512,
            sampleRate: 44100,
            startHostSeconds: 10.0   // same time → frame 0
        )
        XCTAssertFalse(skip, "Voice is not in the future — do not skip")
        XCTAssertEqual(frame, 0, "Voice starts at frame 0")
    }

    /// Voice started before the buffer began: clamp to frame 0.
    func testSynthVoiceStartFrameAlreadyStarted() {
        let (skip, frame) = synthVoiceStartFrame(
            bufferStartSeconds: 10.0,
            frameCount: 512,
            sampleRate: 44100,
            startHostSeconds: 9.9    // 100ms in the past → clamp to 0
        )
        XCTAssertFalse(skip, "Past voice should not be skipped")
        XCTAssertEqual(frame, 0, "Past voice should start at frame 0 (clamped)")
    }

    /// Voice starts beyond the end of this buffer: must be skipped (stay pending).
    func testSynthVoiceStartFrameFutureBuffer() {
        let (skip, _) = synthVoiceStartFrame(
            bufferStartSeconds: 10.0,
            frameCount: 512,        // 512/44100 ≈ 11.6ms
            sampleRate: 44100,
            startHostSeconds: 10.05  // 50ms after buffer start → past frame 512
        )
        XCTAssertTrue(skip, "Voice in far future should be skipped this buffer")
    }

    /// Voice starts mid-buffer at a known offset: verify frame index.
    /// The implementation uses Int(offsetFrames) — truncating double → integer.
    func testSynthVoiceStartFrameMidBuffer() {
        // Use a start time that avoids floating-point cancellation by using an
        // offset of exactly 0.5 seconds (representable in IEEE-754 at 44100 Hz).
        // 0.5 * 44100 = 22050.0 exactly → frame 22050.
        let sr = 44100.0
        let bufStart = 0.0   // start at epoch 0 to avoid cancellation error
        let startTime = 0.5  // exactly 22050 frames

        let (skip, frame) = synthVoiceStartFrame(
            bufferStartSeconds: bufStart,
            frameCount: 44100,   // 1s buffer
            sampleRate: sr,
            startHostSeconds: startTime
        )
        XCTAssertFalse(skip, "Voice is within this 1-second buffer")
        XCTAssertEqual(frame, 22050, "Frame at exactly 0.5s = 22050")
    }

    /// Voice starts exactly at the last frame of the buffer (not beyond it).
    func testSynthVoiceStartFrameLastFrame() {
        // bufferStart=10.0, frameCount=441, sr=44100.
        // startHostSeconds = bufStart + 440/44100 → offsetFrames = 440.0 exactly → frame 440.
        let sr = 44100.0
        let bufStart = 10.0
        let frameIdx = 440
        let startTime = bufStart + Double(frameIdx) / sr

        let (skip, frame) = synthVoiceStartFrame(
            bufferStartSeconds: bufStart,
            frameCount: 441,
            sampleRate: sr,
            startHostSeconds: startTime
        )
        XCTAssertFalse(skip, "Frame 440 of 441 is inside the buffer")
        XCTAssertEqual(frame, 440, "Should start at exactly frame 440")
    }

    /// Voice starting well beyond the buffer end must be skipped.
    func testSynthVoiceStartFrameWellBeyondBuffer() {
        // startHostSeconds = bufStart + 2 × bufferDuration → clearly beyond this buffer.
        let sr = 44100.0
        let bufStart = 10.0
        let fc = 512
        let bufDuration = Double(fc) / sr
        let startTime = bufStart + 2 * bufDuration   // 2× buffer duration ahead

        let (skip, _) = synthVoiceStartFrame(
            bufferStartSeconds: bufStart,
            frameCount: fc,
            sampleRate: sr,
            startHostSeconds: startTime
        )
        XCTAssertTrue(skip, "A voice starting 2 buffer-durations ahead must be skipped")
    }

    // MARK: - Bug 2: Integration — voice renders silence before startFrame

    func testVoiceRendersZeroBeforeStartFrame() {
        // Trigger a voice with startHostSeconds = 0.1 in a buffer starting at 0.0,
        // at 1000 Hz sample rate.  bufferStartSeconds=0.0, frameCount=200, sr=1000.
        // startHostSeconds=0.1 → startFrame = round(0.1*1000) = 100.
        // Frames 0..99 must be silent; frames 100.. must have non-zero output.
        let sr = 1000.0
        let bufStart = 0.0
        let startTime = 0.1  // startFrame = 100

        let voice = SynthVoice()
        voice.trigger(
            waveform:         "sine",
            freq:             50.0,    // low freq so non-zero output is expected
            gain:             1.0,
            attack:           0.0,
            decay:            0.0,
            sustain:          1.0,
            release:          1.0,
            durationSec:      1.0,
            sampleRate:       sr,
            birthSample:      0,
            startHostSeconds: startTime
        )

        var buf = [Float](repeating: 0, count: 200)
        buf.withUnsafeMutableBufferPointer { ptr in
            voice.render(into: ptr.baseAddress!, frameCount: 200,
                         bufferStartSeconds: bufStart, sampleRate: sr)
        }

        // Frames 0..99: silent (voice not yet started)
        let preSilenceMax = buf[0..<100].map { abs($0) }.max() ?? 0
        XCTAssertEqual(Double(preSilenceMax), 0.0, accuracy: 1e-6,
                       "Frames before startFrame must be silent")

        // Frames 100..199: voice is active — must produce non-zero audio
        let postMax = buf[100...].map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(Double(postMax), 0.001,
                             "Frames at/after startFrame must produce non-zero audio")
    }

    func testVoiceSkipsEntireBufferWhenFarFuture() {
        // If startHostSeconds is beyond this buffer, voice.render must write zero
        // and return true (still pending, not idle).
        let sr = 44100.0
        let voice = SynthVoice()
        voice.trigger(
            waveform:         "sine",
            freq:             440.0,
            gain:             1.0,
            attack:           0.001,
            decay:            0.05,
            sustain:          0.6,
            release:          0.1,
            durationSec:      0.5,
            sampleRate:       sr,
            birthSample:      0,
            startHostSeconds: 10.0   // far future
        )

        var buf = [Float](repeating: 0, count: 512)
        let stillActive = buf.withUnsafeMutableBufferPointer { ptr -> Bool in
            return voice.render(into: ptr.baseAddress!, frameCount: 512,
                                bufferStartSeconds: 0.0, sampleRate: sr)
        }
        XCTAssertTrue(stillActive, "Voice should remain active when its start is in the future")
        let maxAbs = buf.map { abs($0) }.max() ?? 0
        XCTAssertEqual(Double(maxAbs), 0.0, accuracy: 1e-6,
                       "Future voice must write silence to the buffer")
    }

    // MARK: - Bug 3: Synth headroom

    func testSynthHeadroomApplied() {
        // With gain=1.0 and sustain=1.0, the rendered sine amplitude must stay
        // at or below synthHeadroom (0.3), not at the pre-fix ~1.0.
        // We use attack=0.0 so we immediately reach full envelope.
        let sr = 44100.0
        let voice = SynthVoice()
        voice.trigger(
            waveform:         "sine",
            freq:             440.0,
            gain:             1.0,
            attack:           0.0,
            decay:            0.0,
            sustain:          1.0,
            release:          1.0,
            durationSec:      2.0,
            sampleRate:       sr,
            birthSample:      0,
            startHostSeconds: 0.0
        )
        var buf = [Float](repeating: 0, count: 4410)  // 100ms
        buf.withUnsafeMutableBufferPointer { ptr in
            voice.render(into: ptr.baseAddress!, frameCount: 4410,
                         bufferStartSeconds: 0.0, sampleRate: sr)
        }
        let maxAbs = buf.map { abs($0) }.max() ?? 0
        // Expected: ≤ 0.31 (synthHeadroom=0.3 + tiny polyBLEP overshoot allowance)
        XCTAssertLessThanOrEqual(Double(maxAbs), 0.31,
                                 "synthHeadroom must cap output at 0.3 × gain")
        // Voice must not be silent either
        XCTAssertGreaterThan(Double(maxAbs), 0.01,
                             "synthHeadroom must not silence the voice")
    }

    func testSynthHeadroomWithGainHalf() {
        // gain=0.5 → peak ≈ 0.5 × synthHeadroom = 0.15
        let sr = 44100.0
        let voice = SynthVoice()
        voice.trigger(
            waveform:         "sine",
            freq:             440.0,
            gain:             0.5,
            attack:           0.0,
            decay:            0.0,
            sustain:          1.0,
            release:          1.0,
            durationSec:      2.0,
            sampleRate:       sr,
            birthSample:      0,
            startHostSeconds: 0.0
        )
        var buf = [Float](repeating: 0, count: 4410)
        buf.withUnsafeMutableBufferPointer { ptr in
            voice.render(into: ptr.baseAddress!, frameCount: 4410,
                         bufferStartSeconds: 0.0, sampleRate: sr)
        }
        let maxAbs = buf.map { abs($0) }.max() ?? 0
        // gain=0.5 → expected peak ≈ 0.15, ceiling ≤ 0.17
        XCTAssertLessThanOrEqual(Double(maxAbs), 0.17,
                                 "gain=0.5: peak should be around 0.5 × headroom = 0.15")
        XCTAssertGreaterThan(Double(maxAbs), 0.005,
                             "gain=0.5 voice must not be inaudible")
    }

    func testSynthHeadroomBelowFullScale() {
        // Verify explicitly: with gain=1.0 and all waveforms, output never exceeds 0.35.
        // This is the formal test of Bug 3.
        let sr = 44100.0
        for wave in ["sine", "sawtooth", "square", "triangle"] {
            let voice = SynthVoice()
            voice.trigger(
                waveform:         wave,
                freq:             440.0,
                gain:             1.0,
                attack:           0.0,
                decay:            0.0,
                sustain:          1.0,
                release:          1.0,
                durationSec:      2.0,
                sampleRate:       sr,
                birthSample:      0,
                startHostSeconds: 0.0
            )
            var buf = [Float](repeating: 0, count: 4410)
            buf.withUnsafeMutableBufferPointer { ptr in
                voice.render(into: ptr.baseAddress!, frameCount: 4410,
                             bufferStartSeconds: 0.0, sampleRate: sr)
            }
            let maxAbs = buf.map { abs($0) }.max() ?? 0
            XCTAssertLessThan(Double(maxAbs), 0.35,
                              "\(wave): output exceeds headroom ceiling of 0.3")
        }
    }

    // MARK: - Bug 1 fix: _layer tagging and layer key distinctness

    /// stack() must inject distinct _layer values per branch.
    func testStackLayerTagsAreDistinct() throws {
        let parser = CodeParser()
        let pat = try parser.parse("""
            stack(
              note("a2").sound("sawtooth"),
              note("e5").sound("sawtooth")
            )
            """)
        let haps = pat.firstCycle().sorted {
            ($0.value["_layer"]?.doubleValue ?? 0) < ($1.value["_layer"]?.doubleValue ?? 0)
        }
        let layers = Set(haps.compactMap { $0.value["_layer"]?.doubleValue })
        XCTAssertEqual(layers, [0.0, 1.0],
                       "stack() must tag branches with _layer 0 and 1")
    }

    /// Single-layer (non-stack) pattern must have _layer = 0.
    func testSingleLayerTagIsZero() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"note("c4").sound("sine")"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        for hap in haps {
            XCTAssertEqual(hap.value["_layer"]?.doubleValue, 0.0,
                           "Single-layer pattern must have _layer = 0")
        }
    }

    /// $: multi-layer syntax must produce distinct _layer per segment.
    func testDollarColonLayerTagsAreDistinct() throws {
        let parser = CodeParser()
        let pat = try parser.parse("""
            $: note("a2").sound("sawtooth")
            $: note("e5").sound("sawtooth")
            """)
        let haps = pat.firstCycle()
        let layers = Set(haps.compactMap { $0.value["_layer"]?.doubleValue })
        XCTAssertEqual(layers, [0.0, 1.0],
                       "$: segments must tag distinct _layer values 0 and 1")
    }

    /// Adding _layer must NOT change hap count (map not withControl).
    func testLayerTagDoesNotDuplicateHaps() throws {
        let parser = CodeParser()
        // slow(4) pattern: 1 hap with whole=[0,4). Using withControl would
        // multiply by 4; using map must keep it at 1.
        let pat = try parser.parse(#"s("pad").slow(4)"#)
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1,
                       "_layer injection via map must not duplicate haps (was broken if using withControl)")
    }

    /// PatternScheduler.layerKey produces distinct keys per layer index.
    func testLayerKeyDistinctness() {
        let k0 = PatternScheduler.layerKey(layerIdx: 0, name: "sawtooth")
        let k1 = PatternScheduler.layerKey(layerIdx: 1, name: "sawtooth")
        XCTAssertNotEqual(k0, k1, "Different layer indices must produce different chain keys")
        XCTAssertEqual(k0, "0#sawtooth")
        XCTAssertEqual(k1, "1#sawtooth")
    }

    // MARK: - Bug 2 fix (triangle): frequency-independent amplitude

    /// Triangle RMS at a2 (110 Hz) vs e5 (659 Hz) must be within 2× of each other.
    /// Before fix: ratio was ~6×.
    func testTriangleAmplitudeFrequencyIndependent() {
        let sr = 44100.0
        let durFrames = Int(0.5 * sr)   // 500ms render window

        func renderTriangleRMS(freq: Double) -> Double {
            let voice = SynthVoice()
            voice.trigger(waveform: "triangle", freq: freq, gain: 1.0,
                          attack: 0.0, decay: 0.0, sustain: 1.0, release: 1.0,
                          durationSec: 1.0, sampleRate: sr, birthSample: 0,
                          startHostSeconds: 0.0)
            var buf = [Float](repeating: 0, count: durFrames)
            buf.withUnsafeMutableBufferPointer { ptr in
                voice.render(into: ptr.baseAddress!, frameCount: durFrames,
                             bufferStartSeconds: 0.0, sampleRate: sr)
            }
            // Skip first 50ms (transient from integrator settling)
            let skipFrames = Int(0.05 * sr)
            let window = buf[skipFrames...]
            var sumSq: Float = 0
            for s in window { sumSq += s * s }
            return Double(sqrt(sumSq / Float(window.count)))
        }

        let rmsLow  = renderTriangleRMS(freq: 110.0)   // a2
        let rmsHigh = renderTriangleRMS(freq: 659.255)  // e5

        XCTAssertGreaterThan(rmsLow,  0.001, "Triangle a2 must produce non-zero RMS")
        XCTAssertGreaterThan(rmsHigh, 0.001, "Triangle e5 must produce non-zero RMS")

        let ratio = rmsHigh > 1e-9 ? rmsLow / rmsHigh : 999.0
        XCTAssertGreaterThan(ratio, 0.5,
                             "Triangle a2/e5 RMS ratio must be > 0.5 (was ~6 before fix)")
        XCTAssertLessThan(ratio, 2.0,
                          "Triangle a2/e5 RMS ratio must be < 2.0 (was ~6 before fix)")
    }

    /// Triangle must produce the correct fundamental frequency.
    func testTrianglePitchAtE5() {
        let sr = 44100.0
        let frameCount = Int(0.3 * sr)
        let voice = SynthVoice()
        voice.trigger(waveform: "triangle", freq: 659.255, gain: 1.0,
                      attack: 0.0, decay: 0.0, sustain: 1.0, release: 1.0,
                      durationSec: 1.0, sampleRate: sr, birthSample: 0,
                      startHostSeconds: 0.0)
        var buf = [Float](repeating: 0, count: frameCount)
        buf.withUnsafeMutableBufferPointer { ptr in
            voice.render(into: ptr.baseAddress!, frameCount: frameCount,
                         bufferStartSeconds: 0.0, sampleRate: sr)
        }
        // Count zero-crossings (rising edge) to estimate frequency
        // For triangle at 659 Hz, we expect ~659*0.3 ≈ 198 full cycles in 300ms.
        var crossings = 0
        for i in 1..<frameCount {
            if buf[i-1] <= 0 && buf[i] > 0 { crossings += 1 }
        }
        let estimatedFreq = Double(crossings) / 0.3
        XCTAssertEqual(estimatedFreq, 659.0, accuracy: 30.0,
                       "Triangle e5: zero-crossing frequency estimate must be near 659 Hz")
    }
}
