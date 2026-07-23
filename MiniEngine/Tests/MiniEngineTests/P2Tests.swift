// ---------------------------------------------------------------------------
// P2Tests — Tests for P2 pattern functions in MiniEngine.
//
// Coverage (all functions from functionalityv1.1.md §P2):
//   1. arp("up"|"down"|"updown"|"downup")   — arpeggiate chords
//   2. superimpose(f)                        — stack(self, f(self))
//   3. stut(n, feedback, time)              — n echoes with decaying gain
//   4. echo(n, time, feedback)              — stut with different arg order
//   5. iter(n)                              — rotate pattern 1/n per cycle
//   6. chunk(n, f)                          — apply f to rotating 1/n portion
//   7. palindrome                           — alternate normal/reversed by cycle
//   8. hurry(n)                             — fast(n) + speed×n
//   9. swingBy(x, n) / swing(n)            — delay odd steps by x fraction
//  10. Mini ? degrade                       — random omission (? operator)
//  11. Mini {a b, c d e} polymeter         — parallel branches, own step count
//  12. range/segment                        — confirmed existing (Signal.swift)
//  13. slice(n, indexPat) / loopAt(n)      — sample begin/end manipulation
//  14. CodeParser acceptance               — all above parseable from code strings
//
// Oracle confirmation:
//   superimpose, iter, palindrome, hurry, chunk, polymeter are verified against
//   oracle/generate.mjs fixtures (OracleTests.swift).
//   Deterministic functions are tested for exact output.
//   Random/stochastic functions (degrade ?) tested for proportion + determinism.
//   swingBy is tested for onset ordering and proportion (documented approximation
//   vs Strudel's whole-span model — see COMPATIBILITY.md).
// ---------------------------------------------------------------------------

import XCTest
@testable import MiniEngine

final class P2Tests: XCTestCase {

    // MARK: - 1. arp

