import XCTest
@testable import MiniEngine

final class PatternTests: XCTestCase {

    // MARK: - pure

    func testPureFirstCycle() {
        let pat = Pattern<String>.pure("hello")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, "hello")
        XCTAssertEqual(haps[0].whole, TimeSpan(Rational(0), Rational(1)))
        XCTAssertEqual(haps[0].part,  TimeSpan(Rational(0), Rational(1)))
    }

    func testPureMultipleCycles() {
        let pat = Pattern<Int>.pure(42)
        let haps = pat.queryArc(Rational(0), Rational(3))
        XCTAssertEqual(haps.count, 3)
        for h in haps {
            XCTAssertEqual(h.value, 42)
        }
    }

    func testSilence() {
        let pat = Pattern<String>.silence
        XCTAssertTrue(pat.firstCycle().isEmpty)
        XCTAssertTrue(pat.queryArc(Rational(0), Rational(4)).isEmpty)
    }

    // MARK: - fastcat

    func testFastcatTwoElements() {
        let pat = fastcat(.pure("a"), .pure("b"))
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 2)
        // First half: "a", second half: "b"
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(sorted[0].value, "a")
        XCTAssertEqual(sorted[0].part.begin, Rational(0, 2))
        XCTAssertEqual(sorted[0].part.end,   Rational(1, 2))
        XCTAssertEqual(sorted[1].value, "b")
        XCTAssertEqual(sorted[1].part.begin, Rational(1, 2))
        XCTAssertEqual(sorted[1].part.end,   Rational(2, 2))
    }

    func testFastcatThreeElements() {
        let pat = fastcat(.pure("a"), .pure("b"), .pure("c"))
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 3)
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(sorted[0].value, "a")
        XCTAssertEqual(sorted[0].part, TimeSpan(Rational(0, 3), Rational(1, 3)))
        XCTAssertEqual(sorted[1].value, "b")
        XCTAssertEqual(sorted[2].value, "c")
        XCTAssertEqual(sorted[2].part, TimeSpan(Rational(2, 3), Rational(3, 3)))
    }

    func testFastcatRepeatsCycles() {
        let pat = fastcat(.pure("a"), .pure("b"))
        let haps = pat.queryArc(Rational(0), Rational(2))
        XCTAssertEqual(haps.count, 4) // 2 per cycle × 2 cycles
    }

    // MARK: - slowcat

    func testSlowcatTwoElements() {
        let pat = slowcat(.pure("a"), .pure("b"))
        // cycle 0 → "a", cycle 1 → "b"
        let c0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(c0.count, 1)
        XCTAssertEqual(c0[0].value, "a")

        let c1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertEqual(c1.count, 1)
        XCTAssertEqual(c1[0].value, "b")

        // cycle 2 → wraps to "a"
        let c2 = pat.queryArc(Rational(2), Rational(3))
        XCTAssertEqual(c2.count, 1)
        XCTAssertEqual(c2[0].value, "a")
    }

    func testSlowcatFourElements() {
        let pat = slowcat(.pure("c4"), .pure("e4"), .pure("g4"), .pure("b4"))
        let values = (0..<4).map { i -> String in
            let h = pat.queryArc(Rational(i), Rational(i + 1))
            return h.first?.value ?? ""
        }
        XCTAssertEqual(values, ["c4", "e4", "g4", "b4"])
    }

    // MARK: - fast / slow

    func testFast() {
        let pat = fastcat(.pure("a"), .pure("b")).fast(Rational(2))
        // At x2 speed the pattern repeats twice in one cycle → 4 events
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 4)
    }

    func testSlow() {
        let pat = Pattern<String>.pure("pad").slow(Rational(4))
        // Each event spans 4 cycles; in cycle 0 we get 1 event covering [0,4)
        let haps = pat.queryArc(Rational(0), Rational(4))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, "pad")
    }

    func testSlowWithSplitQuery() {
        // pure("pad").slow(4): querying [0,1) should still return the event
        let pat = Pattern<String>.pure("pad").slow(Rational(4))
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, "pad")
        // part covers [0,1) (clipped), whole covers [0,4)
        XCTAssertEqual(haps[0].whole, TimeSpan(Rational(0), Rational(4)))
        XCTAssertEqual(haps[0].part,  TimeSpan(Rational(0), Rational(1)))
    }

    // MARK: - stack

    func testStack() {
        let pat = stack(.pure("a"), .pure("b"))
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 2)
        let values = Set(haps.map { $0.value })
        XCTAssertEqual(values, Set(["a", "b"]))
    }

    // MARK: - map

    func testMap() {
        let pat = Pattern<Int>.pure(5).map { $0 * 2 }
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 10)
    }

    // MARK: - appLeft

    func testAppLeft() {
        // Combine "a b" (structure) with constant gain 0.5
        let base  = fastcat(.pure("a"), .pure("b"))
        let gainP = Pattern<([String: ControlValue]) -> [String: ControlValue]>.pure { dict in
            var d = dict; d["gain"] = .double(0.5); return d
        }
        // base as ControlPattern
        let basePat = base.map { ["s": ControlValue.string($0)] }
        let combined = appLeft(gainP, basePat)
        let haps = combined.firstCycle()
        XCTAssertEqual(haps.count, 2)
        for h in haps {
            XCTAssertEqual(h.value["gain"], .double(0.5))
        }
    }
}
