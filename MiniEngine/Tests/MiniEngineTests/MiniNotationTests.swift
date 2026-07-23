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

    // MARK: - Chord / comma (parallel stack) in mini-notation

    func testSimpleChordInBrackets() {
        // "[a3,c4,e4]" → 3 simultaneous haps spanning full cycle
        let pat = parseMini("[a3,c4,e4]")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3)
        let values = Set(haps.map { $0.value })
        XCTAssertEqual(values, ["a3", "c4", "e4"])
        // All start at 0 and span the full cycle
        for hap in haps {
            XCTAssertEqual(hap.part.begin, Rational(0, 1))
            XCTAssertEqual(hap.part.end,   Rational(1, 1))
        }
    }

    func testTopLevelChord() {
        // "c3,e3" — top-level comma → stack of 2 simultaneous notes
        let pat = parseMini("c3,e3")
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 2)
        let values = Set(haps.map { $0.value })
        XCTAssertEqual(values, ["c3", "e3"])
        for hap in haps {
            XCTAssertEqual(hap.part.begin, Rational(0, 1))
            XCTAssertEqual(hap.part.end,   Rational(1, 1))
        }
    }

    func testChordInSlowcat() {
        // "<[a3,c4,e4] [e3,g#3,b3]>" — alternating chord per cycle
        let pat = parseMini("<[a3,c4,e4] [e3,g#3,b3]>")
        // Cycle 0: a3, c4, e4
        let c0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(c0.count, 3)
        XCTAssertEqual(Set(c0.map { $0.value }), ["a3", "c4", "e4"])
        // Cycle 1: e3, g#3, b3
        let c1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertEqual(c1.count, 3)
        XCTAssertEqual(Set(c1.map { $0.value }), ["e3", "g#3", "b3"])
    }

    func testChordReplicate() {
        // "[a3,c4,e4]!2" — chord replicated as 2 equal steps → 6 haps
        let pat = parseMini("[a3,c4,e4]!2")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 6)
        // First 3 at [0, 1/2), last 3 at [1/2, 1)
        let firstHalf  = haps.filter { $0.part.begin == Rational(0, 2) }
        let secondHalf = haps.filter { $0.part.begin == Rational(1, 2) }
        XCTAssertEqual(firstHalf.count, 3)
        XCTAssertEqual(secondHalf.count, 3)
        XCTAssertEqual(Set(firstHalf.map  { $0.value }), ["a3", "c4", "e4"])
        XCTAssertEqual(Set(secondHalf.map { $0.value }), ["a3", "c4", "e4"])
    }

    func testChordReplicateOnce() {
        // "[a3]!1 b3" — !1 is a no-op (replicate once = keep one copy)
        let pat = parseMini("[a3]!1 b3")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2)
        XCTAssertEqual(haps[0].value, "a3")
        XCTAssertEqual(haps[0].part.begin, Rational(0, 2))
        XCTAssertEqual(haps[1].value, "b3")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 2))
    }

    func testParallelSubSequences() {
        // "[bd bd, hh hh hh]" — two sub-sequences of different step counts
        let pat = parseMini("[bd bd, hh hh hh]")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 5)
        // bd appears at [0,1/2) and [1/2,1)
        let bds = haps.filter { $0.value == "bd" }.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(bds.count, 2)
        XCTAssertEqual(bds[0].part.begin, Rational(0, 2))
        XCTAssertEqual(bds[0].part.end,   Rational(1, 2))
        XCTAssertEqual(bds[1].part.begin, Rational(1, 2))
        // hh appears at [0,1/3), [1/3,2/3), [2/3,1)
        let hhs = haps.filter { $0.value == "hh" }.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(hhs.count, 3)
        XCTAssertEqual(hhs[0].part.begin, Rational(0, 3))
        XCTAssertEqual(hhs[1].part.begin, Rational(1, 3))
        XCTAssertEqual(hhs[2].part.begin, Rational(2, 3))
    }

    func testChordWithWeightModifier() {
        // "[a3,c4,e4]@3 b3" — chord occupies 3/4 of cycle, b3 occupies 1/4
        let pat = parseMini("[a3,c4,e4]@3 b3")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        // 3 chord notes + 1 single note = 4 haps
        XCTAssertEqual(haps.count, 4)
        let chordHaps = haps.filter { $0.value != "b3" }
        XCTAssertEqual(chordHaps.count, 3)
        for h in chordHaps {
            XCTAssertEqual(h.part.begin, Rational(0, 1))
            XCTAssertEqual(h.part.end,   Rational(3, 4))
        }
        let b3Hap = haps.first { $0.value == "b3" }
        XCTAssertNotNil(b3Hap)
        XCTAssertEqual(b3Hap?.part.begin, Rational(3, 4))
        XCTAssertEqual(b3Hap?.part.end,   Rational(1, 1))
    }

    // MARK: - MIDI notes with sharps/flats (d#5, g#3)

    func testMidiNoteD_sharp5() {
        // d#5 = MIDI 75 — (5+1)*12 + 2 + 1 = 75
        XCTAssertEqual(midiNote(for: "d#5"), 75)
    }

    func testMidiNoteG_sharp3() {
        // g#3 = MIDI 56 — (3+1)*12 + 7 + 1 = 56
        XCTAssertEqual(midiNote(for: "g#3"), 56)
    }

    func testMidiNoteA3() {
        // a3 = MIDI 57 — (3+1)*12 + 9 = 57
        XCTAssertEqual(midiNote(for: "a3"), 57)
    }

    func testMidiNoteB3() {
        // b3 = MIDI 59 — (3+1)*12 + 11 = 59
        XCTAssertEqual(midiNote(for: "b3"), 59)
    }

    // MARK: - Chord via note() in CodeParser

    func testCodeParserNoteChordInBrackets() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"note("[a3,c4,e4]")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 3)
        let midiNotes = Set(haps.compactMap { $0.value["note"]?.doubleValue.map { Int($0) } })
        XCTAssertEqual(midiNotes, [57, 60, 64])   // a3=57, c4=60, e4=64
        // All simultaneous — same part span
        for hap in haps {
            XCTAssertEqual(hap.part.begin, Rational(0, 1))
            XCTAssertEqual(hap.part.end,   Rational(1, 1))
        }
    }

    func testCodeParserNoteChordSlowcat() throws {
        // note("<[a3,c4,e4] [a3,c4,e4] [e3,g#3,b3] [a3,c4,e4]>") — PAD layer (4-cycle slowcat)
        let parser = CodeParser()
        let pat = try parser.parse(#"note("<[a3,c4,e4] [a3,c4,e4] [e3,g#3,b3] [a3,c4,e4]>")"#)
        // Cycle 0: a3(57), c4(60), e4(64)
        let c0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(c0.count, 3)
        let c0Notes = Set(c0.compactMap { $0.value["note"]?.doubleValue.map { Int($0) } })
        XCTAssertEqual(c0Notes, [57, 60, 64])
        // Cycle 2: e3(52), g#3(56), b3(59)
        let c2 = pat.queryArc(Rational(2), Rational(3))
        XCTAssertEqual(c2.count, 3)
        let c2Notes = Set(c2.compactMap { $0.value["note"]?.doubleValue.map { Int($0) } })
        XCTAssertEqual(c2Notes, [52, 56, 59])
    }

    func testCodeParserNoteChordWithSoundAndParams() throws {
        // Full PAD layer from the user's pattern:
        // note("<[a3,c4,e4] [a3,c4,e4] [e3,g#3,b3] [a3,c4,e4]>").sound("sawtooth").attack(1.5).lpf(600)
        let parser = CodeParser()
        let code = #"note("<[a3,c4,e4] [a3,c4,e4] [e3,g#3,b3] [a3,c4,e4]>").sound("sawtooth").attack(1.5).decay(1).sustain(0.5).release(2).lpf(600).gain(0.2).room(0.7)"#
        let pat = try parser.parse(code)
        // Cycle 0: 3 chord events, each with note + s + ADSR + filter
        let c0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(c0.count, 3)
        for hap in c0 {
            XCTAssertEqual(hap.value["s"]?.stringValue, "sawtooth")
            XCTAssertEqual(hap.value["attack"]?.doubleValue ?? -1, 1.5, accuracy: 1e-9)
            XCTAssertEqual(hap.value["lpf"]?.doubleValue ?? -1, 600.0, accuracy: 1e-9)
            XCTAssertEqual(hap.value["gain"]?.doubleValue ?? -1, 0.2, accuracy: 1e-9)
        }
        let c0Notes = Set(c0.compactMap { $0.value["note"]?.doubleValue.map { Int($0) } })
        XCTAssertEqual(c0Notes, [57, 60, 64])
    }

    func testCodeParserNoteReplicateOnce() throws {
        // "~!1" must replicate the silence once (= 1 step, same as just "~")
        // Verify !1 does NOT mean "replicate twice" or zero
        let parser = CodeParser()
        let pat = try parser.parse(#"note("<~!2 a3>")"#)
        // slowcat with 3 alternatives: silence, silence, a3
        // cycle 0: silence, cycle 1: silence, cycle 2: a3
        let c0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(c0.count, 0, "cycle 0 should be silence (~!2 = 2 silences)")
        let c1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertEqual(c1.count, 0, "cycle 1 should be silence")
        let c2 = pat.queryArc(Rational(2), Rational(3))
        XCTAssertEqual(c2.count, 1)
        XCTAssertEqual(c2[0].value["note"]?.doubleValue.map { Int($0) }, 57)  // a3=57
    }

    // MARK: - Full user acceptance pattern parse

    func testUserFullPatternWithChordsParses() throws {
        // The full user pattern from the task — must parse without error
        let code = """
        setcpm(15)
        stack(
          note("<~!2 [e5 d#5 e5 d#5 e5 b4 d5 c5 a4 ~ ~ c4 e4 a4 b4 ~] [e4 ~ ~ g#4 b4 c5 ~ ~ e4 ~ e5 d#5 e5 d#5 e5 b4] [d5 c5 a4 ~ ~ c4 e4 a4 b4 ~ e4 ~ c5 b4 a4 ~]!1>").sound("triangle").attack(0.005).decay(0.25).sustain(0.35).release(0.4).lpf(2800).gain(0.42).pan(0.45).delay(0.3).delaytime(0.25).delayfeedback(0.35).room(0.35),
          note("<~!2 [a2 ~ a2 ~ a2 ~ a2 ~] [a2 ~ a2 ~ e2 ~ e2 ~] [a2 ~ a2 ~ e2 ~ a2 ~]>").sound("sawtooth").attack(0.001).decay(0.16).sustain(0.3).release(0.1).lpf("<400!4 700!4 1200!4 900!4>").resonance(8).gain(0.5),
          note("<[a3,c4,e4] [a3,c4,e4] [e3,g#3,b3] [a3,c4,e4]>").sound("sawtooth").attack(1.5).decay(1).sustain(0.5).release(2).lpf(600).gain(0.2).room(0.7),
          s("<bd*8!12 [bd ~ ~ ~ bd ~ bd ~] bd*8!3>").decay(0.38).gain(0.95),
          s("<~!4 [~ cp ~ cp]!8 ~ [~ cp ~ cp]!3>").gain(0.48).room(0.2),
          s("<~!2 [hh hh hh <hh oh>]*2>").decay(0.18).gain(0.28).pan(0.65),
          s("<~!8 [~ rim ~ ~ rim ~ ~ ~]!8>").decay(0.15).gain(0.24).pan(0.28)
        )
        """
        let parser = CodeParser()
        // Must not throw
        XCTAssertNoThrow(try parser.parse(code))
        let result = try parser.parseWithTempo(code)
        XCTAssertEqual(result.cps ?? 0, 0.25, accuracy: 1e-9, "setcpm(15) should give cps=0.25")

        // Verify the PAD chord layer produces 3 simultaneous events in cycle 0
        let padCode = #"note("<[a3,c4,e4] [a3,c4,e4] [e3,g#3,b3] [a3,c4,e4]>")"#
        let padPat = try parser.parse(padCode)
        let padC0 = padPat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(padC0.count, 3, "PAD chord: 3 simultaneous events in cycle 0")
        let padNotes0 = Set(padC0.compactMap { $0.value["note"]?.doubleValue.map { Int($0) } })
        XCTAssertEqual(padNotes0, [57, 60, 64], "PAD cycle 0: a3=57, c4=60, e4=64")

        // Cycle 2: e3,g#3,b3 chord
        let padC2 = padPat.queryArc(Rational(2), Rational(3))
        XCTAssertEqual(padC2.count, 3, "PAD chord: 3 simultaneous events in cycle 2")
        let padNotes2 = Set(padC2.compactMap { $0.value["note"]?.doubleValue.map { Int($0) } })
        XCTAssertEqual(padNotes2, [52, 56, 59], "PAD cycle 2: e3=52, g#3=56, b3=59")
    }
}
