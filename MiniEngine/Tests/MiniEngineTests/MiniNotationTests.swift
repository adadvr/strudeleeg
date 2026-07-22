import XCTest
@testable import MiniEngine

final class MiniNotationTests: XCTestCase {

    // MARK: - Basic sequence

    func testSingleElement() {
        let pat = parseMini("pad")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, "pad")
    }

    func testTwoElements() {
        let pat = parseMini("pad bell")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value, "pad")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 2))
        XCTAssertEqual(haps[1].value, "bell")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 2))
    }

    func testSilence() {
        let pat = parseMini("pad ~ bell")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        // 3 slots: pad at 0/3, silence at 1/3, bell at 2/3
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value, "pad")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 3))
        XCTAssertEqual(haps[1].value, "bell")
        XCTAssertEqual(haps[1].part.begin, Rational(2, 3))
    }

    // MARK: - Groups [...]

    func testGroup() {
        // "[pad bell] pad" — first step = [pad bell] = pad at 0, bell at 1/4
        let pat = parseMini("[pad bell] pad")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        // 3 events: pad@0/4, bell@1/4, pad@2/4  (actually pad@1/2 for the outer step)
        // outer: 2 steps → 0..1/2 and 1/2..1
        // inner [pad bell]: within 0..1/2 → pad@0, bell@1/4
        XCTAssertEqual(haps.count, 3)
        XCTAssertEqual(haps[0].value, "pad")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 4))
        XCTAssertEqual(haps[1].value, "bell")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 4))
        XCTAssertEqual(haps[2].value, "pad")
        XCTAssertEqual(haps[2].part.begin, Rational(2, 4))
    }

    // MARK: - Slowcat <...>

    func testSlowcat() {
        let pat = parseMini("<c4 e4 g4 b4>")
        // cycle 0 → c4, cycle 1 → e4, cycle 2 → g4, cycle 3 → b4
        let expected = ["c4", "e4", "g4", "b4"]
        for (i, exp) in expected.enumerated() {
            let haps = pat.queryArc(Rational(i), Rational(i + 1))
            XCTAssertEqual(haps.count, 1, "cycle \(i)")
            XCTAssertEqual(haps[0].value, exp, "cycle \(i)")
        }
    }

    func testSlowcatTwoCycles() {
        // <a b> — cycle 0 → a, cycle 1 → b, cycle 2 → a
        let pat = parseMini("<a b>")
        XCTAssertEqual(pat.queryArc(Rational(0), Rational(1)).first?.value, "a")
        XCTAssertEqual(pat.queryArc(Rational(1), Rational(2)).first?.value, "b")
        XCTAssertEqual(pat.queryArc(Rational(2), Rational(3)).first?.value, "a")
    }

    // MARK: - MIDI note

    func testMidiNoteC4() {
        XCTAssertEqual(midiNote(for: "c4"), 60)
    }

    func testMidiNoteE4() {
        XCTAssertEqual(midiNote(for: "e4"), 64)
    }

    func testMidiNoteG4() {
        XCTAssertEqual(midiNote(for: "g4"), 67)
    }

    func testMidiNoteB4() {
        XCTAssertEqual(midiNote(for: "b4"), 71)
    }

    func testMidiNoteSharp() {
        XCTAssertEqual(midiNote(for: "c#4"), 61)
    }

    func testMidiNoteFlat() {
        XCTAssertEqual(midiNote(for: "bb4"), 70)
    }

    // MARK: - Code parser

    func testCodeParserSimpleS() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["s"], .string("pad"))
    }

    func testCodeParserSlowGainRoom() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").slow(4).gain(0.5).room(0.6)"#)
        // slow(4) → 1 event per 4 cycles; query [0,1) still returns it
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1)
        let val = haps[0].value
        XCTAssertEqual(val["s"],    .string("pad"))
        XCTAssertEqual(val["gain"], .double(0.5))
        XCTAssertEqual(val["room"], .double(0.6))
    }

    func testCodeParserNotePattern() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"note("<c4 e4 g4 b4>").s("bell").slow(2)"#)
        // slow(2) → 2 cycles per note alternative
        // cycle 0: c4; cycle 2: e4; etc.
        let h0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertFalse(h0.isEmpty)
        XCTAssertEqual(h0[0].value["note"], .double(60)) // c4
        XCTAssertEqual(h0[0].value["s"],    .string("bell"))

        let h1 = pat.queryArc(Rational(2), Rational(3))
        XCTAssertFalse(h1.isEmpty)
        XCTAssertEqual(h1[0].value["note"], .double(64)) // e4
    }

    func testCodeParserStack() throws {
        let parser = CodeParser()
        let code = """
        stack(
          s("pad").slow(4).gain(0.5).room(0.6),
          note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7)
        )
        """
        let pat = try parser.parse(code)
        let haps = pat.queryArc(Rational(0), Rational(1))
        // pad (slow 4): 1 event; bell: 1 event → 2 total
        XCTAssertEqual(haps.count, 2)

        let pad  = haps.first { $0.value["s"] == .string("pad")  }
        let bell = haps.first { $0.value["s"] == .string("bell") }
        XCTAssertNotNil(pad)
        XCTAssertNotNil(bell)
        XCTAssertEqual(pad?.value["gain"],  .double(0.5))
        XCTAssertEqual(pad?.value["room"],  .double(0.6))
        XCTAssertEqual(bell?.value["gain"], .double(0.7))
        XCTAssertEqual(bell?.value["room"], .double(0.4))
        XCTAssertEqual(bell?.value["cutoff"], .double(1500))
        XCTAssertEqual(bell?.value["note"], .double(60)) // c4 in cycle 0
    }

    func testCodeParserLineComments() throws {
        let parser = CodeParser()
        let code = """
        // this is a comment
        s("pad") // inline comment
        """
        let pat = try parser.parse(code)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["s"], .string("pad"))
    }

    // MARK: - ControlPattern gain as pattern

    func testGainAsPattern() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").gain("<0.3 0.8>")"#)
        // cycle 0 → gain=0.3, cycle 1 → gain=0.8
        let h0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertFalse(h0.isEmpty)
        XCTAssertEqual(h0[0].value["gain"], .double(0.3))

        let h1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertFalse(h1.isEmpty)
        XCTAssertEqual(h1[0].value["gain"], .double(0.8))
    }
}
