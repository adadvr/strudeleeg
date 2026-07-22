import XCTest
@testable import MiniEngine

final class DebugTests: XCTestCase {

    func testPadSlow4Over4Cycles() {
        // Oracle: 1 hap with part [0, 4) for [0,4) span
        let pat = s("pad").slow(4)
        let haps = pat.queryArc(Rational(0), Rational(4))
        print("[Debug] s(pad).slow(4) over [0,4): \(haps.count) haps")
        for h in haps.sorted(by: { $0.part.begin < $1.part.begin }) {
            print("  part: \(h.part)  value: \(h.value)")
        }
        XCTAssertEqual(haps.count, 1)
    }

    func testPadSlow4Over8Cycles() {
        // Oracle: 2 haps, part [0,4) and [4,8)
        // Our engine should match
        let pat = Pattern<String>.pure("pad").slow(Rational(4))
        let haps = pat.queryArc(Rational(0), Rational(8))
        print("[Debug] pure(pad).slow(4) over [0,8): \(haps.count) haps")
        for h in haps.sorted(by: { $0.part.begin < $1.part.begin }) {
            print("  part: \(h.part)  whole: \(h.whole.map { $0.description } ?? "nil")")
        }
        XCTAssertEqual(haps.count, 2, "Expected 2 haps (one per 4-cycle period)")

        // Now add gain
        let sPat = s("pad").slow(4)
        let hapsBefore = sPat.queryArc(Rational(0), Rational(8))
        print("[Debug] s(pad).slow(4) before gain: \(hapsBefore.count) haps")
        for h in hapsBefore.sorted(by: { $0.part.begin < $1.part.begin }) {
            print("  part: \(h.part)  value: \(h.value)")
        }

        let patWithGain = sPat.gain(0.5)
        let hapsAfterGain = patWithGain.queryArc(Rational(0), Rational(8))
        print("[Debug] s(pad).slow(4).gain(0.5): \(hapsAfterGain.count) haps")
        for h in hapsAfterGain.sorted(by: { $0.part.begin < $1.part.begin }) {
            print("  part: \(h.part)  value: \(h.value)")
        }
    }

    func testStackPatternHapCount() throws {
        let parser = CodeParser()
        let code = """
        stack(
          s("pad").slow(4).gain(0.5).room(0.6),
          note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7)
        )
        """
        let pat = try parser.parse(code)
        let haps = pat.queryArc(Rational(0), Rational(8))
        print("[Debug] Stack over [0,8): \(haps.count) haps")
        for h in haps.sorted(by: { $0.part.begin < $1.part.begin }) {
            let s = h.value["s"]?.stringValue ?? "?"
            let note = h.value["note"]?.doubleValue.map { "\(Int($0))" } ?? "-"
            print("  s=\(s) note=\(note) part=\(h.part)")
        }
        // Oracle shows 16 haps: pad repeats every 1 cycle (each cycle = one hap)
        // within 4-cycle periods, and bell every 1 cycle within 2-cycle periods.
        // Total: 8 cycles × (1 pad + 1 bell) = 16 haps.
        XCTAssertEqual(haps.count, 16, "Expected 16 haps (oracle-verified)")
    }
}
