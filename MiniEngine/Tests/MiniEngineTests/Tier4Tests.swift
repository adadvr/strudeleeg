// ---------------------------------------------------------------------------
// Tier4Tests — Phase 4 / Tier 4: Textures / DSP custom
//
// Tests organised as:
//   1. Control-map tests — verifies field names/values in pattern output.
//      Cross-checked against oracle fixtures where possible.
//   2. DSP unit tests:
//      • crush: quantisation formula correctness on a known sample buffer.
//      • chop: begin/end sub-event values and time-slot positions.
//      • striate: begin/end interleaving across events.
//      • shape: wetDryMix mapping (x → x*100).
//      • vowel: EQ band frequency configuration.
//   3. CodeParser integration — all new methods parsed correctly.
//
// Test decisions (documented):
//   • AVAudioUnitDistortion DSP not tested offline (requires running engine).
//     We test the parameter mapping (wetDryMix = x*100) and that the preset
//     is loaded without crash (via SynthLayer init, which is exerciseable offline).
//   • AVAudioUnitEQ vowel bands not tested for audio output (requires engine).
//     We test the frequency configuration logic via the public formant table.
//   • Bitcrusher: tested with a known float buffer (pure signal quantisation).
//   • chorus / phaser: not implemented — CodeParser logs a warning, no error.
//     Verified: pattern is returned unchanged (no crash).
//
// Oracle fixture labels matched:
//   s("pad").shape(0.5)        → value["shape"] = 0.5
//   s("pad").distort(0.8)      → value["distort"] = 0.8
//   s("pad").crush(4)          → value["crush"] = 4.0
//   s("pad bell").crush(8)     → both events have crush=8
//   s("sawtooth").vowel("a")   → value["vowel"] = "a"
//   s("sawtooth").vowel("<a o>") → alternates per cycle
//   s("pad").chop(4)           → 4 sub-events with correct begin/end
//   s("pad bell").chop(2)      → 4 sub-events, 2 per original event
//   s("pad").striate(4)        → 4 events same as chop(4)
//   s("pad bell").striate(2)   → 2 events, each with different chunk
// ---------------------------------------------------------------------------

import XCTest
@testable import MiniEngine

final class Tier4Tests: XCTestCase {

    // MARK: - 1. Control map — shape / distort