    /// arp("up"): chord notes sorted ascending, divided evenly in the span.
    /// Oracle semantics: notes sorted by MIDI value ascending, divided into N sub-slots.
    func testArpUp() {
        // note("[c4,e4,g4]") = 3 simultaneous notes: c4=60, e4=64, g4=67
        // arp("up") → c@[0,1/3), e@[1/3,2/3), g@[2/3,1)
        let chord = note("[c4,e4,g4]").s("sine")
        let arped = chord.arp("up")
        let haps = arped.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3, "arp('up') on 3-note chord = 3 sequential events")
        // notes ascending
        let noteVals = haps.compactMap { $0.value["note"]?.doubleValue }
        XCTAssertEqual(noteVals, [60, 64, 67], "arp('up') must produce notes in ascending order")
        // timing: evenly spaced at 1/3 intervals
        XCTAssertEqual(haps[0].part.begin, Rational(0),     "arp[0] begins at 0")
        XCTAssertEqual(haps[0].part.end,   Rational(1, 3),  "arp[0] ends at 1/3")
        XCTAssertEqual(haps[1].part.begin, Rational(1, 3),  "arp[1] begins at 1/3")
        XCTAssertEqual(haps[2].part.begin, Rational(2, 3),  "arp[2] begins at 2/3")
        XCTAssertEqual(haps[2].part.end,   Rational(1),     "arp[2] ends at 1")
    }

    func testArpDown() {
        let chord = note("[c4,e4,g4]").s("sine")
        let arped = chord.arp("down")
        let haps = arped.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3, "arp('down') on 3-note chord = 3 events")
        let noteVals = haps.compactMap { $0.value["note"]?.doubleValue }
        XCTAssertEqual(noteVals, [67, 64, 60], "arp('down') must produce notes in descending order")
    }

    func testArpUpdown() {
        // 3 notes: up then down not repeating first/last.
        // [c4, e4, g4] updown → c, e, g, e (4 events, not 5)
        let chord = note("[c4,e4,g4]").s("sine")
        let arped = chord.arp("updown")
        let haps = arped.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4, "arp('updown') on 3 notes: c,e,g,e = 4 events")
        let noteVals = haps.compactMap { $0.value["note"]?.doubleValue }
        XCTAssertEqual(noteVals, [60, 64, 67, 64], "arp('updown'): up then down not repeating endpoints")
    }

    func testArpDownup() {
        // 3 notes: down then up not repeating first/last.
        // [c4, e4, g4] downup → g, e, c, e (4 events)
        let chord = note("[c4,e4,g4]").s("sine")
        let arped = chord.arp("downup")
        let haps = arped.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4, "arp('downup') on 3 notes: g,e,c,e = 4 events")
        let noteVals = haps.compactMap { $0.value["note"]?.doubleValue }
        XCTAssertEqual(noteVals, [67, 64, 60, 64], "arp('downup'): down then up not repeating endpoints")
    }

    func testArpTwoNotes() {
        // 2-note chord: arp("up") → lo@[0,1/2), hi@[1/2,1)
        let chord = note("[c4,g4]").s("sine")
        let arped = chord.arp("up")
        let haps = arped.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2, "arp on 2-note chord = 2 events")
        XCTAssertEqual(haps[0].value["note"]?.doubleValue ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(haps[1].value["note"]?.doubleValue ?? 0, 67, accuracy: 0.01)
        XCTAssertEqual(haps[0].part.end, Rational(1, 2))
        XCTAssertEqual(haps[1].part.begin, Rational(1, 2))
    }

    func testArpSingleNotePassthrough() {
        // Single note "chord" - arp is identity
        let single = note("c4").s("sine")
        let arped = single.arp("up")
        let haps = arped.firstCycle()
        XCTAssertEqual(haps.count, 1, "arp on single note = 1 event (passthrough)")
    }

    // MARK: - 2. superimpose

    /// superimpose(f) = stack(self, f(self)).
    /// Oracle confirmed: s("bd sn").superimpose(x => x.fast(2)) = 6 events.
    func testSuperimpose() {
        let pat = s("bd sn")
        let result = pat.superimpose { $0.fast(2) }
        let haps = result.firstCycle()
        XCTAssertEqual(haps.count, 6, "superimpose(fast(2)) on 2-event pattern = 2 + 4 = 6 events")
        // The original 2 events should be present
        let bdHaps = haps.filter { $0.value["s"]?.stringValue == "bd" }
        let snHaps = haps.filter { $0.value["s"]?.stringValue == "sn" }
        XCTAssertEqual(bdHaps.count, 3, "bd appears 3 times: 1 original + 2 fast copies")
        XCTAssertEqual(snHaps.count, 3, "sn appears 3 times: 1 original + 2 fast copies")
    }

    func testSuperimposeIdentity() {
        // superimpose(x => x) = stack(self, self) = 2× every event
        let pat = s("bd")
        let result = pat.superimpose { $0 }
        let haps = result.firstCycle()
        XCTAssertEqual(haps.count, 2, "superimpose(identity) doubles events")
    }

    func testSuperimposeLargerTransform() {
        // superimpose(x => x.slow(2)) — transform stretches to 2 cycles.
        // Querying cycle 0: original has bd and sn; slow(2) has only bd in [0,1).
        // Total in cycle 0: bd, sn, bd (from slow) = 3 events.
        let pat = s("bd sn")
        let result = pat.superimpose { $0.slow(2) }
        let haps = result.firstCycle()
        XCTAssertEqual(haps.count, 3, "superimpose(slow(2)) in cycle 0: bd+sn+bd(slow) = 3")
    }

    // MARK: - 3. stut

    /// stut(n, feedback, time): n copies shifted by time each, gain × feedback^k.
    ///
    /// Semantics: Strudel's rotR/late is a time shift of a periodic pattern — copies
    /// wrap around cycle boundaries, so querying [0,1) picks up events from both the
    /// shifted-forward position AND the previous cycle's wrap-around. This is correct
    /// behaviour (confirmed to match Strudel's own stut output).
    ///
    /// For stut(3, 0.5, 0.25) on s("bd") querying [0,1):
    ///   - Copy 0 (gain=1.0): whole=[0,1), part=[0,1)
    ///   - Copy 1 (gain=0.5, late 0.25): whole=[-0.75,0.25) part=[0,0.25)
    ///                                   AND whole=[0.25,1.25) part=[0.25,1)
    ///   - Copy 2 (gain=0.25, late 0.5): whole=[-0.5,0.5) part=[0,0.5)
    ///                                   AND whole=[0.5,1.5) part=[0.5,1)
    ///   Total: 5 events in [0,1).
    ///
    /// The key gain pattern (from whole.begin order): 1.0 at origin, 0.5 at shift1, 0.25 at shift2.
    func testStutThreeEchoes() {
        let pat = s("bd")
        let result = pat.stut(3, 0.5, 0.25)
        let haps = result.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        // Strudel semantics: 5 events in [0,1) due to periodic rotation wrapping
        XCTAssertEqual(haps.count, 5, "stut(3, 0.5, 0.25) on bd: 5 events in [0,1) (periodic rotation wraps)")

        // All events should be bd
        for hap in haps {
            XCTAssertEqual(hap.value["s"]?.stringValue, "bd", "all stut events are bd")
        }
        // All events should have gain field
        let gains = haps.compactMap { $0.value["gain"]?.doubleValue }
        XCTAssertEqual(gains.count, 5, "all stut events have gain field")
        // Gains present: 1.0, 0.5, 0.5, 0.25, 0.25 (copies 0, 1-left, 1-right, 2-left, 2-right)
        let gainsSorted = gains.sorted()
        XCTAssertEqual(gainsSorted[0], 0.25, accuracy: 1e-9, "min gain = 0.25 (copy 2)")
        XCTAssertEqual(gainsSorted[4], 1.0,  accuracy: 1e-9, "max gain = 1.0 (copy 0)")
        // The event at t=0.25 (strict onset) has gain 0.5
        let atQuarter = haps.filter { $0.part.begin == Rational(1, 4) }
        XCTAssertFalse(atQuarter.isEmpty, "stut: event with onset at t=0.25 exists (copy 1 forward)")
        XCTAssertEqual(atQuarter[0].value["gain"]?.doubleValue ?? -1, 0.5, accuracy: 1e-9,
                       "onset at t=0.25 has gain=0.5 (copy 1 feedback)")
        // The event at t=0.5 has gain 0.25
        let atHalf = haps.filter { $0.part.begin == Rational(1, 2) }
        XCTAssertFalse(atHalf.isEmpty, "stut: event with onset at t=0.5 exists (copy 2 forward)")
        XCTAssertEqual(atHalf[0].value["gain"]?.doubleValue ?? -1, 0.25, accuracy: 1e-9,
                       "onset at t=0.5 has gain=0.25 (copy 2 feedback)")
    }

    func testStutOneRepetition() {
        // stut(1, 0.5, 0.25) = just the original (no echoes)
        let pat = s("bd")
        let result = pat.stut(1, 0.5, 0.25)
        let haps = result.firstCycle()
        XCTAssertEqual(haps.count, 1, "stut(1,...) = original only")
        XCTAssertEqual(haps[0].value["gain"]?.doubleValue ?? -1, 1.0, accuracy: 1e-9,
                       "stut copy 0 has gain=1.0")
    }

    func testStutZeroRepetitionsReturnsOriginal() {
        // stut(0, ...) = silence/empty (implementation-defined: guard n>0 returns self)
        let pat = s("bd")
        let result = pat.stut(0, 0.5, 0.25)
        // We return self when n<=0 per implementation
        let haps = result.firstCycle()
        XCTAssertEqual(haps.count, 1, "stut(0,...) returns original pattern")
    }

    func testStutExistingGainMultiplied() {
        // s("bd").gain(0.8).stut(2, 0.5, 0.25)
        // Copy 0: gain = 0.8 × 1.0 = 0.8
        // Copy 1 (late 0.25): gain = 0.8 × 0.5 = 0.4 — periodic wrap gives 3 events in [0,1)
        let pat = s("bd").gain(0.8)
        let result = pat.stut(2, 0.5, 0.25)
        let haps = result.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        // 3 events: copy 0 and 2 events from copy 1 (periodic wrap)
        XCTAssertEqual(haps.count, 3, "stut(2,...): 3 events (copy 0 + 2 from copy 1 wrap)")
        // The event at t=0.25 (strict onset of echo) has gain 0.4
        let atQuarter = haps.filter { $0.part.begin == Rational(1, 4) }
        XCTAssertFalse(atQuarter.isEmpty, "stut: event at t=0.25 present")
        XCTAssertEqual(atQuarter[0].value["gain"]?.doubleValue ?? -1, 0.4, accuracy: 1e-9,
                       "stut copy 1 echo onset: 0.8 × 0.5 = 0.4")
        // The original event at t=0 (whole=[0,1)) has gain 0.8
        let originalEvent = haps.first { $0.whole == TimeSpan(Rational(0), Rational(1)) }
        XCTAssertNotNil(originalEvent, "stut original event (whole=[0,1)) exists")
        XCTAssertEqual(originalEvent?.value["gain"]?.doubleValue ?? -1, 0.8, accuracy: 1e-9,
                       "stut copy 0: 0.8 × 1.0 = 0.8")
    }

    // MARK: - 4. echo

    /// echo(n, time, feedback) = stut(n, feedback, time) — just different arg order.
    func testEchoSameAsStutDifferentArgOrder() {
        let pat = s("bd")
        // stut(3, 0.5, 0.25) and echo(3, 0.25, 0.5) should be identical
        let stutResult = pat.stut(3, 0.5, 0.25)
        let echoResult = pat.echo(3, 0.25, 0.5)
        let stutHaps = stutResult.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        let echoHaps = echoResult.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(stutHaps.count, echoHaps.count, "echo and stut produce same number of haps")
        for (s, e) in zip(stutHaps, echoHaps) {
            XCTAssertEqual(s.part.begin, e.part.begin, "Same timing")
            XCTAssertEqual(s.value["gain"]?.doubleValue ?? -1,
                           e.value["gain"]?.doubleValue ?? -2,
                           accuracy: 1e-9, "Same gain")
        }
    }

    // MARK: - 5. iter

    /// iter(n) rotates pattern by 1/n per cycle.
    /// Oracle confirmed: s("bd sn hh oh").iter(4) over 4 cycles.
    func testIterFourCycles() {
        // "bd sn hh oh".iter(4):
        //   cycle 0: bd sn hh oh (starts at 0/4=0)
        //   cycle 1: sn hh oh bd (starts at 1/4)
        //   cycle 2: hh oh bd sn (starts at 2/4)
        //   cycle 3: oh bd sn hh (starts at 3/4)
        let pat = s("bd sn hh oh").iter(4)

        // Cycle 0: bd first
        let c0 = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c0.count, 4)
        XCTAssertEqual(c0[0].value["s"]?.stringValue, "bd", "cycle 0 starts with bd")
        XCTAssertEqual(c0[3].value["s"]?.stringValue, "oh", "cycle 0 ends with oh")

        // Cycle 1: sn first
        let c1 = pat.queryArc(Rational(1), Rational(2)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c1.count, 4)
        XCTAssertEqual(c1[0].value["s"]?.stringValue, "sn", "cycle 1 starts with sn")

        // Cycle 2: hh first
        let c2 = pat.queryArc(Rational(2), Rational(3)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c2.count, 4)
        XCTAssertEqual(c2[0].value["s"]?.stringValue, "hh", "cycle 2 starts with hh")

        // Cycle 3: oh first
        let c3 = pat.queryArc(Rational(3), Rational(4)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c3.count, 4)
        XCTAssertEqual(c3[0].value["s"]?.stringValue, "oh", "cycle 3 starts with oh")
    }

    func testIterWrapsAtN() {
        // iter(2) on "bd sn": cycle 0 = bd sn, cycle 1 = sn bd, cycle 2 = bd sn (wraps)
        let pat = s("bd sn").iter(2)
        let c0 = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        let c2 = pat.queryArc(Rational(2), Rational(3)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c0[0].value["s"]?.stringValue, c2[0].value["s"]?.stringValue,
                       "iter wraps at n: cycle 2 == cycle 0")
    }

    func testIterOneIsIdentity() {
        // iter(1) rotates by 1/1 per cycle = full cycle each time = same as identity
        let pat = s("bd sn")
        let result = pat.iter(1)
        let orig = pat.queryArc(Rational(0), Rational(2)).sorted { $0.part.begin < $1.part.begin }
        let iterd = result.queryArc(Rational(0), Rational(2)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(orig.count, iterd.count)
    }

    // MARK: - 6. chunk

    /// chunk(4, fast(2)) on "bd sn hh oh":
    /// cycle k: portion [k/4, (k+1)/4) is played at fast(2) of the whole pattern.
    /// Oracle confirmed (Strudel): 5 events per cycle.
    ///
    /// Cycle 0 semantics:
    ///   chunk [0, 1/4): transform = fast(2) of full pattern → bd@[0,1/8), sn@[1/8,1/4)
    ///   rest normal: sn@[1/4,1/2), hh@[1/2,3/4), oh@[3/4,1)
    ///   Total events: bd, sn, sn, hh, oh = 5 events
    func testChunkFour() {
        let pat = s("bd sn hh oh").chunk(4) { $0.fast(2) }
        let c0 = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c0.count, 5, "chunk(4, fast(2)): cycle 0 = 5 events total")
        // First event: bd (from fast(2) in chunk slot [0,1/4))
        XCTAssertEqual(c0[0].value["s"]?.stringValue, "bd",
                       "cycle 0 event 0: bd from fast(2) chunk")
        // Second event: sn (from fast(2) in chunk slot [0,1/4))
        XCTAssertEqual(c0[1].value["s"]?.stringValue, "sn",
                       "cycle 0 event 1: sn from fast(2) chunk")
        // Normal events outside chunk
        XCTAssertEqual(c0[2].value["s"]?.stringValue, "sn",
                       "cycle 0 event 2: sn (normal, [1/4,1/2))")
        XCTAssertEqual(c0[3].value["s"]?.stringValue, "hh",
                       "cycle 0 event 3: hh (normal)")
        XCTAssertEqual(c0[4].value["s"]?.stringValue, "oh",
                       "cycle 0 event 4: oh (normal)")
    }

    func testChunkRotatesEachCycle() {
        // chunk(4, fast(2)) on "a b c d":
        // cycle 0: chunk [0,1/4) — fast(2) maps: a@[0,1/8), b@[1/8,1/4); normal: b,c,d
        // cycle 1: chunk [1/4,1/2) — fast(2) maps: c@[1/4,3/8), d@[3/8,1/2); normal: a,c,d
        let pat = s("a b c d").chunk(4) { $0.fast(2) }
        let c0 = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c0.count, 5, "cycle 0: 5 events")
        XCTAssertEqual(c0[0].value["s"]?.stringValue, "a", "cycle 0 event 0: 'a' from fast(2)")
        // cycle 1: chunk portion is b's slot [1/4, 1/2) — fast(2) gives c@[1/4,3/8), d@[3/8,1/2)
        let c1 = pat.queryArc(Rational(1), Rational(2)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c1.count, 5, "cycle 1: 5 events")
    }

    // MARK: - 7. palindrome

    /// palindrome: even cycles normal, odd cycles reversed.
    /// Oracle confirmed: s("bd sn hh oh").palindrome over 2 cycles.
    func testPalindromeEvenNormalOddReversed() {
        let pat = s("bd sn hh oh").palindrome

        // Cycle 0 (even): normal order bd, sn, hh, oh
        let c0 = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c0.count, 4)
        XCTAssertEqual(c0[0].value["s"]?.stringValue, "bd", "cycle 0: starts with bd (normal)")
        XCTAssertEqual(c0[3].value["s"]?.stringValue, "oh", "cycle 0: ends with oh (normal)")

        // Cycle 1 (odd): reversed oh, hh, sn, bd
        let c1 = pat.queryArc(Rational(1), Rational(2)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c1.count, 4)
        XCTAssertEqual(c1[0].value["s"]?.stringValue, "oh", "cycle 1: starts with oh (reversed)")
        XCTAssertEqual(c1[3].value["s"]?.stringValue, "bd", "cycle 1: ends with bd (reversed)")
    }

    func testPalindromeCycle2SameAsCycle0() {
        let pat = s("bd sn hh oh").palindrome
        let c0 = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        let c2 = pat.queryArc(Rational(2), Rational(3)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c0.count, c2.count)
        for (a, b) in zip(c0, c2) {
            XCTAssertEqual(a.value["s"]?.stringValue, b.value["s"]?.stringValue,
                           "palindrome cycle 2 == cycle 0 (even)")
        }
    }

    func testPalindromeEventCount() {
        // palindrome doesn't change the event count per cycle
        let pat = s("bd sn hh oh").palindrome
        let c0 = pat.queryArc(Rational(0), Rational(1))
        let c1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertEqual(c0.count, c1.count, "palindrome preserves event count per cycle")
    }

    // MARK: - 8. hurry

    /// hurry(n): fast(n) AND speed field multiplied by n.
    /// Oracle confirmed: s("bd sn").hurry(2) = 4 events, each speed=2.
    func testHurryDoubles() {
        let pat = s("bd sn").hurry(2)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4, "hurry(2) doubles event count (fast(2) effect)")
        for hap in haps {
            XCTAssertEqual(hap.value["speed"]?.doubleValue ?? -1, 2.0, accuracy: 1e-9,
                           "hurry(2) sets speed=2 on each event")
        }
    }

    func testHurryExistingSpeedMultiplied() {
        // s("pad").speed(2).hurry(2) → speed = 2 × 2 = 4
        let pat = s("pad").speed(2).hurry(2)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value["speed"]?.doubleValue ?? -1, 4.0, accuracy: 1e-9,
                       "hurry multiplies existing speed: 2 × 2 = 4")
    }

    func testHurryKeepsSampleField() {
        let pat = s("pad").hurry(3)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value["s"]?.stringValue, "pad", "hurry preserves s field")
        XCTAssertEqual(haps[0].value["speed"]?.doubleValue ?? -1, 3.0, accuracy: 1e-9,
                       "hurry(3) sets speed=3")
    }

    // MARK: - 9. swingBy / swing

    /// swingBy(amount, period): delay odd steps.
    /// Documented approximation: our impl shifts part.begin directly, while Strudel
    /// uses a whole-span model. Onset ordering and timing proportions are preserved.
    ///
    /// For s("bd sn").swingBy(1/3, 2): bd is step 0 (even, unchanged),
    /// sn is step 1 (odd, delayed by 1/3 × 1/2 = 1/6).
    ///
    /// Note: swingBy uses Rational(approximating:) which introduces slight rounding
    /// (1/3 ≈ 333333/1000000). Tolerance of 1e-4 accommodates this approximation.
    func testSwingByOddStepDelayed() {
        let pat = s("bd sn").swingBy(1.0 / 3.0, 2)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2, "swingBy on 2-event pattern = 2 events")
        // bd (even step 0): unchanged at t=0
        let bd = haps.first { $0.value["s"]?.stringValue == "bd" }
        let sn = haps.first { $0.value["s"]?.stringValue == "sn" }
        XCTAssertNotNil(bd); XCTAssertNotNil(sn)
        XCTAssertEqual(bd!.part.begin.toDouble, 0.0, accuracy: 1e-9,
                       "bd (even step) unchanged at t=0")
        // sn (odd step 1): original t=0.5, shift = 1/3 × (1/2) = 1/6
        // Expected onset: 0.5 + 1/6 ≈ 2/3 ≈ 0.6667
        // Tolerance 1e-4 for Rational approximation of 1/3
        XCTAssertEqual(sn!.part.begin.toDouble, 2.0 / 3.0, accuracy: 1e-4,
                       "sn (odd step) delayed by 1/6 to t≈2/3 (within 1e-4 of Rational approx)")
    }

    func testSwingByEvenStepUnchanged() {
        // s("hh hh hh hh").swingBy(1/3, 2): 4 events at t=0, 0.25, 0.5, 0.75.
        //
        // stepIndex = floor(pos × period) = floor(pos × 2):
        //   pos=0.00 → stepIndex=0 (even) → unchanged at 0
        //   pos=0.25 → stepIndex=0 (even) → unchanged at 0.25
        //   pos=0.50 → stepIndex=1 (odd)  → shifted by 1/6 to ≈0.667
        //   pos=0.75 → stepIndex=1 (odd)  → shifted by 1/6 to ≈0.917
        //
        // swingBy(1/3, 2) divides the cycle into 2 half-cycle groups of beats.
        // The SECOND event in each half-cycle group is delayed (stepIndex is odd).
        let pat = s("hh hh hh hh").swingBy(1.0 / 3.0, 2)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4, "4-event pattern preserves 4 events after swingBy")
        // Steps 0 and 1 (stepIndex 0): unchanged at t=0 and t=0.25
        XCTAssertEqual(haps[0].part.begin.toDouble, 0.0, accuracy: 1e-9,
                       "step 0 (even): t=0 unchanged")
        XCTAssertEqual(haps[1].part.begin.toDouble, 0.25, accuracy: 1e-9,
                       "step 1 (stepIndex=0, even): t=0.25 unchanged")
        // Steps 2 and 3 (stepIndex 1, odd): shifted by 1/6
        //   0.5 + 1/3/2 = 0.5 + 1/6 ≈ 0.6667
        //   0.75 + 1/6 ≈ 0.9167
        XCTAssertEqual(haps[2].part.begin.toDouble, 0.5 + 1.0/6.0, accuracy: 1e-4,
                       "step 2 (stepIndex=1, odd): delayed from 0.5 to ≈0.667")
        XCTAssertEqual(haps[3].part.begin.toDouble, 0.75 + 1.0/6.0, accuracy: 1e-4,
                       "step 3 (stepIndex=1, odd): delayed from 0.75 to ≈0.917")
    }

    func testSwingIsSwingByOneThird() {
        // swing(n) = swingBy(1/3, n)
        let patSwing   = s("bd sn hh oh").swing(2)
        let patSwingBy = s("bd sn hh oh").swingBy(1.0 / 3.0, 2)
        let swingHaps   = patSwing.firstCycle().sorted { $0.part.begin < $1.part.begin }
        let swingByHaps = patSwingBy.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(swingHaps.count, swingByHaps.count)
        for (a, b) in zip(swingHaps, swingByHaps) {
            XCTAssertEqual(a.part.begin.toDouble, b.part.begin.toDouble, accuracy: 1e-12,
                           "swing(n) == swingBy(1/3, n): same timing")
        }
    }

    func testSwingByZeroAmountIsIdentity() {
        let pat = s("bd sn hh oh").swingBy(0, 2)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        let orig = s("bd sn hh oh").firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, orig.count)
        for (a, b) in zip(haps, orig) {
            XCTAssertEqual(a.part.begin, b.part.begin, "swingBy(0,...) is identity")
        }
    }

    // MARK: - 10. Mini ? — degrade (random omission)

    /// degrade (? operator in mini-notation): probabilistic omission.
    /// Determinism: same seed, same cycle → same result.
    /// Proportion: over many cycles, ~p fraction of events are omitted.
    ///
    /// DOCUMENTED: Our PRNG (splitmix64 seeded by cycle+index) differs from
    /// Strudel's murmur-hash time-keyed rand. No bit-exact match; proportions match.
    func testDegradeIsDeterministic() {
        // Parse "bd?" — should produce same result on repeated queries for same cycle.
        let pat = parseMini("bd?")
        let q1 = pat.query(TimeSpan(Rational(0), Rational(1)))
        let q2 = pat.query(TimeSpan(Rational(0), Rational(1)))
        // Must be identical (same result for same cycle)
        XCTAssertEqual(q1.count, q2.count, "degrade is deterministic: same cycle = same result")
    }

    func testDegradeProportion() {
        // "bd?" with default prob=0.5: over 100 cycles, ~50% should be present.
        // Use a tolerance of ±15% (probabilistic test).
        let pat = parseMini("bd?")
        var present = 0
        let nCycles = 200
        for c in 0..<nCycles {
            let haps = pat.query(TimeSpan(Rational(c), Rational(c + 1)))
            present += haps.count
        }
        let fraction = Double(present) / Double(nCycles)
        XCTAssertGreaterThan(fraction, 0.35, "degrade(0.5): expected ~50% present, got \(fraction)")
        XCTAssertLessThan(fraction, 0.65, "degrade(0.5): expected ~50% present, got \(fraction)")
    }

    func testDegradeCustomProbability() {
        // "bd?0.2": 80% present (0.2 = omission probability)
        let pat = parseMini("bd?0.2")
        var present = 0
        let nCycles = 200
        for c in 0..<nCycles {
            let haps = pat.query(TimeSpan(Rational(c), Rational(c + 1)))
            present += haps.count
        }
        let fraction = Double(present) / Double(nCycles)
        XCTAssertGreaterThan(fraction, 0.70, "degrade(0.2): expected ~80% present, got \(fraction)")
        XCTAssertLessThan(fraction, 0.90, "degrade(0.2): expected ~80% present, got \(fraction)")
    }

    func testDegradeZeroOmissionProb() {
        // "bd?0": prob=0 → always present (no degradation)
        let pat = parseMini("bd?0")
        for c in 0..<10 {
            let haps = pat.query(TimeSpan(Rational(c), Rational(c + 1)))
            XCTAssertEqual(haps.count, 1, "degrade(prob=0) always present in cycle \(c)")
        }
    }

    func testDegradeOneOmissionProb() {
        // "bd?1": prob=1 → always absent (silence)
        let pat = parseMini("bd?1")
        for c in 0..<10 {
            let haps = pat.query(TimeSpan(Rational(c), Rational(c + 1)))
            XCTAssertEqual(haps.count, 0, "degrade(prob=1) always absent in cycle \(c)")
        }
    }

    func testDegradeControlPattern() {
        // s("bd? sn hh?0.3") — degraded elements are parsed from mini-notation
        let pat = s("bd? sn hh?0.3")
        // Over many cycles, count presence of each position
        var bdCount = 0, snCount = 0, hhCount = 0
        let nCycles = 200
        for c in 0..<nCycles {
            let haps = pat.queryArc(Rational(c), Rational(c + 1))
                .filter { $0.value["s"] != nil }
            bdCount += haps.filter { $0.value["s"]?.stringValue == "bd" }.count
            snCount += haps.filter { $0.value["s"]?.stringValue == "sn" }.count
            hhCount += haps.filter { $0.value["s"]?.stringValue == "hh" }.count
        }
        // sn should always be present (no ?)
        XCTAssertEqual(snCount, nCycles, "sn has no ? so always present")
        // bd: ~50% present (omit prob=0.5)
        let bdFrac = Double(bdCount) / Double(nCycles)
        XCTAssertGreaterThan(bdFrac, 0.35); XCTAssertLessThan(bdFrac, 0.65)
        // hh: ~70% present (omit prob=0.3)
        let hhFrac = Double(hhCount) / Double(nCycles)
        XCTAssertGreaterThan(hhFrac, 0.55); XCTAssertLessThan(hhFrac, 0.85)
    }

    // MARK: - 11. Polymeter {a b, c d e}

    /// Polymeter: each branch maintains its own step count.
    /// {bd sn, hh hh hh}: bd/sn = 2 steps; hh/hh/hh = 3 steps.
    /// In a single cycle: bd@[0,1/2), sn@[1/2,1), hh@[0,1/3), hh@[1/3,2/3), hh@[2/3,1).
    /// Oracle confirmed: stack([bd sn], [hh hh hh]) = same single-cycle structure.
    func testPolymeterSingleCycle() {
        let pat = parseMini("{bd sn, hh hh hh}")
        let haps = pat.query(TimeSpan(Rational(0), Rational(1)))
            .sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 5, "{bd sn, hh hh hh} = 5 events (2 + 3) in cycle 0")

        let bdHaps = haps.filter { $0.value == "bd" }
        let snHaps = haps.filter { $0.value == "sn" }
        let hhHaps = haps.filter { $0.value == "hh" }

        XCTAssertEqual(bdHaps.count, 1); XCTAssertEqual(snHaps.count, 1)
        XCTAssertEqual(hhHaps.count, 3)

        // bd spans [0, 1/2)
        XCTAssertEqual(bdHaps[0].part.begin, Rational(0))
        XCTAssertEqual(bdHaps[0].part.end,   Rational(1, 2))
        // hh spans: [0,1/3), [1/3,2/3), [2/3,1)
        XCTAssertEqual(hhHaps[0].part.begin, Rational(0))
        XCTAssertEqual(hhHaps[1].part.begin, Rational(1, 3))
        XCTAssertEqual(hhHaps[2].part.begin, Rational(2, 3))
    }

    func testPolymeterControlPattern() {
        // Verify via s() function (wraps in ControlPattern)
        let pat = s("{bd sn, hh hh hh}")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 5, "s(\"{bd sn, hh hh hh}\") = 5 control events")
    }

    func testPolymeterThreeBranches() {
        // {a b, c d e, f} — 3 branches: 2+3+1=6 events per cycle
        let pat = parseMini("{a b, c d e, f}")
        let haps = pat.query(TimeSpan(Rational(0), Rational(1)))
        XCTAssertEqual(haps.count, 6, "{a b, c d e, f} = 2+3+1 = 6 events")
    }

    func testPolymeterSingleBranchIsPlain() {
        // {a b} with no comma = single branch = just "a b"
        let pat = parseMini("{a b}")
        let haps = pat.query(TimeSpan(Rational(0), Rational(1)))
        XCTAssertEqual(haps.count, 2, "{a b} = plain 2-step pattern")
    }

    // MARK: - 12. range / segment — confirmed existing

    /// range and segment are already tested in SignalTests.swift.
    /// This test confirms they are accessible and produce expected values on ControlPattern.
    func testRangeSegmentExistOnPattern() {
        // sine.range(0.1, 0.9).segment(4) — should produce 4 events with values in [0.1, 0.9]
        let pat = sine.range(0.1, 0.9).segment(4)
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 4, "segment(4) produces 4 events")
        for hap in haps {
            XCTAssertGreaterThanOrEqual(hap.value, 0.1, "range lower bound")
            XCTAssertLessThanOrEqual(hap.value, 0.9 + 1e-9, "range upper bound")
        }
    }

    // MARK: - 13. slice / loopAt

    /// slice(n, indexPat): sets begin/end fields to select a slice of a sample.
    /// Oracle semantics: slice(4, "0 1 2 3") → 4 events, each with begin/end covering 1/4 of sample.
    func testSliceFourChunks() {
        let pat = s("pad").slice(4, "0 1 2 3")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4, "slice(4, '0 1 2 3') = 4 events")
        let expectedBegins = [0.0, 0.25, 0.5, 0.75]
        let expectedEnds   = [0.25, 0.5, 0.75, 1.0]
        for (i, hap) in haps.enumerated() {
            XCTAssertEqual(hap.value["begin"]?.doubleValue ?? -1, expectedBegins[i], accuracy: 1e-9,
                           "slice chunk \(i): begin=\(expectedBegins[i])")
            XCTAssertEqual(hap.value["end"]?.doubleValue ?? -1, expectedEnds[i], accuracy: 1e-9,
                           "slice chunk \(i): end=\(expectedEnds[i])")
        }
    }

    func testSliceIndexWrap() {
        // slice(4, "0 2 4 6") — indices wrap: 4 mod 4=0, 6 mod 4=2
        let pat = s("pad").slice(4, "0 2 4 6")
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 4)
        // Index 4 mod 4 = 0 → begin=0, end=0.25
        XCTAssertEqual(haps[2].value["begin"]?.doubleValue ?? -1, 0.0, accuracy: 1e-9,
                       "index 4 wraps to 0: begin=0")
    }

    func testSliceOneChunk() {
        // slice(1, "0") → always plays the full sample (begin=0, end=1)
        let pat = s("pad").slice(1, "0")
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value["begin"]?.doubleValue ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(haps[0].value["end"]?.doubleValue ?? -1,   1.0, accuracy: 1e-9)
    }

    /// loopAt(n): sets speed = 1/n and begin=0, end=1 for full-sample playback.
    ///
    /// DOCUMENTED APPROXIMATION: Without actual sample duration, we set speed=1/n.
    /// For breakbeats recorded at one cycle length, loopAt(1) = normal speed,
    /// loopAt(2) = half speed (stretched to 2 cycles).
    func testLoopAtSetsSpeedAndRange() {
        let pat = s("pad").loopAt(2)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        let hap = haps[0]
        XCTAssertEqual(hap.value["speed"]?.doubleValue ?? -1, 0.5, accuracy: 1e-9,
                       "loopAt(2): speed = 1/2 = 0.5")
        XCTAssertEqual(hap.value["begin"]?.doubleValue ?? -1, 0.0, accuracy: 1e-9,
                       "loopAt: begin = 0 (full sample)")
        XCTAssertEqual(hap.value["end"]?.doubleValue ?? -1, 1.0, accuracy: 1e-9,
                       "loopAt: end = 1 (full sample)")
    }

    func testLoopAtOneIsNormalSpeed() {
        let pat = s("pad").loopAt(1)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value["speed"]?.doubleValue ?? -1, 1.0, accuracy: 1e-9,
                       "loopAt(1) = normal speed (speed=1.0)")
    }

    func testLoopAtExistingSpeedPreserved() {
        // loopAt merges speed into the control map; existing speed is overwritten
        let pat = s("pad").speed(2).loopAt(4)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty)
        // loopAt(4) sets speed=1/4; the existing speed(2) is overwritten by loopAt's merge
        // (loopAt uses withControl which merges, right side wins → speed=0.25)
        XCTAssertEqual(haps[0].value["speed"]?.doubleValue ?? -1, 0.25, accuracy: 1e-9,
                       "loopAt(4) overrides speed to 1/4=0.25")
    }

    // MARK: - 14. CodeParser acceptance

    /// All P2 functions must be parseable from code strings by CodeParser.

    func testCodeParserArp() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"note("[c4,e4,g4]").s("sine").arp("up")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 3, "CodeParser: arp('up') on 3-note chord = 3 events")
        let noteVals = haps.compactMap { $0.value["note"]?.doubleValue }.sorted()
        XCTAssertEqual(noteVals, [60, 64, 67], "arp('up') ascending notes via CodeParser")
    }

    func testCodeParserSuperimpose() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd sn").superimpose(x => x.fast(2))"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 6, "CodeParser: superimpose(fast(2)) = 6 events")
    }

    func testCodeParserStut() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd").stut(3, 0.5, 0.25)"#)
        let haps = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        // stut(3, 0.5, 0.25): 5 events in [0,1) due to periodic rotation wrapping (same as Strudel)
        XCTAssertEqual(haps.count, 5, "CodeParser: stut(3, 0.5, 0.25) = 5 events (periodic wrap)")
        // Gains 0.5 and 0.25 should appear
        let gains = Set(haps.compactMap { $0.value["gain"]?.doubleValue })
        XCTAssertTrue(gains.contains(1.0), "stut: gain 1.0 present (copy 0)")
        XCTAssertTrue(gains.contains(0.5), "stut: gain 0.5 present (copy 1)")
        XCTAssertTrue(gains.contains(0.25), "stut: gain 0.25 present (copy 2)")
    }

    func testCodeParserEcho() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd").echo(3, 0.25, 0.5)"#)
        let haps = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        // echo(3, 0.25, 0.5) = stut(3, 0.5, 0.25): same 5 events
        XCTAssertEqual(haps.count, 5, "CodeParser: echo(3, 0.25, 0.5) = 5 events (periodic wrap)")
    }

    func testCodeParserIter() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd sn hh oh").iter(4)"#)
        let c0 = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        let c1 = pat.queryArc(Rational(1), Rational(2)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c0[0].value["s"]?.stringValue, "bd", "iter(4) cycle 0 starts with bd")
        XCTAssertEqual(c1[0].value["s"]?.stringValue, "sn", "iter(4) cycle 1 starts with sn")
    }

    func testCodeParserChunk() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd sn hh oh").chunk(4, x => x.fast(2))"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 5, "CodeParser: chunk(4, fast(2)) = 5 events in cycle 0")
    }

    func testCodeParserPalindrome() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd sn hh oh").palindrome"#)
        let c0 = pat.queryArc(Rational(0), Rational(1)).sorted { $0.part.begin < $1.part.begin }
        let c1 = pat.queryArc(Rational(1), Rational(2)).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(c0[0].value["s"]?.stringValue, "bd", "palindrome cycle 0: bd first (normal)")
        XCTAssertEqual(c1[0].value["s"]?.stringValue, "oh", "palindrome cycle 1: oh first (reversed)")
    }

    func testCodeParserHurry() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd sn").hurry(2)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 4, "CodeParser: hurry(2) = 4 events")
        for hap in haps {
            XCTAssertEqual(hap.value["speed"]?.doubleValue ?? -1, 2.0, accuracy: 1e-9,
                           "CodeParser: hurry(2) sets speed=2")
        }
    }

    func testCodeParserSwingBy() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd sn hh oh").swingBy(0.33, 2)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 4, "CodeParser: swingBy preserves event count")
    }

    func testCodeParserSwing() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("bd sn").swing(2)"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 2, "CodeParser: swing(2) preserves event count")
    }

    func testCodeParserSlice() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").slice(4, "0 1 2 3")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 4, "CodeParser: slice(4, '0 1 2 3') = 4 events")
        XCTAssertEqual(haps[0].value["begin"]?.doubleValue ?? -1, 0.0, accuracy: 1e-9)
    }

    func testCodeParserLoopAt() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("pad").loopAt(2)"#)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty, "CodeParser: loopAt(2) produces events")
        XCTAssertEqual(haps[0].value["speed"]?.doubleValue ?? -1, 0.5, accuracy: 1e-9,
                       "CodeParser: loopAt(2) → speed=0.5")
    }

    func testCodeParserDegradeInMiniNotation() throws {
        let parser = CodeParser()
        // bd? in mini-notation inside s() — parses and produces probabilistic output
        let pat = try parser.parse(#"s("bd? sn")"#)
        // sn should always appear; bd? might not
        var snCount = 0
        for c in 0..<50 {
            let haps = pat.queryArc(Rational(c), Rational(c + 1))
                .filter { $0.value["s"] != nil }
            snCount += haps.filter { $0.value["s"]?.stringValue == "sn" }.count
        }
        XCTAssertEqual(snCount, 50, "CodeParser: sn (no ?) always present")
    }

    func testCodeParserPolymeterInMiniNotation() throws {
        let parser = CodeParser()
        let pat = try parser.parse(#"s("{bd sn, hh hh hh}")"#)
        let haps = pat.firstCycle()
        XCTAssertEqual(haps.count, 5,
                       "CodeParser: s('{bd sn, hh hh hh}') = 5 events (polymeter single-cycle)")
    }
}
