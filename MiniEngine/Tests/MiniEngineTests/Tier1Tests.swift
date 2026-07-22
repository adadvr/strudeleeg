// ---------------------------------------------------------------------------
// Tier1Tests — Tests for all Tier 1 features:
//   1. pan(x)
//   2. delay / delaytime / delayfeedback
//   3. euclid(k, n) / euclid(k, n, rot)
//   4. Mini-notation * ! @
//   5. setcps / setcpm parsing
//   6. n("...") + scale("Root:name")
// ---------------------------------------------------------------------------

import XCTest
@testable import MiniEngine

final class Tier1Tests: XCTestCase {

    // MARK: - 1. pan(x)

    func testPanScalar() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").pan(0.25)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["pan"], .double(0.25))
        XCTAssertEqual(haps[0].value["s"],   .string("pad"))
    }

    func testPanDefault() throws {
        // No pan → no "pan" key in control map
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertNil(haps[0].value["pan"])
    }

    func testPanAsPattern() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").pan("<0 1>")"#)
        let h0 = pat.queryArc(Rational(0), Rational(1))
        let h1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertFalse(h0.isEmpty)
        XCTAssertFalse(h1.isEmpty)
        XCTAssertEqual(h0[0].value["pan"], .double(0.0))
        XCTAssertEqual(h1[0].value["pan"], .double(1.0))
    }

    // MARK: - 2. delay / delaytime / delayfeedback

    func testDelayFields() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").delay(0.5).delaytime(0.3).delayfeedback(0.6)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        let val = haps[0].value
        XCTAssertEqual(val["delay"],         .double(0.5))
        XCTAssertEqual(val["delaytime"],     .double(0.3))
        XCTAssertEqual(val["delayfeedback"], .double(0.6))
    }

    func testDelayOnlyDefault() throws {
        // delay without delaytime/feedback — they should not appear in pattern
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").delay(0.4)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["delay"], .double(0.4))
        // delaytime and delayfeedback defaults are handled at the scheduler level
    }

    // MARK: - 3. euclid(k, n) and euclid(k, n, rot)

    func testEuclidAlgorithm38() {
        // bjorklund(3,8) = [1,0,0,1,0,0,1,0] → onsets at steps 0,3,6
        let rhythm = euclideanRhythm(k: 3, n: 8)
        XCTAssertEqual(rhythm.count, 8)
        let onsets = rhythm.enumerated().compactMap { $0.element ? $0.offset : nil }
        XCTAssertEqual(onsets, [0, 3, 6])
    }

    func testEuclidAlgorithm25() {
        // bjorklund(2,5) = [1,0,1,0,0] → onsets at steps 0,2
        let rhythm = euclideanRhythm(k: 2, n: 5)
        XCTAssertEqual(rhythm.count, 5)
        let onsets = rhythm.enumerated().compactMap { $0.element ? $0.offset : nil }
        XCTAssertEqual(onsets, [0, 2])
    }

    func testEuclidAlgorithm58() {
        // bjorklund(5,8) = [1,0,1,1,0,1,1,0] → onsets at steps 0,2,3,5,6
        let rhythm = euclideanRhythm(k: 5, n: 8)
        XCTAssertEqual(rhythm.count, 8)
        let onsets = rhythm.enumerated().compactMap { $0.element ? $0.offset : nil }
        XCTAssertEqual(onsets, [0, 2, 3, 5, 6])
    }

    func testEuclidPatternHapCount38() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bell").euclid(3,8)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 3)
    }

    func testEuclidPatternPositions38() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bell").euclid(3,8)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        // Step 0 → [0, 1/8), step 3 → [3/8, 4/8), step 6 → [6/8, 7/8)
        XCTAssertEqual(haps[0].part.begin, Rational(0, 8))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 8))
        XCTAssertEqual(haps[1].part.begin, Rational(3, 8))
        XCTAssertEqual(haps[1].part.end,   Rational(4, 8))
        XCTAssertEqual(haps[2].part.begin, Rational(6, 8))
        XCTAssertEqual(haps[2].part.end,   Rational(7, 8))
    }

    func testEuclidPatternPositions25() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bell").euclid(2,5)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        // Step 0 → [0, 1/5), step 2 → [2/5, 3/5)
        XCTAssertEqual(haps[0].part.begin, Rational(0, 5))
        XCTAssertEqual(haps[1].part.begin, Rational(2, 5))
    }

    func testEuclidPatternPositions58() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bell").euclid(5,8)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 5)
        // onsets at 0,2,3,5,6
        XCTAssertEqual(haps[0].part.begin, Rational(0, 8))
        XCTAssertEqual(haps[1].part.begin, Rational(2, 8))
        XCTAssertEqual(haps[2].part.begin, Rational(3, 8))
        XCTAssertEqual(haps[3].part.begin, Rational(5, 8))
        XCTAssertEqual(haps[4].part.begin, Rational(6, 8))
    }

    func testEuclidRotation382() throws {
        // euclid(3,8,2): Strudel's euclidRot shifts onset positions forward by rot=2
        // bjorklund(3,8) = [1,0,0,1,0,0,1,0] → onsets at 0,3,6
        // Rotate right by 2: [1,0,1,0,0,1,0,0] → onsets at 0,2,5
        // (rotateRight = onsets shift forward: (0+2)%8=2, (3+2)%8=5, (6+2)%8=0 → sorted: 0,2,5)
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bell").euclid(3,8,2)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        // Oracle: onsets at steps 0, 2, 5
        XCTAssertEqual(haps[0].part.begin, Rational(0, 8))
        XCTAssertEqual(haps[1].part.begin, Rational(2, 8))
        XCTAssertEqual(haps[2].part.begin, Rational(5, 8))
    }

    // MARK: - 4. Mini-notation * (fast)

    func testMiniStar2() {
        // "pad*2" = pad plays twice in its slot
        let pat = parseMini("pad*2")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].part.begin, Rational(0, 2))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 2))
        XCTAssertEqual(haps[1].part.begin, Rational(1, 2))
        XCTAssertEqual(haps[1].part.end,   Rational(2, 2))
    }

    func testMiniStarInSequence() {
        // "pad*2 bell" → 2-step sequence where first step is pad*2
        // Each top step = 1/2 cycle; pad*2 fills [0, 1/2) with 2 events
        let pat = parseMini("pad*2 bell")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        XCTAssertEqual(haps[0].value, "pad")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 4))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 4))
        XCTAssertEqual(haps[1].value, "pad")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 4))
        XCTAssertEqual(haps[1].part.end,   Rational(2, 4))
        XCTAssertEqual(haps[2].value, "bell")
        XCTAssertEqual(haps[2].part.begin, Rational(2, 4))
        XCTAssertEqual(haps[2].part.end,   Rational(4, 4))
    }

    // MARK: - 4. Mini-notation ! (replicate)

    func testMiniBang2() {
        // "pad!2" = 2 copies of pad in 2 equal steps
        let pat = parseMini("pad!2")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value, "pad")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 2))
        XCTAssertEqual(haps[1].value, "pad")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 2))
    }

    func testMiniBang2InSequence() {
        // "pad!2 bell" → 3 equal steps: pad, pad, bell
        let pat = parseMini("pad!2 bell")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        XCTAssertEqual(haps[0].value, "pad")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 3))
        XCTAssertEqual(haps[1].value, "pad")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 3))
        XCTAssertEqual(haps[2].value, "bell")
        XCTAssertEqual(haps[2].part.begin, Rational(2, 3))
    }

    func testMiniBangDefaultIs2() {
        // "a!" without number = 2 copies
        let pat = parseMini("a!")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 2)
    }

    // MARK: - 4. Mini-notation @ (weight)

    func testMiniWeight3() {
        // "pad@3 bell" → pad takes 3/4 cycle, bell takes 1/4
        let pat = parseMini("pad@3 bell")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value, "pad")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 4))
        XCTAssertEqual(haps[0].part.end,   Rational(3, 4))
        XCTAssertEqual(haps[1].value, "bell")
        XCTAssertEqual(haps[1].part.begin, Rational(3, 4))
        XCTAssertEqual(haps[1].part.end,   Rational(4, 4))
    }

    func testMiniWeightEqualDefault() {
        // "a@2 b@2" → equal weights → same as "a b"
        let pat = parseMini("a@2 b@2")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].part.begin, Rational(0, 2))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 2))
        XCTAssertEqual(haps[1].part.begin, Rational(1, 2))
        XCTAssertEqual(haps[1].part.end,   Rational(2, 2))
    }

    // MARK: - 5. setcps / setcpm parsing

    func testSetcpsParsing() throws {
        let parser = CodeParser()
        let result = try parser.parseWithTempo("setcps(0.6)\ns(\"pad\")")
        XCTAssertEqual(result.cps ?? 0.0, 0.6, accuracy: 1e-9)
        let haps = result.pattern.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["s"], .string("pad"))
    }

    func testSetcpmParsing() throws {
        let parser = CodeParser()
        // setcpm(60) = setcps(1.0)
        let result = try parser.parseWithTempo("setcpm(60)\ns(\"pad\")")
        XCTAssertEqual(result.cps.map { Double($0) } ?? 0.0, 1.0, accuracy: 1e-9)
    }

    func testSetcpmHalfSpeed() throws {
        let parser = CodeParser()
        // setcpm(30) = setcps(0.5) — default
        let result = try parser.parseWithTempo("setcpm(30)\ns(\"bell\")")
        XCTAssertEqual(result.cps ?? 0, 0.5, accuracy: 1e-9)
    }

    func testSetcpsNilWhenAbsent() throws {
        let parser = CodeParser()
        let result = try parser.parseWithTempo("s(\"pad\")")
        XCTAssertNil(result.cps, "cps should be nil if setcps not present")
    }

    func testSetcpsPatternNotAffected() throws {
        // setcps should not change hap times (those are in cycle units)
        let parser = CodeParser()
        let withTempo = try parser.parseWithTempo("setcps(0.6)\ns(\"pad bell\")")
        let noTempo   = try parser.parseWithTempo("s(\"pad bell\")")
        let h1 = withTempo.pattern.firstCycle().sorted { $0.part.begin < $1.part.begin }
        let h2 = noTempo.pattern.firstCycle().sorted   { $0.part.begin < $1.part.begin }
        XCTAssertEqual(h1.count, h2.count)
        for (a, b) in zip(h1, h2) {
            XCTAssertEqual(a.part.begin, b.part.begin)
            XCTAssertEqual(a.part.end,   b.part.end)
        }
    }

    // MARK: - 6. n() + scale()

    func testScaleDegreesMIDI() {
        // C natural minor: C=48, D=50, Eb=51, F=53, G=55, Ab=56, Bb=58
        let minorIntervals = [0, 2, 3, 5, 7, 8, 10]
        let rootC3 = 48
        XCTAssertEqual(scaleDegreeToMidi(index: 0, root: rootC3, intervals: minorIntervals), 48) // C3
        XCTAssertEqual(scaleDegreeToMidi(index: 1, root: rootC3, intervals: minorIntervals), 50) // D3
        XCTAssertEqual(scaleDegreeToMidi(index: 2, root: rootC3, intervals: minorIntervals), 51) // Eb3
        XCTAssertEqual(scaleDegreeToMidi(index: 4, root: rootC3, intervals: minorIntervals), 55) // G3
        XCTAssertEqual(scaleDegreeToMidi(index: 6, root: rootC3, intervals: minorIntervals), 58) // Bb3
        XCTAssertEqual(scaleDegreeToMidi(index: 7, root: rootC3, intervals: minorIntervals), 60) // C4 (octave up)
        XCTAssertEqual(scaleDegreeToMidi(index: 8, root: rootC3, intervals: minorIntervals), 62) // D4
        XCTAssertEqual(scaleDegreeToMidi(index: -1, root: rootC3, intervals: minorIntervals), 46) // Bb2
    }

    func testNPlusScaleBasicMIDI() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"n("0 2 4").scale("C:minor").s("bell")"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        // n(0) = C3 = 48, n(2) = Eb3 = 51, n(4) = G3 = 55
        XCTAssertEqual(haps[0].value["note"], .double(48))
        XCTAssertEqual(haps[1].value["note"], .double(51))
        XCTAssertEqual(haps[2].value["note"], .double(55))
        // All have s="bell"
        for hap in haps {
            XCTAssertEqual(hap.value["s"], .string("bell"))
        }
        // n and scale keys should be removed after resolution
        for hap in haps {
            XCTAssertNil(hap.value["n"])
            XCTAssertNil(hap.value["scale"])
        }
    }

    func testNPlusScaleNegativeAndOctaveWrap() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"n("-1 7 8").scale("C:minor").s("bell")"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        // n(-1) = Bb2 = 46, n(7) = C4 = 60, n(8) = D4 = 62
        XCTAssertEqual(haps[0].value["note"], .double(46))
        XCTAssertEqual(haps[1].value["note"], .double(60))
        XCTAssertEqual(haps[2].value["note"], .double(62))
    }

    func testNPlusScaleMajor() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"n("0 4 7").scale("C:major")"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        // C major from C3=48: intervals [0,2,4,5,7,9,11]
        // n(0)=48, n(4)=55, n(7)=60
        XCTAssertEqual(haps[0].value["note"], .double(48))  // C3
        XCTAssertEqual(haps[1].value["note"], .double(55))  // G3
        XCTAssertEqual(haps[2].value["note"], .double(60))  // C4
    }

    func testParseScaleFunction() {
        // Verify parseScale returns correct root and intervals
        let result = parseScale("C:minor")
        XCTAssertNotNil(result)
        if let (root, intervals) = result {
            XCTAssertEqual(root, 48)  // C3
            XCTAssertEqual(intervals, [0, 2, 3, 5, 7, 8, 10])
        }
    }

    func testParseScaleMajor() {
        let result = parseScale("G:major")
        XCTAssertNotNil(result)
        if let (root, _) = result {
            XCTAssertEqual(root, 55)  // G3 = MIDI 55
        }
    }

    // MARK: - Code parser integration

    func testCodeParserAllTier1() throws {
        // Ensure a comprehensive Tier 1 pattern parses without error
        let parser = CodeParser()
        let code = """
        setcps(0.6)
        stack(
          s("pad").pan(0.3).delay(0.3),
          n("0 2 4").scale("C:minor").s("bell").euclid(3,8)
        )
        """
        let result = try parser.parseWithTempo(code)
        XCTAssertEqual(result.cps ?? 0, 0.6, accuracy: 1e-9)
        let haps = result.pattern.firstCycle()
        XCTAssertFalse(haps.isEmpty)
    }
}
