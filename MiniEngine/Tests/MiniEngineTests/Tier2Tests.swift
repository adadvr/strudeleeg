// ---------------------------------------------------------------------------
// Tier2Tests — Phase 2 / Tier 3: Pattern algebra
//
// Tests for: rev, ply, every, sometimes/often/rarely, off, jux, struct
// Plus CodeParser integration for all of the above.
//
// RNG note: sometimes/often/rarely use a deterministic PRNG seeded by
// (cycle, eventIndex). Tests verify determinism and approximate probability
// over many cycles — not bit-identical output to Strudel (which uses a
// time-based RNG, not accessible clean-room).
// ---------------------------------------------------------------------------

import XCTest
@testable import MiniEngine

final class Tier2Tests: XCTestCase {

    // MARK: - rev

    func testRevTwoElements() {
        // s("pad bell").rev → bell at [0,1/2), pad at [1/2,1)
        let pat = fastcat(Pattern<String>.pure("pad"), Pattern<String>.pure("bell")).rev
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value, "bell")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 2))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 2))
        XCTAssertEqual(haps[1].value, "pad")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 2))
        XCTAssertEqual(haps[1].part.end,   Rational(2, 2))
    }

    func testRevThreeElements() {
        // "a b c".rev → "c b a"
        let pat = fastcat(
            Pattern<String>.pure("a"),
            Pattern<String>.pure("b"),
            Pattern<String>.pure("c")
        ).rev
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        XCTAssertEqual(haps[0].value, "c")
        XCTAssertEqual(haps[1].value, "b")
        XCTAssertEqual(haps[2].value, "a")
    }

    func testRevSingleElement() {
        // Reversing a single event is identity
        let pat = Pattern<String>.pure("pad").rev
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, "pad")
        XCTAssertEqual(haps[0].part.begin, Rational(0))
        XCTAssertEqual(haps[0].part.end,   Rational(1))
    }

    func testRevWithSubgroup() {
        // "[pad bell] hi".rev → hi at [0,1/2), then [bell pad] at [1/2,1)
        // (subgroup itself also reverses: bell at [1/2,3/4), pad at [3/4,1))
        let inner = fastcat(Pattern<String>.pure("pad"), Pattern<String>.pure("bell"))
        let pat = fastcat(inner, Pattern<String>.pure("hi")).rev
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        XCTAssertEqual(haps[0].value, "hi")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 2))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 2))
        // subgroup reversed: bell then pad
        XCTAssertEqual(haps[1].value, "bell")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 2))
        XCTAssertEqual(haps[2].value, "pad")
        XCTAssertEqual(haps[2].part.begin, Rational(3, 4))
    }

    func testRevIdempotent() {
        // rev.rev should equal original
        let pat = fastcat(
            Pattern<String>.pure("a"),
            Pattern<String>.pure("b"),
            Pattern<String>.pure("c")
        )
        let revrev = pat.rev.rev
        let orig = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        let rr   = revrev.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(orig.count, rr.count)
        for (o, r) in zip(orig, rr) {
            XCTAssertEqual(o.value, r.value)
            XCTAssertEqual(o.part.begin, r.part.begin)
        }
    }

    func testRevCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad bell").rev"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value["s"], .string("bell"))
        XCTAssertEqual(haps[1].value["s"], .string("pad"))
    }

    func testRevMultipleCycles() {
        // rev should work consistently across multiple cycles
        let pat = fastcat(Pattern<String>.pure("a"), Pattern<String>.pure("b")).rev
        for cycle in 0..<4 {
            let haps = pat.queryArc(Rational(cycle), Rational(cycle + 1))
                .sorted { $0.part.begin < $1.part.begin }
            XCTAssertEqual(haps.count, 2)
            XCTAssertEqual(haps[0].value, "b", "cycle \(cycle)")
            XCTAssertEqual(haps[1].value, "a", "cycle \(cycle)")
        }
    }

    // MARK: - ply

    func testPly2OnSingleEvent() {
        // pure("pad").ply(2) → 2 events at [0,1/2) and [1/2,1)
        let pat = Pattern<String>.pure("pad").ply(2)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value, "pad")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 2))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 2))
        XCTAssertEqual(haps[1].value, "pad")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 2))
        XCTAssertEqual(haps[1].part.end,   Rational(2, 2))
    }

    func testPly3OnSingleEvent() {
        // pure("pad").ply(3) → 3 events each 1/3 cycle
        let pat = Pattern<String>.pure("pad").ply(3)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        XCTAssertEqual(haps[0].part.begin, Rational(0, 3))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 3))
        XCTAssertEqual(haps[1].part.begin, Rational(1, 3))
        XCTAssertEqual(haps[2].part.begin, Rational(2, 3))
    }

    func testPly2OnSequence() {
        // fastcat("pad","bell").ply(2) → 4 events: pad*2, bell*2
        let pat = fastcat(Pattern<String>.pure("pad"), Pattern<String>.pure("bell")).ply(2)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4)
        XCTAssertEqual(haps[0].value, "pad")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 4))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 4))
        XCTAssertEqual(haps[1].value, "pad")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 4))
        XCTAssertEqual(haps[2].value, "bell")
        XCTAssertEqual(haps[2].part.begin, Rational(2, 4))
        XCTAssertEqual(haps[3].value, "bell")
        XCTAssertEqual(haps[3].part.begin, Rational(3, 4))
    }

    func testPly1Identity() {
        // ply(1) should be identity
        let base = fastcat(Pattern<String>.pure("a"), Pattern<String>.pure("b"))
        let plied = base.ply(1)
        XCTAssertEqual(
            base.firstCycle().sorted { $0.part.begin < $1.part.begin }.map { $0.value },
            plied.firstCycle().sorted { $0.part.begin < $1.part.begin }.map { $0.value }
        )
    }

    func testPlyCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad bell").ply(2)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4)
        XCTAssertEqual(haps[0].value["s"], .string("pad"))
        XCTAssertEqual(haps[2].value["s"], .string("bell"))
    }

    func testPlyCodeParser3() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").ply(3)"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        for h in haps {
            XCTAssertEqual(h.value["s"], .string("pad"))
        }
    }

    // MARK: - every

    func testEvery2Fast2() {
        // every(2, fast(2)): cycle 0 gets fast(2) = 4 events; cycle 1 = 2 events
        let base = fastcat(Pattern<String>.pure("a"), Pattern<String>.pure("b"))
        let pat  = base.every(2) { $0.fast(2) }
        let c0 = pat.queryArc(Rational(0), Rational(1))
        let c1 = pat.queryArc(Rational(1), Rational(2))
        let c2 = pat.queryArc(Rational(2), Rational(3))
        XCTAssertEqual(c0.count, 4, "cycle 0 should be fast(2)")
        XCTAssertEqual(c1.count, 2, "cycle 1 should be normal")
        XCTAssertEqual(c2.count, 4, "cycle 2 = next block start")
    }

    func testEvery4Fast2() {
        // every(4, fast(2)): cycles 0,4,8 get 4 events; cycles 1,2,3,5,6,7 get 2
        let base = fastcat(Pattern<String>.pure("a"), Pattern<String>.pure("b"))
        let pat  = base.every(4) { $0.fast(2) }
        // Block 1: cycles 0-3
        XCTAssertEqual(pat.queryArc(Rational(0), Rational(1)).count, 4)
        XCTAssertEqual(pat.queryArc(Rational(1), Rational(2)).count, 2)
        XCTAssertEqual(pat.queryArc(Rational(2), Rational(3)).count, 2)
        XCTAssertEqual(pat.queryArc(Rational(3), Rational(4)).count, 2)
        // Block 2: cycles 4-7
        XCTAssertEqual(pat.queryArc(Rational(4), Rational(5)).count, 4)
        XCTAssertEqual(pat.queryArc(Rational(5), Rational(6)).count, 2)
    }

    func testEvery1AlwaysApplies() {
        // every(1, f): applies every cycle (all cycles are cycle-0 of their block of 1)
        let base = Pattern<String>.pure("pad")
        let pat  = base.every(1) { $0.fast(3) }
        XCTAssertEqual(pat.firstCycle().count, 3)
        XCTAssertEqual(pat.queryArc(Rational(1), Rational(2)).count, 3)
    }

    func testEveryCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad bell").every(4, x => x.fast(2))"#)
        let c0 = pat.queryArc(Rational(0), Rational(1))
        let c1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertEqual(c0.count, 4, "cycle 0 should be fast(2)")
        XCTAssertEqual(c1.count, 2, "cycle 1 should be normal")
    }

    func testEveryCodeParserChained() throws {
        // Test lambda with chained methods: x => x.fast(2).gain(0.5)
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").every(2, x => x.fast(2).gain(0.5))"#)
        let c0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(c0.count, 2, "fast(2) doubles events")
        for h in c0 {
            XCTAssertEqual(h.value["gain"], .double(0.5), "gain(0.5) applied")
        }
    }

    // MARK: - sometimes / often / rarely

    func testSometimesDeterminism() {
        // Same pattern queried twice should give same results (deterministic PRNG)
        let pat = Pattern<String>.pure("pad").sometimes { $0.fast(2) }
        let r1 = (0..<50).flatMap { c in pat.queryArc(Rational(c), Rational(c+1)).map { $0.value } }
        let r2 = (0..<50).flatMap { c in pat.queryArc(Rational(c), Rational(c+1)).map { $0.value } }
        XCTAssertEqual(r1, r2, "PRNG must be deterministic: same seed → same output")
    }

    func testSometimesApproximateProbability() {
        // sometimes(0.5) should apply ~50% of the time over many cycles
        let pat = Pattern<String>.pure("pad").sometimes { $0.fast(2) }
        var applied = 0
        let total = 1000
        for c in 0..<total {
            let count = pat.queryArc(Rational(c), Rational(c+1)).count
            if count == 2 { applied += 1 }
        }
        let ratio = Double(applied) / Double(total)
        XCTAssertGreaterThan(ratio, 0.35, "sometimes should apply at least 35% of the time")
        XCTAssertLessThan(ratio, 0.65, "sometimes should apply at most 65% of the time")
    }

    func testOftenApproximateProbability() {
        // often(0.75) should apply ~75% of the time
        let pat = Pattern<String>.pure("pad").often { $0.fast(2) }
        var applied = 0
        let total = 1000
        for c in 0..<total {
            let count = pat.queryArc(Rational(c), Rational(c+1)).count
            if count == 2 { applied += 1 }
        }
        let ratio = Double(applied) / Double(total)
        XCTAssertGreaterThan(ratio, 0.55, "often should apply more than 55% of the time")
        XCTAssertLessThan(ratio, 0.90, "often should apply less than 90% of the time")
    }

    func testRarelyApproximateProbability() {
        // rarely(0.25) should apply ~25% of the time
        let pat = Pattern<String>.pure("pad").rarely { $0.fast(2) }
        var applied = 0
        let total = 1000
        for c in 0..<total {
            let count = pat.queryArc(Rational(c), Rational(c+1)).count
            if count == 2 { applied += 1 }
        }
        let ratio = Double(applied) / Double(total)
        XCTAssertGreaterThan(ratio, 0.10, "rarely should apply at least 10% of the time")
        XCTAssertLessThan(ratio, 0.45, "rarely should apply at most 45% of the time")
    }

    func testSometimesByNeverApplies() {
        let pat = Pattern<String>.pure("pad").sometimesBy(0.0) { $0.fast(2) }
        // prob=0 → never applied → always 1 event
        for c in 0..<10 {
            XCTAssertEqual(pat.queryArc(Rational(c), Rational(c+1)).count, 1,
                           "prob=0 should never apply")
        }
    }

    func testSometimesByAlwaysApplies() {
        let pat = Pattern<String>.pure("pad").sometimesBy(1.0) { $0.fast(2) }
        // prob=1 → always applied → always 2 events
        for c in 0..<10 {
            XCTAssertEqual(pat.queryArc(Rational(c), Rational(c+1)).count, 2,
                           "prob=1 should always apply")
        }
    }

    func testSometimesCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").sometimes(x => x.fast(2))"#)
        // Just verify it parses and produces events without crashing
        var totalEvents = 0
        for c in 0..<20 {
            totalEvents += pat.queryArc(Rational(c), Rational(c+1)).count
        }
        XCTAssertGreaterThan(totalEvents, 20, "should produce more than baseline events sometimes")
    }

    func testOftenCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").often(x => x.fast(2))"#)
        var applied = 0
        for c in 0..<20 {
            let count = pat.queryArc(Rational(c), Rational(c+1)).count
            if count == 2 { applied += 1 }
        }
        XCTAssertGreaterThan(applied, 5, "often should apply frequently")
    }

    func testRarelyCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").rarely(x => x.fast(2))"#)
        // Verify it parses and runs without error
        var total = 0
        for c in 0..<20 {
            total += pat.queryArc(Rational(c), Rational(c+1)).count
        }
        XCTAssertGreaterThanOrEqual(total, 20, "rarely should still produce at least base events")
    }

    // MARK: - off

    func testOffShiftsEventsRight() {
        // off(0.25, identity): should have 2 copies, shifted right by 0.25
        // Original at [0,1), shifted copy appears at [0.25, 1.25) (wraps into [0,0.25) and [0.25,1))
        let base = Pattern<String>.pure("pad")
        let pat  = base.off(Rational(1, 4)) { $0 }
        let haps = pat.queryArc(Rational(0), Rational(1))
        // Should have original + shifted fragment
        XCTAssertGreaterThan(haps.count, 1, "off should produce extra events")
    }

    func testOffStructure() {
        // off(0.25, gain 0.5) on pure bell:
        // Original: whole=[0,1), part=[0,1)
        // Shifted: cycle -1 bell becomes whole=[-3/4, 1/4), part=[0,1/4)
        //          cycle 0 bell becomes whole=[1/4, 5/4), part=[1/4,1)
        let base = s("bell")
        let pat  = base.off(Rational(1, 4)) { $0.gain(0.5) }
        let haps = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }

        // 3 haps: original + 2 fragments of shifted copy
        XCTAssertEqual(haps.count, 3)
        // hap[0]: original bell [0,1)
        XCTAssertEqual(haps[0].value["s"], .string("bell"))
        XCTAssertNil(haps[0].value["gain"])
        // hap[1]: shifted fragment [0, 1/4)
        XCTAssertEqual(haps[1].value["gain"], .double(0.5))
        XCTAssertEqual(haps[1].part.end,   Rational(1, 4))
        // hap[2]: shifted fragment [1/4, 1)
        XCTAssertEqual(haps[2].value["gain"], .double(0.5))
        XCTAssertEqual(haps[2].part.begin, Rational(1, 4))
    }

    func testOffCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bell").off(0.25, x => x.gain(0.5))"#)
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 3)
        // Should have original (no gain) + shifted copies (with gain)
        let original = haps.filter { $0.value["gain"] == nil }
        let shifted  = haps.filter { $0.value["gain"] == .double(0.5) }
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(shifted.count, 2)
    }

    // MARK: - jux

    func testJuxPanValues() {
        // jux(f): original at pan=0 (left), f(copy) at pan=1 (right)
        let base = s("pad")
        let pat  = base.jux { $0.fast(2) }
        let haps = pat.firstCycle()

        let leftHaps  = haps.filter { $0.value["pan"] == .double(0.0) }
        let rightHaps = haps.filter { $0.value["pan"] == .double(1.0) }

        XCTAssertFalse(leftHaps.isEmpty, "jux should produce pan=0 events")
        XCTAssertFalse(rightHaps.isEmpty, "jux should produce pan=1 events")
        // Original: 1 event; fast(2) copy: 2 events
        XCTAssertEqual(leftHaps.count, 1)
        XCTAssertEqual(rightHaps.count, 2)
    }

    func testJuxIdentity() {
        // jux(identity) should give original at pan=0 + copy at pan=1 (same timing)
        let base = s("pad")
        let pat  = base.jux { $0 }
        let haps = pat.firstCycle()

        let left  = haps.filter { $0.value["pan"] == .double(0.0) }
        let right = haps.filter { $0.value["pan"] == .double(1.0) }
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(right.count, 1)
    }

    func testJuxCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad bell").jux(x => x.fast(2))"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 6)  // 2 left + 4 right

        let leftHaps  = haps.filter { $0.value["pan"] == .double(0.0) }
        let rightHaps = haps.filter { $0.value["pan"] == .double(1.0) }
        XCTAssertEqual(leftHaps.count, 2,  "original: pad, bell (pan=0)")
        XCTAssertEqual(rightHaps.count, 4, "fast(2) on pad bell: 4 events (pan=1)")
    }

    func testJuxOracleConfirmedPanValues() {
        // Oracle confirmed: jux uses pan=0 (not 0.5) for original
        // and pan=1 (not some other value) for the transformed copy
        let base = s("pad")
        let pat  = base.jux { $0 }
        let haps = pat.firstCycle()
        let pans = Set(haps.compactMap { $0.value["pan"]?.doubleValue })
        XCTAssertTrue(pans.contains(0.0), "jux left channel must be pan=0")
        XCTAssertTrue(pans.contains(1.0), "jux right channel must be pan=1")
    }

    // MARK: - struct

    func testStructBasicMask() {
        // s("bell").structGate via string mini-notation "t f t t"
        // → 3 events at [0,1/4), [1/2,3/4), [3/4,1)
        // Use the string mini-notation form (avoids Pattern<Bool> specialization in tests)
        let pat = s("bell").structGate("t f t t")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        XCTAssertEqual(haps[0].part.begin, Rational(0, 4))
        XCTAssertEqual(haps[0].part.end,   Rational(1, 4))
        XCTAssertEqual(haps[1].part.begin, Rational(2, 4))
        XCTAssertEqual(haps[1].part.end,   Rational(3, 4))
        XCTAssertEqual(haps[2].part.begin, Rational(3, 4))
        XCTAssertEqual(haps[2].part.end,   Rational(4, 4))
        for h in haps {
            XCTAssertEqual(h.value["s"], ControlValue.string("bell"))
        }
    }

    func testStructStringMaskTilda() {
        // structGate("t ~ t t") → same as above, using mini-notation
        let pat = s("bell").structGate("t ~ t t")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        XCTAssertEqual(haps[0].part.begin, Rational(0, 4))
        XCTAssertEqual(haps[1].part.begin, Rational(2, 4))
        XCTAssertEqual(haps[2].part.begin, Rational(3, 4))
    }

    func testStructAllTrue() {
        // "t t t t" → 4 events
        let pat = s("bell").structGate("t t t t")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 4)
    }

    func testStructAllFalse() {
        // "~ ~ ~ ~" → 0 events (silence)
        let pat = s("bell").structGate("~ ~ ~ ~")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 0)
    }

    func testStructCodeParser() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bell").struct("t ~ t t")"#)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        XCTAssertEqual(haps[0].part.begin, Rational(0, 4))
        XCTAssertEqual(haps[1].part.begin, Rational(2, 4))
        XCTAssertEqual(haps[2].part.begin, Rational(3, 4))
    }

    func testStructRepeatsCorrectly() {
        // struct should repeat the same pattern each cycle
        let pat = s("bell").structGate("t ~ t")
        let c0 = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        let c1 = pat.queryArc(Rational(1), Rational(2)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c0.count, 2, "cycle 0: 2 events")
        XCTAssertEqual(c1.count, 2, "cycle 1: 2 events (same pattern repeats)")
        // Positions in cycle 1 should be offset by 1 cycle
        XCTAssertEqual(c1[0].part.begin, c0[0].part.begin + Rational(1))
    }

    // MARK: - PRNG properties

    func testPRNGDifferentSeeds() {
        // Different seeds should produce different outputs
        var rng0 = MiniPRNG(cycle: 0, eventIndex: 0)
        var rng1 = MiniPRNG(cycle: 1, eventIndex: 0)
        var rng2 = MiniPRNG(cycle: 0, eventIndex: 1)
        let v0 = rng0.nextDouble()
        let v1 = rng1.nextDouble()
        let v2 = rng2.nextDouble()
        // While not guaranteed, different seeds almost always give different values
        XCTAssertFalse(v0 == v1 && v0 == v2, "PRNG seeds should produce different output")
    }

    func testPRNGRange() {
        // All values should be in [0, 1)
        for c in 0..<100 {
            var rng = MiniPRNG(cycle: c, eventIndex: c % 3)
            for _ in 0..<10 {
                let v = rng.nextDouble()
                XCTAssertGreaterThanOrEqual(v, 0.0, "PRNG value must be >= 0")
                XCTAssertLessThan(v, 1.0, "PRNG value must be < 1")
            }
        }
    }

    // MARK: - Composition / integration

    func testRevThenPly() {
        // rev then ply — should work without crashing
        let pat = fastcat(
            Pattern<String>.pure("a"),
            Pattern<String>.pure("b")
        ).rev.ply(2)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 4, "rev + ply(2) should give 4 events")
    }

    func testEveryAndJux() throws {
        // Compose every + jux
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").every(2, x => x.fast(2)).jux(x => x.gain(0.5))"#)
        // cycle 0: fast(2) on pad → 2 events; jux doubles to 4 (pan 0 + pan 1)
        let c0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(c0.count, 4)
    }

    func testStructAndRev() throws {
        let parser = CodeParser()
        // struct first, then rev
        let pat = try parser.parse(#"s("bell").struct("t ~ t t").rev"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 3, "struct gives 3 events, rev preserves count")
    }
}
