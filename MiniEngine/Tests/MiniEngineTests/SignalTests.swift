// ---------------------------------------------------------------------------
// SignalTests — P0-2: Señales continuas
//
// Verifica:
//   1. Semántica de signal(): punto de muestreo (begin del span), whole=nil
//   2. Osciladores: sine, saw, isaw, tri, square, cosine, rand, perlin
//   3. Métodos: .range(), .rangex(), .segment(), .slow(), .fast()
//   4. Fase exacta de sine (t=0→0.5, t=0.25→1.0 — confirmado contra oracle)
//   5. Integración con gain: .gain(sine) → valor evaluado por evento
//   6. CodeParser: expresiones de señal parseadas correctamente
//   7. Determinismo de rand con seed (mismo t → mismo valor)
// ---------------------------------------------------------------------------

import XCTest
@testable import MiniEngine

final class SignalTests: XCTestCase {

    // MARK: - 1. signal() base semantics

    func testSignalWholeIsNil() {
        // Una señal continua no tiene estructura discreta: whole = nil
        let sig = signal { t in t }
        let haps = sig.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1, "signal must return exactly 1 hap per query")
        XCTAssertNil(haps[0].whole, "signal hap must have whole=nil (no discrete structure)")
    }

    func testSignalSampledAtSpanBegin() {
        // Semántica confirmada contra oracle: la señal se evalúa en span.begin
        // signal(identity) queryArc(0.5, 1.0) → value = 0.5 (begin del span)
        let sig = signal { t in t }
        let haps = sig.queryArc(Rational(1, 2), Rational(1))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.5, accuracy: 1e-12)
    }

    func testSignalPartMatchesQuerySpan() {
        // El part del hap cubre el span consultado completo
        let sig = signal { t in t }
        let span = TimeSpan(Rational(1, 4), Rational(3, 4))
        let haps = sig.query(span)
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].part, span)
    }

    func testSignalReturnsOneHapPerQuery() {
        // Una señal continua devuelve 1 hap por CADA llamada al query function.
        // queryArc(0, 5) es una sola llamada (sin splitQueries) → 1 hap.
        // signal() no tiene estructura discreta, whole=nil.
        let sig = signal { t in sin(t) }
        XCTAssertEqual(sig.queryArc(Rational(0), Rational(5)).count, 1)
    }

    // MARK: - 2. Osciladores: fase exacta confirmada contra oracle

    func testSinePhasAt0() {
        // oracle: sine sampled at t=0 → (sin(0)+1)/2 = 0.5
        let haps = sine.queryArc(Rational(0), Rational(1, 8))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.5, accuracy: 1e-10, "sine(0) must be 0.5")
    }

    func testSinePhaseAt025() {
        // oracle: sine sampled at t=0.25 → (sin(π/2)+1)/2 = 1.0
        let haps = sine.queryArc(Rational(1, 4), Rational(3, 8))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 1.0, accuracy: 1e-10, "sine(0.25) must be 1.0 (peak)")
    }

    func testSinePhaseAt05() {
        // sine at t=0.5 → (sin(π)+1)/2 ≈ 0.5
        let haps = sine.queryArc(Rational(1, 2), Rational(5, 8))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.5, accuracy: 1e-10, "sine(0.5) must be 0.5")
    }

    func testSinePhaseAt075() {
        // sine at t=0.75 → (sin(3π/2)+1)/2 = 0.0
        let haps = sine.queryArc(Rational(3, 4), Rational(7, 8))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.0, accuracy: 1e-10, "sine(0.75) must be 0.0 (trough)")
    }

    func testSineRange0To1() {
        // sine must always be in [0, 1]
        let haps = sine.queryArc(Rational(0), Rational(4))
        for hap in haps {
            XCTAssertGreaterThanOrEqual(hap.value, 0.0)
            XCTAssertLessThanOrEqual(hap.value, 1.0 + 1e-10)
        }
    }

    // MARK: - 3. saw

    func testSawAt0() {
        // saw(0) = 0 % 1 = 0
        let haps = saw.queryArc(Rational(0), Rational(1, 4))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.0, accuracy: 1e-10)
    }

    func testSawAt05() {
        // saw(0.5) = 0.5 % 1 = 0.5
        let haps = saw.queryArc(Rational(1, 2), Rational(3, 4))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.5, accuracy: 1e-10)
    }

    func testSawWrapsAtCycleBoundary() {
        // saw(1.0) = 1 % 1 = 0 (resets at cycle boundary)
        let haps = saw.queryArc(Rational(1), Rational(5, 4))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.0, accuracy: 1e-10)
    }

    // MARK: - 4. isaw

    func testIsawAt0() {
        // isaw(0) = 1 - 0 = 1
        let haps = isaw.queryArc(Rational(0), Rational(1, 4))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 1.0, accuracy: 1e-10)
    }

    func testIsawAt05() {
        // isaw(0.5) = 1 - 0.5 = 0.5
        let haps = isaw.queryArc(Rational(1, 2), Rational(3, 4))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.5, accuracy: 1e-10)
    }

    // MARK: - 5. square

    func testSquareFirstHalf() {
        // square(0) = floor(0*2 % 2) = 0
        let haps = square.queryArc(Rational(0), Rational(1, 4))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.0, accuracy: 1e-10)
    }

    func testSquareSecondHalf() {
        // square(0.5) = floor(1.0 % 2) = 1
        let haps = square.queryArc(Rational(1, 2), Rational(3, 4))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 1.0, accuracy: 1e-10)
    }

    // MARK: - 6. tri

    func testTriAt0() {
        // tri = fastcat(saw, isaw). At t=0 (cycle 0, first half) → saw(0)=0
        let haps = tri.queryArc(Rational(0), Rational(1, 4))
        XCTAssertFalse(haps.isEmpty)
        // First hap in [0, 1/2) is saw-like; at begin t=0 → value=0
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(sorted[0].value, 0.0, accuracy: 1e-10)
    }

    func testTriAt025() {
        // tri at t=0.25 → saw(0.5 relative) = 0.5
        // In first half [0,0.5), saw is mapped: t_inner = t * 2, saw(0.5)=0.5
        let haps = tri.queryArc(Rational(1, 4), Rational(3, 8))
        XCTAssertFalse(haps.isEmpty)
    }

    // MARK: - 7. cosine

    func testCosineAt0() {
        // cosine(0) = (cos(0)+1)/2 = 1.0
        let haps = cosine.queryArc(Rational(0), Rational(1, 4))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 1.0, accuracy: 1e-10, "cosine(0) must be 1.0")
    }

    func testCosineAt025() {
        // cosine(0.25) = (cos(π/2)+1)/2 ≈ 0.5
        let haps = cosine.queryArc(Rational(1, 4), Rational(3, 8))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.5, accuracy: 1e-10)
    }

    func testCosineAt05() {
        // cosine(0.5) = (cos(π)+1)/2 = 0.0
        let haps = cosine.queryArc(Rational(1, 2), Rational(3, 4))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value, 0.0, accuracy: 1e-10)
    }

    // MARK: - 8. rand — determinism and distribution

    func testRandDeterminism() {
        // Same time → same value (deterministic)
        let h1 = rand.queryArc(Rational(0), Rational(1, 4))
        let h2 = rand.queryArc(Rational(0), Rational(1, 4))
        XCTAssertEqual(h1.count, 1)
        XCTAssertEqual(h1[0].value, h2[0].value, accuracy: 1e-15)
    }

    func testRandRange() {
        // rand must always be in [0, 1)
        let haps = rand.queryArc(Rational(0), Rational(100))
        for hap in haps {
            XCTAssertGreaterThanOrEqual(hap.value, 0.0)
            XCTAssertLessThan(hap.value, 1.0)
        }
    }

    func testRandDifferentTimes() {
        // Different times should give different values (not identical sequence)
        let h0 = rand.queryArc(Rational(0), Rational(1, 4))[0].value
        let h1 = rand.queryArc(Rational(1), Rational(5, 4))[0].value
        let h2 = rand.queryArc(Rational(2), Rational(9, 4))[0].value
        // Not all equal (with overwhelming probability for any reasonable hash)
        XCTAssertFalse(h0 == h1 && h1 == h2, "rand should vary across time")
    }

    // MARK: - 9. perlin — smoothness and range

    func testPerlinRange() {
        // perlin must stay in [0, 1]
        let haps = perlin.queryArc(Rational(0), Rational(50))
        for hap in haps {
            XCTAssertGreaterThanOrEqual(hap.value, 0.0)
            XCTAssertLessThanOrEqual(hap.value, 1.0 + 1e-10)
        }
    }

    func testPerlinSmoothness() {
        // Perlin noise should be bounded [0,1] and vary
        let h0 = perlin.queryArc(Rational(0), Rational(1, 8))[0].value
        let h1 = perlin.queryArc(Rational(1, 8), Rational(2, 8))[0].value
        // Difference between consecutive samples should be < 0.5 (smooth)
        XCTAssertLessThan(abs(h1 - h0), 0.5, "perlin should be smooth (no jumps > 0.5)")
    }

    // MARK: - 10. .range()

    func testRangeScalesCorrectly() {
        // saw.range(2, 4) at t=0 → 0 * (4-2) + 2 = 2.0
        // Confirmed against oracle: saw.range(2,4).segment(4) → [2, 2.5, 3, 3.5]
        let sig = saw.range(2.0, 4.0)
        let h = sig.queryArc(Rational(0), Rational(1, 4))
        XCTAssertEqual(h[0].value, 2.0, accuracy: 1e-10)
    }

    func testRangeAt05() {
        // saw.range(2, 4) at t=0.5 → 0.5 * (4-2) + 2 = 3.0
        let sig = saw.range(2.0, 4.0)
        let h = sig.queryArc(Rational(1, 2), Rational(3, 4))
        XCTAssertEqual(h[0].value, 3.0, accuracy: 1e-10)
    }

    func testSineRange() {
        // sine.range(200, 2000) at t=0 → 0.5 * (2000-200) + 200 = 1100
        let sig = sine.range(200.0, 2000.0)
        let h = sig.queryArc(Rational(0), Rational(1, 8))
        XCTAssertEqual(h[0].value, 1100.0, accuracy: 1e-8)
    }

    func testSineRangeAtPeak() {
        // sine.range(200, 2000) at t=0.25 → 1.0 * 1800 + 200 = 2000
        let sig = sine.range(200.0, 2000.0)
        let h = sig.queryArc(Rational(1, 4), Rational(3, 8))
        XCTAssertEqual(h[0].value, 2000.0, accuracy: 1e-8)
    }

    // MARK: - 11. .rangex()

    func testRangexAt0() {
        // saw.rangex(100, 1000) at t=0 → exp(0 * log(10) + log(100)) = 100
        let sig = saw.rangex(100.0, 1000.0)
        let h = sig.queryArc(Rational(0), Rational(1, 4))
        XCTAssertEqual(h[0].value, 100.0, accuracy: 1e-8)
    }

    func testRangexAt1() {
        // saw.rangex(100, 1000) at t=999/1000:
        // saw(999/1000) = 0.999, rangex: exp(0.999*log(10) + log(100)) ≈ 997.7
        // Not exactly 1000 (saw never reaches exactly 1 before wrapping).
        // Verify: result is between 990 and 1000 (within 1% of max).
        let sig = saw.rangex(100.0, 1000.0)
        let h = sig.queryArc(Rational(999, 1000), Rational(1))
        XCTAssertFalse(h.isEmpty)
        XCTAssertGreaterThan(h[0].value, 990.0, "rangex near t=1 should be close to 1000")
        XCTAssertLessThanOrEqual(h[0].value, 1000.0)
    }

    // MARK: - 12. .segment() — discretizes signal

    func testSegmentCount() {
        // sine.segment(8) → 8 haps per cycle (confirmed against oracle)
        let haps = sine.segment(8).queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 8)
    }

    func testSegmentHasWholeSpan() {
        // Segmented haps have whole = part (discrete structure, not nil)
        let haps = sine.segment(4).queryArc(Rational(0), Rational(1))
        for hap in haps {
            XCTAssertNotNil(hap.whole, "segment hap must have non-nil whole (discrete structure)")
        }
    }

    func testSegmentFirstHapValue() {
        // sine.segment(8) first hap: value = sine at t=0 = 0.5
        // Confirmed exactly against oracle
        let haps = sine.segment(8).queryArc(Rational(0), Rational(1))
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(sorted[0].value, 0.5, accuracy: 1e-10,
            "sine.segment(8)[0] must be 0.5 (sine sampled at t=0)")
        XCTAssertEqual(sorted[0].part.begin, Rational(0))
        XCTAssertEqual(sorted[0].part.end, Rational(1, 8))
    }

    func testSegmentSecondHapValue() {
        // sine.segment(8)[1]: value = sine at t=1/8 = (sin(2π/8)+1)/2 = (sin(π/4)+1)/2
        let expected = (sin(2.0 * .pi / 8.0) + 1.0) / 2.0
        let haps = sine.segment(8).queryArc(Rational(0), Rational(1))
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(sorted[1].value, expected, accuracy: 1e-10)
    }

    func testSawRangeSegment4() {
        // saw.range(2,4).segment(4) → [2.0, 2.5, 3.0, 3.5]
        // Confirmed exactly against oracle
        let haps = saw.range(2.0, 4.0).segment(4).queryArc(Rational(0), Rational(1))
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(sorted.count, 4)
        XCTAssertEqual(sorted[0].value, 2.0, accuracy: 1e-10)
        XCTAssertEqual(sorted[1].value, 2.5, accuracy: 1e-10)
        XCTAssertEqual(sorted[2].value, 3.0, accuracy: 1e-10)
        XCTAssertEqual(sorted[3].value, 3.5, accuracy: 1e-10)
    }

    func testSineSlowSegment() {
        // sine.slow(2).segment(8) queried over 2 cycles → 16 haps
        // oracle: first value=0.5 (sine sampled at t=0)
        let haps = sine.slow(2).segment(8).queryArc(Rational(0), Rational(2))
        XCTAssertEqual(haps.count, 16)
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(sorted[0].value, 0.5, accuracy: 1e-10)
    }

    // MARK: - 13. .slow() and .fast() on signals

    func testSignalSlowStretches() {
        // sine.slow(2): at t=0.25 (= 1/4 cycle) → should sample sine at t=0.125
        // Because slow(2) stretches time: inner_t = outer_t / 2
        // sine.slow(2).queryArc(0.25, 0.5) → evaluates at inner t=0.125
        // (sin(2π*0.125)+1)/2 = (sin(π/4)+1)/2 ≈ 0.854
        let expected = (sin(2.0 * .pi * 0.125) + 1.0) / 2.0
        let haps = sine.slow(2).queryArc(Rational(1, 4), Rational(1, 2))
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value, expected, accuracy: 1e-10)
    }

    func testSignalFastCompresses() {
        // sine.fast(2): completes one full sine cycle in 0.5 outer cycles
        // At outer t=0.25 → inner t=0.5 → sine(0.5)=0.5
        let haps = sine.fast(2).queryArc(Rational(1, 4), Rational(3, 8))
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value, 0.5, accuracy: 1e-10)
    }

    // MARK: - 14. Signal integration with gain (appLeft semantics)

    func testGainSineIntegration() {
        // s("bd*4").gain(sine) → 4 events, each with gain from sine
        // oracle values: gain at whole.begin=0/4→0.5, 1/4→1.0, 2/4→0.5, 3/4→0.0
        let pat = s("bd").fast(4).gain(sine)
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 4)
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }

        // Event 0: whole.begin=0 → sine(0)=0.5
        XCTAssertEqual(sorted[0].value["gain"]?.doubleValue ?? -1, 0.5, accuracy: 1e-8)
        // Event 1: whole.begin=0.25 → sine(0.25)=1.0
        XCTAssertEqual(sorted[1].value["gain"]?.doubleValue ?? -1, 1.0, accuracy: 1e-8)
        // Event 2: whole.begin=0.5 → sine(0.5)=0.5
        XCTAssertEqual(sorted[2].value["gain"]?.doubleValue ?? -1, 0.5, accuracy: 1e-8)
        // Event 3: whole.begin=0.75 → sine(0.75)=0.0
        XCTAssertEqual(sorted[3].value["gain"]?.doubleValue ?? -1, 0.0, accuracy: 1e-8)
    }

    func testLpfSignalIntegration() {
        // .lpf(sine.range(200, 2000)) — sine modulates lpf
        let pat = s("bd").lpf(sine.range(200.0, 2000.0))
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1)
        // At t=0: sine=0.5 → lpf = 0.5*(2000-200)+200 = 1100
        XCTAssertEqual(haps[0].value["lpf"]?.doubleValue ?? -1, 1100.0, accuracy: 1e-6)
    }

    func testGainSawSlowIntegration() {
        // .gain(saw.slow(4)) — saw signal slow(4) modulates gain
        // At t=0: saw.slow(4)(0) = saw(0/4) = 0 % 1 = 0
        let pat = s("bd").gain(saw.slow(4))
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["gain"]?.doubleValue ?? -1, 0.0, accuracy: 1e-10)
    }

    // MARK: - 15. CodeParser signal expressions

    func testCodeParserGainSine() throws {
        // s("bd").gain(sine) parsed from code string
        let parser = CodeParser()
        let pat = try parser.parse("s(\"bd\").gain(sine)")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["gain"]?.doubleValue ?? -1, 0.5, accuracy: 1e-8)
    }

    func testCodeParserLpfSineRange() throws {
        // s("bd").lpf(sine.range(200, 2000))
        let parser = CodeParser()
        let pat = try parser.parse("s(\"bd\").lpf(sine.range(200, 2000))")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(haps[0].value["lpf"]?.doubleValue ?? -1, 1100.0, accuracy: 1e-6)
    }

    func testCodeParserGainSawSlow() throws {
        // s("bd").gain(saw.slow(4))
        let parser = CodeParser()
        let pat = try parser.parse("s(\"bd\").gain(saw.slow(4))")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1)
        // At t=0: saw.slow(4) → inner t=0/4=0 → saw(0)=0
        XCTAssertEqual(haps[0].value["gain"]?.doubleValue ?? -1, 0.0, accuracy: 1e-10)
    }

    func testCodeParserRandRange() throws {
        // s("bd").gain(rand.range(0, 1)) — rand returns something in [0,1]
        let parser = CodeParser()
        let pat = try parser.parse("s(\"bd\").gain(rand.range(0, 1))")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1)
        let gain = haps[0].value["gain"]?.doubleValue ?? -1
        XCTAssertGreaterThanOrEqual(gain, 0.0)
        XCTAssertLessThanOrEqual(gain, 1.0)
    }

    func testCodeParserPerlinRange() throws {
        // s("bd").gain(perlin.range(0.2, 0.8))
        let parser = CodeParser()
        let pat = try parser.parse("s(\"bd\").gain(perlin.range(0.2, 0.8))")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 1)
        let gain = haps[0].value["gain"]?.doubleValue ?? -1
        XCTAssertGreaterThanOrEqual(gain, 0.2 - 1e-8)
        XCTAssertLessThanOrEqual(gain, 0.8 + 1e-8)
    }

    func testCodeParserSineRangeLpfChain() throws {
        // s("sawtooth").lpf(sine.range(200, 2000)).gain(0.5)
        let parser = CodeParser()
        let pat = try parser.parse("s(\"sawtooth\").lpf(sine.range(200, 2000)).gain(0.5)")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertFalse(haps.isEmpty)
        XCTAssertEqual(haps[0].value["gain"]?.doubleValue ?? -1, 0.5, accuracy: 1e-8)
        XCTAssertEqual(haps[0].value["lpf"]?.doubleValue ?? -1, 1100.0, accuracy: 1e-6)
    }

    // MARK: - 16. Oracle-matching signal fixture cases

    // These tests verify exact match against the Strudel oracle fixtures loaded by OracleTests.
    // They test the same formulas independently to ensure correctness.

    func testOracleSineSegment8Values() {
        // oracle: sine.segment(8) → 8 haps with values matching sin(2π*k/8)/2+0.5
        let haps = sine.segment(8).queryArc(Rational(0), Rational(1))
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(sorted.count, 8)
        let expectedValues: [Double] = (0..<8).map { k in
            (sin(2.0 * .pi * Double(k) / 8.0) + 1.0) / 2.0
        }
        for (k, (hap, expected)) in zip(sorted, expectedValues).enumerated() {
            XCTAssertEqual(hap.value, expected, accuracy: 1e-10,
                "sine.segment(8)[\(k)] expected \(expected)")
        }
    }

    func testOracleSawRangeSegment4Values() {
        // oracle: saw.range(2,4).segment(4) → [2.0, 2.5, 3.0, 3.5]
        let haps = saw.range(2.0, 4.0).segment(4).queryArc(Rational(0), Rational(1))
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(sorted.count, 4)
        let expectedValues: [Double] = [2.0, 2.5, 3.0, 3.5]
        for (k, (hap, expected)) in zip(sorted, expectedValues).enumerated() {
            XCTAssertEqual(hap.value, expected, accuracy: 1e-10,
                "saw.range(2,4).segment(4)[\(k)] expected \(expected)")
        }
    }

    func testOracleSineSlowSegment8() {
        // oracle: sine.slow(2).segment(8) over 2 cycles → 16 haps
        // First 8 values: sine(t/2) sampled at t=0,1/8,2/8,...,7/8
        let haps = sine.slow(2).segment(8).queryArc(Rational(0), Rational(2))
        let sorted = haps.sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(sorted.count, 16)
        // First hap: t=0, inner=0/2=0, sine(0)=0.5
        XCTAssertEqual(sorted[0].value, 0.5, accuracy: 1e-10)
        // 5th hap (k=4, t=4/8=0.5 outer → inner=0.25): sine(0.25)=1.0
        let expected4 = (sin(2.0 * .pi * 0.25) + 1.0) / 2.0
        XCTAssertEqual(sorted[4].value, expected4, accuracy: 1e-10)
    }

    // MARK: - 17. signal() Swift API (EEG hook)

    func testSignalSwiftCallback() {
        // Demonstrates the EEG hook: signal { t in ... }
        // In production, this would receive a real EEG feature value.
        var capturedTime: Double = -1
        let eegSignal = signal { t in
            capturedTime = t
            return 0.42  // simulate EEG feature
        }
        let haps = eegSignal.queryArc(Rational(3, 4), Rational(1))
        XCTAssertEqual(haps.count, 1)
        XCTAssertEqual(capturedTime, 0.75, accuracy: 1e-10,
            "EEG callback receives span.begin as time parameter")
        XCTAssertEqual(haps[0].value, 0.42, accuracy: 1e-15)
        XCTAssertNil(haps[0].whole, "EEG signal hap has no discrete whole")
    }
}
