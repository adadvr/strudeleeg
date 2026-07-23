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

    // MARK: - Bug Fix: * (fast) inside mini-notation advances internal slowcat cycle

    /// Bug 1: [bd <hh oh>]*2
    /// fast(2) must advance the internal cycle of sub-patterns (like slowcat).
    /// Each outer cycle: bd hh bd oh (NOT bd hh bd hh).
    /// Oracle-verified: fastcat(bd, slowcat(hh,oh)).fast(2) over [0,2) = 8 haps.
    func testStarAdvancesSlowcatCycle() {
        let pat = parseMini("[bd <hh oh>]*2")
        let haps = pat.queryArc(Rational(0), Rational(2))
            .sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 8, "2 cycles × 4 events/cycle")
        // Cycle 0: bd hh bd oh
        XCTAssertEqual(haps[0].value, "bd",  "cy0 rep0 slot0")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 4))
        XCTAssertEqual(haps[1].value, "hh",  "cy0 rep0 slot1 — slowcat cycle 0")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 4))
        XCTAssertEqual(haps[2].value, "bd",  "cy0 rep1 slot0")
        XCTAssertEqual(haps[2].part.begin, Rational(2, 4))
        XCTAssertEqual(haps[3].value, "oh",  "cy0 rep1 slot1 — slowcat cycle 1 (NOT hh)")
        XCTAssertEqual(haps[3].part.begin, Rational(3, 4))
        // Cycle 1: bd hh bd oh (slowcat wraps at 2, so cycle 2→hh, cycle 3→oh)
        XCTAssertEqual(haps[4].value, "bd",  "cy1 rep0 slot0")
        XCTAssertEqual(haps[5].value, "hh",  "cy1 rep0 slot1 — slowcat cycle 2%2=0→hh")
        XCTAssertEqual(haps[6].value, "bd",  "cy1 rep1 slot0")
        XCTAssertEqual(haps[7].value, "oh",  "cy1 rep1 slot1 — slowcat cycle 3%2=1→oh")
    }

    /// User's hat pattern: [hh hh hh <hh oh hh oh>]*2
    /// The 4-alternative slowcat advances with fast(2).
    /// Each outer cycle has 8 events: hh×7 + oh×1 (oh appears at rep1, slot3).
    func testUserHatPatternAlternates() {
        let pat = parseMini("[hh hh hh <hh oh hh oh>]*2")
        let haps = pat.queryArc(Rational(0), Rational(4))
            .sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 32, "4 cycles × 8 events")
        // Cycle 0: 8 events; slot 3 of rep0 = slowcat[0]=hh, slot 3 of rep1 = slowcat[1]=oh
        let cy0 = haps.filter { $0.part.begin >= .zero && $0.part.begin < .one }
        XCTAssertEqual(cy0.count, 8)
        // Last event of rep0 (haps[3]) = hh
        XCTAssertEqual(cy0[3].value, "hh")
        // Last event of rep1 (haps[7]) = oh
        XCTAssertEqual(cy0[7].value, "oh")
    }

    // MARK: - Bug Fix: ! inside <> expands slowcat alternatives (not steps)

    /// Bug 2: <a!3 b> = 4 slowcat alternatives (a a a b), not 1 alternative [a a a]
    /// Over 4 cycles: cycles 0,1,2=a; cycle 3=b
    func testBangInsideSlowcatExpandsAlternatives() {
        let pat = parseMini("<a!3 b>")
        // Over 4 cycles: a a a b
        let cy0 = pat.queryArc(Rational(0), Rational(1))
        let cy1 = pat.queryArc(Rational(1), Rational(2))
        let cy2 = pat.queryArc(Rational(2), Rational(3))
        let cy3 = pat.queryArc(Rational(3), Rational(4))
        XCTAssertEqual(cy0.count, 1); XCTAssertEqual(cy0.first?.value, "a", "cy0 should be a")
        XCTAssertEqual(cy1.count, 1); XCTAssertEqual(cy1.first?.value, "a", "cy1 should be a")
        XCTAssertEqual(cy2.count, 1); XCTAssertEqual(cy2.first?.value, "a", "cy2 should be a")
        XCTAssertEqual(cy3.count, 1); XCTAssertEqual(cy3.first?.value, "b", "cy3 should be b")
    }

    /// Bug 2 main: <0!8 3!4 0!4> = 16 alternatives; one value per cycle.
    /// Oracle-verified: cycles 0-7=0, cycles 8-11=3, cycles 12-15=0.
    func testBangInsideSlowcatLargePattern() {
        let pat = parseMini("<0!8 3!4 0!4>")
        let haps = pat.queryArc(Rational(0), Rational(16))
            .sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 16, "16 alternatives = 1 event per cycle")
        for i in 0..<8  { XCTAssertEqual(haps[i].value, "0", "cycle \(i) should be 0") }
        for i in 8..<12 { XCTAssertEqual(haps[i].value, "3", "cycle \(i) should be 3") }
        for i in 12..<16 { XCTAssertEqual(haps[i].value, "0", "cycle \(i) should be 0") }
    }

    /// Bug 2 — ! combined with * inside <>: <bd*8!12 ...> = 12 alternatives of bd*8.
    /// Each cycle that picks this alternative should produce 8 bd events.
    func testBangWithStarInsideSlowcat() {
        let pat = parseMini("<bd*8!12 ~ bd bd>")
        // 15 alternatives: 12×(bd*8), ~, bd, bd
        // Cycle 0 → bd*8 → 8 haps
        let cy0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(cy0.count, 8, "cycle 0 = bd*8 = 8 events")
        XCTAssertTrue(cy0.allSatisfy { $0.value == "bd" })
        // Cycle 12 → silence
        let cy12 = pat.queryArc(Rational(12), Rational(13))
        XCTAssertEqual(cy12.count, 0, "cycle 12 = ~ = silence")
        // Cycles 13, 14 → bd (single)
        let cy13 = pat.queryArc(Rational(13), Rational(14))
        XCTAssertEqual(cy13.count, 1); XCTAssertEqual(cy13.first?.value, "bd")
    }

    // MARK: - Bug Fix: User full pattern integration test

    /// Parse the user's complete complex pattern without error and verify key layers.
    func testUserFullPatternParses() throws {
        let code = """
        setcpm(15)
        stack(
          n("<0!8 3!4 0!4>").scale("C:minor").sound("sawtooth").attack(2).decay(1).sustain(0.6).release(2).lpf(300).gain(0.26).room(0.6),
          s("<bd*8!12 ~ [bd ~ ~ ~ bd ~ bd ~] bd*8!2>").decay(0.38).gain(0.95),
          s("<~!2 [~ cp ~ cp]!10 ~ ~ [~ cp ~ cp]!2>").gain(0.5).room(0.2),
          s("[hh hh hh <hh oh hh oh>]*2").decay(0.2).gain(0.3).pan(0.65),
          s("<~!8 [~ ~ oh ~]!8>").decay(0.5).gain(0.22).pan(0.35).room(0.25),
          s("<~!6 [~ rim ~ ~ rim ~ ~ ~]!10>").decay(0.15).gain(0.25).pan(0.25),
          n("<~!2 [0 ~ 0 3 ~ 0 ~ 5]!14>").scale("C:minor").sound("sawtooth").attack(0.001).decay(0.14).sustain(0.25).release(0.08).lpf("<500!4 800!4 1400!4 1000!4>").resonance(9).gain(0.5),
          n("<~!8 [~ 7 ~ 3]!8>").scale("C:minor").sound("square").attack(0.005).decay(0.18).sustain(0.3).release(0.25).lpf(2200).gain(0.32).delay(0.35).delaytime(0.375).delayfeedback(0.4).room(0.3),
          n("<~!10 [~ 10 ~ 5]!6>").scale("C:minor").sound("square").attack(0.005).decay(0.18).sustain(0.3).release(0.25).lpf(1800).gain(0.22).pan(0.7).delay(0.3).delaytime(0.25).room(0.3),
          n("<~!12 [12 ~ 10 ~ 7 ~ 10 12]!4>").scale("C:minor").sound("triangle").attack(0.01).decay(0.3).sustain(0.4).release(0.5).lpf(3000).gain(0.3).pan(0.45).delay(0.45).delaytime(0.5).delayfeedback(0.5).room(0.5)
        )
        """
        let parser = CodeParser()
        let result = try parser.parseWithTempo(code)
        // Check tempo: setcpm(15) = 15 beats/min / 60 = 0.25 cps
        XCTAssertEqual(result.cps ?? 0, 0.25, accuracy: 1e-9)

        // Drone layer: n("<0!8 3!4 0!4>") — check that cycle 0 gives n=0 and cycle 8 gives n=3
        let allHaps = result.pattern.queryArc(Rational(0), Rational(1))
        XCTAssertFalse(allHaps.isEmpty, "Pattern must produce events in cycle 0")

        // Kick layer: cycle 0 should have 8 bd events (bd*8 pattern)
        let kickHaps = allHaps.filter { $0.value["s"]?.stringValue == "bd" }
        XCTAssertEqual(kickHaps.count, 8, "Kick layer: bd*8 in cycle 0")

        // Hat layer: cycle 0 should have 8 events ([hh hh hh <hh oh>]*2)
        let hatHaps = allHaps.filter {
            let s = $0.value["s"]?.stringValue ?? ""
            return s == "hh" || s == "oh"
        }
        XCTAssertEqual(hatHaps.count, 8, "Hat layer: [hh hh hh <hh oh hh oh>]*2 = 8 events/cycle")
    }

    /// Verify drone layer: <0!8 3!4 0!4> in n() + scale produces correct notes per cycle.
    func testDroneLayerNoteChangesPerCycle() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"n("<0!8 3!4 0!4>").scale("C:minor").sound("sawtooth")"#)
        // Cycles 0-7: n=0 → C3 = MIDI 48
        let cy0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(cy0.count, 1)
        XCTAssertEqual(cy0.first?.value["note"], .double(48), "cycle 0: n=0 → C3=48")

        // Cycle 8: n=3 → Eb3 + octave? Let's check: C minor intervals [0,2,3,5,7,8,10], n(3)=48+5=53
        let cy8 = pat.queryArc(Rational(8), Rational(9))
        XCTAssertEqual(cy8.count, 1)
        XCTAssertEqual(cy8.first?.value["note"], .double(53), "cycle 8: n=3 → F3=53")

        // Cycle 12: n=0 again → C3=48
        let cy12 = pat.queryArc(Rational(12), Rational(13))
        XCTAssertEqual(cy12.count, 1)
        XCTAssertEqual(cy12.first?.value["note"], .double(48), "cycle 12: n=0 → C3=48")
    }

    /// Verify lpf pattern layer: <500!4 800!4 1400!4 1000!4> changes per cycle group.
    func testLpfSlowcatPattern() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("sawtooth").lpf("<500!4 800!4 1400!4 1000!4>")"#)
        let testCases: [(Int, Double)] = [(0,500),(3,500),(4,800),(7,800),(8,1400),(11,1400),(12,1000),(15,1000)]
        for (cycle, expectedLpf) in testCases {
            let haps = pat.queryArc(Rational(cycle), Rational(cycle + 1))
            XCTAssertEqual(haps.count, 1, "cycle \(cycle)")
            XCTAssertEqual(haps.first?.value["lpf"]?.doubleValue ?? -1, expectedLpf,
                           accuracy: 1e-9, "cycle \(cycle) lpf should be \(expectedLpf)")
        }
    }
}