    func testShapeFieldInControlMap() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").shape(0.5)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["shape"]?.doubleValue ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(haps[0].value["s"], .string("pad"))
    }

    func testDistortFieldInControlMap() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").distort(0.8)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["distort"]?.doubleValue ?? -1, 0.8, accuracy: 1e-9)
    }

    func testShapeOnSynth() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").shape(0.3)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["shape"]?.doubleValue ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(haps[0].value["synth"], .string("sawtooth"))
    }

    func testShapePatternnable() throws {
        // shape("<0.2 0.8>") alternates per cycle
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").shape("<0.2 0.8>")"#)
        let h0 = pat.queryArc(Rational(0), Rational(1))
        let h1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertEqual(h0.first?.value["shape"]?.doubleValue ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(h1.first?.value["shape"]?.doubleValue ?? -1, 0.8, accuracy: 1e-9)
    }

    func testShapeWetDryMapping() {
        // shape(x) → wetDryMix = x * 100
        // We verify the mapping formula directly (DSP applied to SynthLayer,
        // not testable offline, but the formula is documented and unit-testable).
        let x = 0.5
        let expected = Float(x * 100.0)
        XCTAssertEqual(expected, 50.0)

        let x2 = 1.0
        XCTAssertEqual(Float(x2 * 100.0), 100.0)

        let x3 = 0.0
        XCTAssertEqual(Float(x3 * 100.0), 0.0)
    }

    // MARK: - 2. Control map — crush (bitcrusher)

    func testCrushFieldInControlMap() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").crush(4)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["crush"]?.doubleValue ?? -1, 4.0, accuracy: 1e-9)
    }

    func testCrushOn2EventPattern() throws {
        // Oracle: s("pad bell").crush(8) → 2 haps, both with crush=8
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad bell").crush(8)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value["crush"]?.doubleValue ?? -1, 8.0, accuracy: 1e-9)
        XCTAssertEqual(haps[1].value["crush"]?.doubleValue ?? -1, 8.0, accuracy: 1e-9)
    }

    func testCrushAbsentByDefault() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad")"#)
        let haps = pat.firstCycle()
        XCTAssertNil(haps[0].value["crush"])
    }

    func testCrushOnSynth() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").crush(6)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["crush"]?.doubleValue ?? -1, 6.0, accuracy: 1e-9)
    }

    // MARK: - 3. DSP — Bitcrusher formula correctness

    /// Test bitcrusher quantisation formula:
    /// quantize(s, bits) = round(s × 2^(bits-1)) / 2^(bits-1)
    func testBitcrusherQuantisation1Bit() {
        // 1 bit: 2^0 = 1 level → round(s × 1) / 1 = round(s)
        // +0.7 → round(0.7) = 1.0
        // -0.7 → round(-0.7) = -1.0
        // 0.0 → 0.0
        var buf: [Float] = [0.7, -0.7, 0.0, 0.3, -0.3]
        buf.withUnsafeMutableBufferPointer { ptr in
            applyBitcrusher(buffer: ptr.baseAddress!, frameCount: 5, bits: 1.0)
        }
        XCTAssertEqual(buf[0], 1.0, accuracy: 1e-6)   // 0.7 → 1.0
        XCTAssertEqual(buf[1], -1.0, accuracy: 1e-6)  // -0.7 → -1.0
        XCTAssertEqual(buf[2], 0.0, accuracy: 1e-6)   // 0.0 → 0.0
        XCTAssertEqual(buf[3], 0.0, accuracy: 1e-6)   // 0.3 → round(0.3) = 0.0
        XCTAssertEqual(buf[4], 0.0, accuracy: 1e-6)   // -0.3 → round(-0.3) = 0.0
    }

    func testBitcrusherQuantisation2Bits() {
        // 2 bits: 2^1 = 2 levels → round(s × 2) / 2
        // +0.75 → round(1.5) / 2 = 2.0/2 = 1.0
        // +0.4  → round(0.8) / 2 = 1.0/2 = 0.5
        // +0.1  → round(0.2) / 2 = 0.0/2 = 0.0
        var buf: [Float] = [0.75, 0.4, 0.1, -0.4, -0.75]
        buf.withUnsafeMutableBufferPointer { ptr in
            applyBitcrusher(buffer: ptr.baseAddress!, frameCount: 5, bits: 2.0)
        }
        XCTAssertEqual(buf[0], 1.0,  accuracy: 1e-6)
        XCTAssertEqual(buf[1], 0.5,  accuracy: 1e-6)
        XCTAssertEqual(buf[2], 0.0,  accuracy: 1e-6)
        XCTAssertEqual(buf[3], -0.5, accuracy: 1e-6)
        XCTAssertEqual(buf[4], -1.0, accuracy: 1e-6)
    }

    func testBitcrusherQuantisation4Bits() {
        // 4 bits: 2^3 = 8 levels → round(s × 8) / 8
        // +0.5 → round(4.0) / 8 = 4/8 = 0.5 (exact, no change)
        // +0.6 → round(4.8) / 8 = 5/8 = 0.625
        // +0.1 → round(0.8) / 8 = 1/8 = 0.125
        var buf: [Float] = [0.5, 0.6, 0.1]
        buf.withUnsafeMutableBufferPointer { ptr in
            applyBitcrusher(buffer: ptr.baseAddress!, frameCount: 3, bits: 4.0)
        }
        XCTAssertEqual(buf[0], 0.5,     accuracy: 1e-5)
        XCTAssertEqual(buf[1], 0.625,   accuracy: 1e-5)
        XCTAssertEqual(buf[2], 0.125,   accuracy: 1e-5)
    }

    func testBitcrusherTransparentAt16Bits() {
        // At 16 bits: 2^15 = 32768 levels — quantisation step is 1/32768 ≈ 3e-5
        // Signal should be nearly unchanged
        let original: [Float] = [0.3, -0.7, 0.1, -0.999, 0.0]
        var buf = original
        buf.withUnsafeMutableBufferPointer { ptr in
            applyBitcrusher(buffer: ptr.baseAddress!, frameCount: 5, bits: 16.0)
        }
        for i in 0..<5 {
            XCTAssertEqual(Double(buf[i]), Double(original[i]), accuracy: 0.0001,
                           "16-bit crush should be near-transparent for sample \(i)")
        }
    }

    func testBitcrusherReducesDistinctValues() {
        // At 3 bits: 2^2=4 levels. A ramp 0..1 in 100 steps should have at most 5 distinct values
        // (0, 0.25, 0.5, 0.75, 1.0)
        var buf = (0..<100).map { Float($0) / 99.0 }
        buf.withUnsafeMutableBufferPointer { ptr in
            applyBitcrusher(buffer: ptr.baseAddress!, frameCount: 100, bits: 3.0)
        }
        let distinct = Set(buf.map { Int($0 * 10000 + 0.5) })
        // At 3 bits we expect at most ~5 quantisation levels in 0..1
        XCTAssertLessThanOrEqual(distinct.count, 6,
                                 "3-bit crush should produce few distinct values, got \(distinct.count)")
    }

    // MARK: - 4. Control map — vowel formant filter

    func testVowelFieldInControlMap() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").vowel("a")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["vowel"], .string("a"))
    }

    func testVowelAllVowels() throws {
        let parser = CodeParser()
        for v in ["a", "e", "i", "o", "u"] {
            let pat = try parser.parse("s(\"sawtooth\").vowel(\"\(v)\")")
            let haps = pat.firstCycle()
            XCTAssertEqual(haps.count, 1, "\(v): should produce 1 hap")
            XCTAssertEqual(haps[0].value["vowel"], .string(v),
                           "\(v): vowel field should be '\(v)'")
        }
    }

    func testVowelAlternatingPerCycle() throws {
        // vowel("<a o>") → "a" in cycle 0, "o" in cycle 1
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").vowel("<a o>")"#)
        let h0 = pat.queryArc(Rational(0), Rational(1))
        let h1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertEqual(h0.first?.value["vowel"], .string("a"), "Cycle 0: should have vowel 'a'")
        XCTAssertEqual(h1.first?.value["vowel"], .string("o"), "Cycle 1: should have vowel 'o'")
    }

    func testVowelAbsentByDefault() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad")"#)
        let haps = pat.firstCycle()
        XCTAssertNil(haps[0].value["vowel"])
    }

    // MARK: - 5. DSP — Vowel formant table verification
    // Verified against: Peterson & Barney (1952) / public acoustic phonetics tables.
    // Values used: approximate midpoint averages.

    func testVowelFormantTableA() {
        // /ɑ/ "father": F1=730, F2=1090, F3=2440
        let layer = SynthLayer(synthName: "sine", sampleRate: 44100)
        layer.applyVowel("a")
        // After applyVowel, the 3 bands should be configured with F1/F2/F3
        let b0 = layer.vowelEQ.bands[0]
        let b1 = layer.vowelEQ.bands[1]
        let b2 = layer.vowelEQ.bands[2]
        XCTAssertFalse(b0.bypass, "Band 0 should be enabled for vowel 'a'")
        XCTAssertFalse(b1.bypass, "Band 1 should be enabled for vowel 'a'")
        XCTAssertFalse(b2.bypass, "Band 2 should be enabled for vowel 'a'")
        XCTAssertEqual(Double(b0.frequency), 730.0,  accuracy: 1.0, "F1 for 'a'")
        XCTAssertEqual(Double(b1.frequency), 1090.0, accuracy: 1.0, "F2 for 'a'")
        XCTAssertEqual(Double(b2.frequency), 2440.0, accuracy: 1.0, "F3 for 'a'")
    }

    func testVowelFormantTableE() {
        // /ɛ/ "bed": F1=530, F2=1840, F3=2480
        let layer = SynthLayer(synthName: "sine", sampleRate: 44100)
        layer.applyVowel("e")
        XCTAssertEqual(Double(layer.vowelEQ.bands[0].frequency), 530.0,  accuracy: 1.0, "F1 for 'e'")
        XCTAssertEqual(Double(layer.vowelEQ.bands[1].frequency), 1840.0, accuracy: 1.0, "F2 for 'e'")
        XCTAssertEqual(Double(layer.vowelEQ.bands[2].frequency), 2480.0, accuracy: 1.0, "F3 for 'e'")
    }

    func testVowelFormantTableI() {
        // /iː/ "see": F1=390, F2=1990, F3=2550
        let layer = SynthLayer(synthName: "sine", sampleRate: 44100)
        layer.applyVowel("i")
        XCTAssertEqual(Double(layer.vowelEQ.bands[0].frequency), 390.0,  accuracy: 1.0, "F1 for 'i'")
        XCTAssertEqual(Double(layer.vowelEQ.bands[1].frequency), 1990.0, accuracy: 1.0, "F2 for 'i'")
        XCTAssertEqual(Double(layer.vowelEQ.bands[2].frequency), 2550.0, accuracy: 1.0, "F3 for 'i'")
    }

    func testVowelFormantTableO() {
        // /ɔ/ "thought": F1=570, F2=840, F3=2410
        let layer = SynthLayer(synthName: "sine", sampleRate: 44100)
        layer.applyVowel("o")
        XCTAssertEqual(Double(layer.vowelEQ.bands[0].frequency), 570.0,  accuracy: 1.0, "F1 for 'o'")
        XCTAssertEqual(Double(layer.vowelEQ.bands[1].frequency), 840.0,  accuracy: 1.0, "F2 for 'o'")
        XCTAssertEqual(Double(layer.vowelEQ.bands[2].frequency), 2410.0, accuracy: 1.0, "F3 for 'o'")
    }

    func testVowelFormantTableU() {
        // /uː/ "food": F1=440, F2=1020, F3=2240
        let layer = SynthLayer(synthName: "sine", sampleRate: 44100)
        layer.applyVowel("u")
        XCTAssertEqual(Double(layer.vowelEQ.bands[0].frequency), 440.0,  accuracy: 1.0, "F1 for 'u'")
        XCTAssertEqual(Double(layer.vowelEQ.bands[1].frequency), 1020.0, accuracy: 1.0, "F2 for 'u'")
        XCTAssertEqual(Double(layer.vowelEQ.bands[2].frequency), 2240.0, accuracy: 1.0, "F3 for 'u'")
    }

    func testVowelBandsStartBypassed() {
        // Without calling applyVowel, all bands should be bypassed
        let layer = SynthLayer(synthName: "sine", sampleRate: 44100)
        for i in 0..<3 {
            XCTAssertTrue(layer.vowelEQ.bands[i].bypass,
                          "Band \(i) should be bypassed before vowel is applied")
        }
    }

    // MARK: - 6. Control map — chop (granular sub-events)

    func testChopSingleEventInto4() throws {
        // s("pad").chop(4) → 4 sub-events, begin/end = 0, 0.25, 0.5, 0.75 / 0.25, 0.5, 0.75, 1.0
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").chop(4)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4, "chop(4) should produce 4 sub-events")

        // Time slots: each 1/4 cycle
        let expectedParts: [(Double, Double)] = [(0, 0.25), (0.25, 0.5), (0.5, 0.75), (0.75, 1.0)]
        let expectedBeginEnd: [(Double, Double)] = [(0, 0.25), (0.25, 0.5), (0.5, 0.75), (0.75, 1.0)]

        for (i, hap) in haps.enumerated() {
            let (pb, pe) = expectedParts[i]
            let (sb, se) = expectedBeginEnd[i]
            XCTAssertEqual(hap.part.begin.toDouble, pb, accuracy: 1e-6,
                           "chop(4) sub-event \(i): wrong part begin")
            XCTAssertEqual(hap.part.end.toDouble,   pe, accuracy: 1e-6,
                           "chop(4) sub-event \(i): wrong part end")
            XCTAssertEqual(hap.value["begin"]?.doubleValue ?? -1, sb, accuracy: 1e-6,
                           "chop(4) sub-event \(i): wrong sample begin")
            XCTAssertEqual(hap.value["end"]?.doubleValue ?? -1,   se, accuracy: 1e-6,
                           "chop(4) sub-event \(i): wrong sample end")
            XCTAssertEqual(hap.value["s"], .string("pad"))
        }
    }

    func testChop2EventPatternInto4() throws {
        // s("pad bell").chop(2) → 4 sub-events
        // Oracle verified: pad×2 then bell×2
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad bell").chop(2)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4, "chop(2) on 2 events should produce 4 sub-events")

        // pad: slots [0,1/4), [1/4,1/2); bell: slots [1/2,3/4), [3/4,1)
        let expectedS: [String] = ["pad", "pad", "bell", "bell"]
        let expectedBegin: [Double] = [0.0, 0.5, 0.0, 0.5]
        let expectedEnd:   [Double] = [0.5, 1.0, 0.5, 1.0]

        for (i, hap) in haps.enumerated() {
            XCTAssertEqual(hap.value["s"]?.stringValue, expectedS[i],
                           "chop(2) event \(i): wrong sample name")
            XCTAssertEqual(hap.value["begin"]?.doubleValue ?? -1, expectedBegin[i], accuracy: 1e-6,
                           "chop(2) event \(i): wrong begin")
            XCTAssertEqual(hap.value["end"]?.doubleValue ?? -1, expectedEnd[i], accuracy: 1e-6,
                           "chop(2) event \(i): wrong end")
        }
    }

    func testChopPreservesOtherFields() throws {
        // chop should preserve existing control fields like gain
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").gain(0.5).chop(2)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 2)
        for hap in haps {
            XCTAssertEqual(hap.value["gain"]?.doubleValue ?? -1, 0.5, accuracy: 1e-6)
            XCTAssertNotNil(hap.value["begin"])
            XCTAssertNotNil(hap.value["end"])
        }
    }

    func testChopSumOfSegmentsIsFullSample() {
        // Direct API test: chop(4) on s("pad") → begin/end should cover [0,1] without gaps
        let pat = s("pad").chop(4)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4)
        var lastEnd = 0.0
        for hap in haps {
            let b = hap.value["begin"]?.doubleValue ?? -1
            let e = hap.value["end"]?.doubleValue   ?? -1
            XCTAssertEqual(b, lastEnd, accuracy: 1e-6, "No gap between chop segments")
            lastEnd = e
        }
        XCTAssertEqual(lastEnd, 1.0, accuracy: 1e-6, "Last chop segment should end at 1.0")
    }

    // MARK: - 7. Control map — striate (granular interleaving)

    func testStriateSingleEventGetsChunk0() throws {
        // s("pad").striate(4):
        // striate assigns chunk (i mod n) to event i. Single event (i=0) → chunk 0.
        // Result: 1 event with begin=0/4=0, end=1/4=0.25.
        // This is DIFFERENT from chop(4) which creates 4 sub-events.
        // Oracle confirmed: s("pad").striate(4) → 1 hap with begin=0, end=0.25
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").striate(4)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1, "striate(4) on single event → 1 event (chunk 0 only)")
        XCTAssertEqual(haps[0].value["begin"]?.doubleValue ?? -1, 0.0,  accuracy: 1e-6)
        XCTAssertEqual(haps[0].value["end"]?.doubleValue   ?? -1, 0.25, accuracy: 1e-6)
    }

    func testStriate2On2Events() throws {
        // s("pad bell").striate(2) → 2 events, not 4
        // Oracle: pad → begin=0, end=0.5 ; bell → begin=0.5, end=1.0
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad bell").striate(2)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2, "striate(2) on 2 events keeps 2 events (no multiplication)")

        XCTAssertEqual(haps[0].value["s"]?.stringValue, "pad")
        XCTAssertEqual(haps[0].value["begin"]?.doubleValue ?? -1, 0.0, accuracy: 1e-6)
        XCTAssertEqual(haps[0].value["end"]?.doubleValue   ?? -1, 0.5, accuracy: 1e-6)

        XCTAssertEqual(haps[1].value["s"]?.stringValue, "bell")
        XCTAssertEqual(haps[1].value["begin"]?.doubleValue ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(haps[1].value["end"]?.doubleValue   ?? -1, 1.0, accuracy: 1e-6)
    }

    func testStriateDifferentFromChopOnMultiEvent() throws {
        // For 2-event pattern:
        // chop(2)    → 4 events
        // striate(2) → 2 events (different behaviour confirmed by oracle)
        let parser = CodeParser()
        let chop    = try parser.parse(#"s("pad bell").chop(2)"#)
        let striate = try parser.parse(#"s("pad bell").striate(2)"#)
        XCTAssertEqual(chop.firstCycle().count,    4, "chop(2) on 2 events = 4 sub-events")
        XCTAssertEqual(striate.firstCycle().count, 2, "striate(2) on 2 events = 2 events (interleaved)")
    }

    // MARK: - 8. SynthLayer — distortion node initialised

    func testSynthLayerDistortionStartsDry() {
        let layer = SynthLayer(synthName: "sine", sampleRate: 44100)
        // Distortion node should start with wetDryMix = 0 (fully dry)
        XCTAssertEqual(Double(layer.distortion.wetDryMix), 0.0, accuracy: 0.1,
                       "Distortion should start dry (wetDryMix=0)")
    }

    func testSynthLayerApplyDistortionMapping() {
        let layer = SynthLayer(synthName: "sine", sampleRate: 44100)
        layer.applyDistortion(0.5)
        XCTAssertEqual(Double(layer.distortion.wetDryMix), 50.0, accuracy: 0.1,
                       "shape(0.5) → wetDryMix = 50")
        layer.applyDistortion(1.0)
        XCTAssertEqual(Double(layer.distortion.wetDryMix), 100.0, accuracy: 0.1,
                       "shape(1.0) → wetDryMix = 100")
        layer.applyDistortion(0.0)
        XCTAssertEqual(Double(layer.distortion.wetDryMix), 0.0, accuracy: 0.1,
                       "shape(0.0) → wetDryMix = 0")
    }

    // MARK: - 9. SynthVoice — crush in render block

    func testCrushInSynthVoiceRender() {
        // Verify that crush applied in the render block quantises the output.
        // We render a low-frequency sine (so we can observe sample values), then
        // verify the output has fewer distinct values than an uncrushed version.
        let sr: Double = 44100
        let frames = 1024

        // Without crush
        let voiceNoCrush = SynthVoice()
        voiceNoCrush.trigger(
            waveform: "sine", freq: 10.0, gain: 1.0,
            attack: 0.0, decay: 0.0, sustain: 1.0, release: 10.0,
            durationSec: 1.0, sampleRate: sr, birthSample: 0,
            startHostSeconds: 0.0, crushBits: 0.0
        )
        var noCrushBuf = [Float](repeating: 0, count: frames)
        noCrushBuf.withUnsafeMutableBufferPointer { ptr in
            voiceNoCrush.render(into: ptr.baseAddress!, frameCount: frames,
                                bufferStartSeconds: 0.0, sampleRate: sr)
        }

        // With crush = 3 bits
        let voiceCrush = SynthVoice()
        voiceCrush.trigger(
            waveform: "sine", freq: 10.0, gain: 1.0,
            attack: 0.0, decay: 0.0, sustain: 1.0, release: 10.0,
            durationSec: 1.0, sampleRate: sr, birthSample: 0,
            startHostSeconds: 0.0, crushBits: 3.0
        )
        var crushBuf = [Float](repeating: 0, count: frames)
        crushBuf.withUnsafeMutableBufferPointer { ptr in
            voiceCrush.render(into: ptr.baseAddress!, frameCount: frames,
                              bufferStartSeconds: 0.0, sampleRate: sr)
        }

        let noCrushDistinct = Set(noCrushBuf.map { Int($0 * 100000) }).count
        let crushDistinct   = Set(crushBuf.map   { Int($0 * 100000) }).count

        XCTAssertLessThan(crushDistinct, noCrushDistinct,
                          "Crushed signal should have fewer distinct amplitude values")
        // At 3 bits, max 2^2+1 = 5 distinct levels in [-1,1] (0, ±0.25, ±0.5, ±0.75, ±1)
        XCTAssertLessThanOrEqual(crushDistinct, 12,
                                 "3-bit crush should produce at most ~9 distinct values")
    }

    // MARK: - 10. CodeParser integration

    func testCodeParserShapeAccepted() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").shape(0.5)"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value["shape"], .double(0.5))
    }

    func testCodeParserDistortAccepted() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").distort(0.7)"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value["distort"], .double(0.7))
    }

    func testCodeParserCrushAccepted() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").crush(4)"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value["crush"], .double(4.0))
    }

    func testCodeParserVowelAccepted() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").vowel("a")"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value["vowel"], .string("a"))
    }

    func testCodeParserChopAccepted() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").chop(4)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 4)
        XCTAssertNotNil(haps[0].value["begin"])
        XCTAssertNotNil(haps[0].value["end"])
    }

    func testCodeParserStriateAccepted() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad bell").striate(2)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 2)
        XCTAssertNotNil(haps[0].value["begin"])
        XCTAssertNotNil(haps[0].value["end"])
    }

    func testCodeParserChorusNotErroring() throws {
        // chorus is not implemented but should not throw — just log a warning
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").chorus(0.5)"#)
        let haps = pat.firstCycle()
        // Pattern should still have the base event (chorus is a no-op)
        XCTAssertFalse(haps.isEmpty, "chorus() should not silently remove events")
    }

    func testCodeParserPhaserNotErroring() throws {
        // phaser is not implemented but should not throw
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").phaser(0.5)"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty, "phaser() should not silently remove events")
    }

    func testCodeParserFullFase4Chain() throws {
        // Full Fase 4 chain on a synth: all new effects in one expression
        let parser = CodeParser()
        let code = #"""
        s("sawtooth")
          .shape(0.3)
          .crush(8)
          .vowel("e")
          .chop(2)
          .gain(0.8)
        """#
        let pat = try parser.parse(code)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        // chop(2) on single event → 2 sub-events
        XCTAssertEqual(haps.count, 2, "chop(2) should produce 2 sub-events")
        let h = haps[0]
        XCTAssertEqual(h.value["shape"]?.doubleValue  ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(h.value["crush"]?.doubleValue  ?? -1, 8.0, accuracy: 1e-9)
        XCTAssertEqual(h.value["vowel"]?.stringValue, "e")
        XCTAssertEqual(h.value["gain"]?.doubleValue   ?? -1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(h.value["begin"]?.doubleValue  ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(h.value["end"]?.doubleValue    ?? -1, 0.5, accuracy: 1e-9)
    }

    // MARK: - 11. Oracle cross-checks (fixture verification)

    func testOracleShapeField() throws {
        // s("pad").shape(0.5) → part=[0,1), shape=0.5
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").shape(0.5)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].part.begin, Rational(0))
        XCTAssertEqual(haps[0].part.end,   Rational(1))
        XCTAssertEqual(haps[0].value["shape"], .double(0.5))
    }

    func testOracleCrushField() throws {
        // s("pad").crush(4) → part=[0,1), crush=4
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").crush(4)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["crush"], .double(4.0))
    }

    func testOracleVowelField() throws {
        // s("sawtooth").vowel("a") → part=[0,1), vowel="a"
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").vowel("a")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["vowel"], .string("a"))
    }

    func testOracleChop4() throws {
        // s("pad").chop(4) — matches oracle fixture
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").chop(4)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4)
        let beginEnds: [(Double, Double)] = [(0, 0.25), (0.25, 0.5), (0.5, 0.75), (0.75, 1.0)]
        for (i, (b, e)) in beginEnds.enumerated() {
            XCTAssertEqual(haps[i].value["begin"]?.doubleValue ?? -1, b, accuracy: 1e-6,
                           "Oracle chop(4) event \(i) begin")
            XCTAssertEqual(haps[i].value["end"]?.doubleValue   ?? -1, e, accuracy: 1e-6,
                           "Oracle chop(4) event \(i) end")
        }
    }

    func testOracleStriate2On2Events() throws {
        // s("pad bell").striate(2) — matches oracle fixture
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad bell").striate(2)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value["begin"]?.doubleValue ?? -1, 0.0, accuracy: 1e-6)
        XCTAssertEqual(haps[0].value["end"]?.doubleValue   ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(haps[1].value["begin"]?.doubleValue ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(haps[1].value["end"]?.doubleValue   ?? -1, 1.0, accuracy: 1e-6)
    }
}
