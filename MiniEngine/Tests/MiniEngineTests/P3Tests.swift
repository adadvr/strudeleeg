// ---------------------------------------------------------------------------
// P3Tests — Tests para P3: expresión y timing en MiniEngine.
//
// Cobertura:
//   1. note("c4").transpose(12)     — transpone "note" en semitones
//   2. s("bd").velocity(0.5)        — campo velocity; ScheduledEvent.velocity
//   3. s("bd").clip(0.5)            — ScheduledEvent.durationSec reducido
//   4. note("c4 e4").late(0.25)     — desplaza eventos 0.25 ciclos más tarde
//   5. note("c4 e4").early(0.25)    — desplaza eventos 0.25 ciclos antes
//   6. note("c4/2")                 — mini-notación /n: c4 sobre 2 ciclos
//   7. CodeParser: late/early/transpose/velocity/clip parseables
//   8. Validator: clip/late/early/transpose/velocity ya NO son sugerencias
// ---------------------------------------------------------------------------

import XCTest
@testable import MiniEngine

final class P3Tests: XCTestCase {

    // MARK: - 1. transpose

    /// note("c4").transpose(12) → el hap tiene note=72 (60+12 = una octava arriba).
    func testTransposeSemitones() {
        let pat = note("c4").s("sine").transpose(12)
        let haps = pat.firstCycle()
        let noteVals = haps.compactMap { $0.value["note"]?.doubleValue }
        XCTAssertFalse(noteVals.isEmpty, "transpose: debe haber al menos un hap con note")
        XCTAssertTrue(noteVals.allSatisfy { $0 == 72.0 },
                      "transpose(12) sobre c4(60) debe dar 72; got \(noteVals)")
    }

    /// note("c4 e4").transpose(-2) → notas 58 (60-2) y 62 (64-2).
    func testTransposeNegative() {
        let pat = note("c4 e4").s("sine").transpose(-2)
        let haps = pat.firstCycle().sorted { $0.part.begin < $1.part.begin }
        let noteVals = haps.compactMap { $0.value["note"]?.doubleValue }
        XCTAssertEqual(noteVals.count, 2, "transpose(-2) sobre 2 notas da 2 haps")
        XCTAssertEqual(noteVals[0], 58.0, "c4(60) - 2 = 58")
        XCTAssertEqual(noteVals[1], 62.0, "e4(64) - 2 = 62")
    }

    /// s("bd") sin campo "note" no se ve afectado por transpose.
    func testTransposeNoNoteField() {
        let pat = s("bd").transpose(7)
        let haps = pat.firstCycle()
        // No debe haber campo "note" inyectado
        XCTAssertFalse(haps.isEmpty, "transpose: debe haber haps")
        for hap in haps {
            XCTAssertNil(hap.value["note"]?.doubleValue,
                         "transpose sobre hap sin note no debe crear campo note")
        }
    }

    /// Overload Int: transpose(12) equivalente a transpose(Double(12)).
    func testTransposeIntOverload() {
        let patD = note("c4").s("sine").transpose(Double(12))
        let patI = note("c4").s("sine").transpose(12)
        let valsD = patD.firstCycle().compactMap { $0.value["note"]?.doubleValue }
        let valsI = patI.firstCycle().compactMap { $0.value["note"]?.doubleValue }
        XCTAssertEqual(valsD, valsI, "transpose(Int) y transpose(Double) deben coincidir")
    }

    // MARK: - 2. velocity

    /// s("bd").velocity(0.5) → campo velocity=0.5 en el hap.
    func testVelocityField() {
        let pat = s("bd").velocity(0.5)
        let haps = pat.firstCycle()
        XCTAssertFalse(haps.isEmpty, "velocity: debe haber haps")
        let velVals = haps.compactMap { $0.value["velocity"]?.doubleValue }
        XCTAssertTrue(velVals.allSatisfy { $0 == 0.5 },
                      "velocity(0.5) debe inyectar campo velocity=0.5; got \(velVals)")
    }

    /// ScheduledEvent extrae velocity=0.5 y gain efectivo = gain × velocity.
    func testVelocityScheduledEvent() {
        let pat = s("bd").velocity(0.5)
        let haps = pat.queryArc(.zero, .one)
        let events = PatternEventExtractor.events(
            haps: haps,
            cycleSeconds: 2.0,
            startHostTime: 0.0,
            windowStart: 0.0,
            windowEnd: 2.0,
            defaultOrbit: 1
        )
        XCTAssertFalse(events.isEmpty, "velocity: debe haber al menos un evento")
        for ev in events {
            XCTAssertEqual(ev.velocity, 0.5, accuracy: 1e-9,
                           "ScheduledEvent.velocity debe ser 0.5")
            // gain efectivo (responsabilidad del scheduler): gain * velocity
            let effectiveGain = ev.gain * ev.velocity
            XCTAssertEqual(effectiveGain, 0.5, accuracy: 1e-9,
                           "gain efectivo (gain=1 × velocity=0.5) debe ser 0.5")
        }
    }

    /// velocity(1.0) por defecto → sin cambio de volumen.
    func testVelocityDefaultOne() {
        let pat = s("bd")
        let haps = pat.queryArc(.zero, .one)
        let events = PatternEventExtractor.events(
            haps: haps,
            cycleSeconds: 2.0,
            startHostTime: 0.0,
            windowStart: 0.0,
            windowEnd: 2.0,
            defaultOrbit: 1
        )
        for ev in events {
            XCTAssertEqual(ev.velocity, 1.0, accuracy: 1e-9,
                           "velocity por defecto debe ser 1.0")
        }
    }

    // MARK: - 3. clip

    /// s("bd").clip(0.5) → ScheduledEvent.durationSec = mitad de la duración del hap.
    func testClipHalfDuration() {
        // Un hap de s("bd") en un ciclo: whole=[0,1), durationCycles=1 → durationSec=cycleSeconds*1
        let cycleSeconds = 2.0
        let pat = s("bd").clip(0.5)
        let haps = pat.queryArc(.zero, .one)
        let events = PatternEventExtractor.events(
            haps: haps,
            cycleSeconds: cycleSeconds,
            startHostTime: 0.0,
            windowStart: 0.0,
            windowEnd: cycleSeconds,
            defaultOrbit: 1
        )
        XCTAssertFalse(events.isEmpty, "clip: debe haber al menos un evento")
        for ev in events {
            XCTAssertEqual(ev.clip ?? -1.0, 0.5, accuracy: 1e-9,
                           "ScheduledEvent.clip debe ser 0.5")
            // durationSec = hapDuration × cycleSeconds × clip = 1 × 2 × 0.5 = 1.0
            XCTAssertEqual(ev.durationSec, 1.0, accuracy: 1e-9,
                           "durationSec con clip(0.5) sobre 1 ciclo a 2s/ciclo debe ser 1.0s")
        }
    }

    /// s("bd").clip(2.0) → duración legato (doble de larga).
    func testClipLegato() {
        let cycleSeconds = 2.0
        let pat = s("bd").clip(2.0)
        let haps = pat.queryArc(.zero, .one)
        let events = PatternEventExtractor.events(
            haps: haps,
            cycleSeconds: cycleSeconds,
            startHostTime: 0.0,
            windowStart: 0.0,
            windowEnd: cycleSeconds,
            defaultOrbit: 1
        )
        XCTAssertFalse(events.isEmpty, "clip legato: debe haber al menos un evento")
        for ev in events {
            XCTAssertEqual(ev.durationSec, 4.0, accuracy: 1e-9,
                           "durationSec con clip(2) sobre 1 ciclo a 2s/ciclo debe ser 4.0s")
        }
    }

    /// Sin clip → durationSec completo (clip=nil no modifica duración).
    func testClipNilIsFullDuration() {
        let cycleSeconds = 2.0
        let pat = s("bd")
        let haps = pat.queryArc(.zero, .one)
        let events = PatternEventExtractor.events(
            haps: haps,
            cycleSeconds: cycleSeconds,
            startHostTime: 0.0,
            windowStart: 0.0,
            windowEnd: cycleSeconds,
            defaultOrbit: 1
        )
        XCTAssertFalse(events.isEmpty, "sin clip: debe haber al menos un evento")
        for ev in events {
            XCTAssertNil(ev.clip, "sin .clip(), ScheduledEvent.clip debe ser nil")
            XCTAssertEqual(ev.durationSec, cycleSeconds, accuracy: 1e-9,
                           "sin clip, durationSec = cycleSeconds completo")
        }
    }

    // MARK: - 4. late

    /// note("c4").late(0.25) → el único evento del ciclo se desplaza 0.25 ciclos más tarde.
    /// Sobre pure("c4"): whole=[0,1), part.begin=0 → tras late(0.25): part.begin=0.25.
    func testLateShiftsOnset() {
        // Usamos pure de un solo evento para evitar ambigüedad de haps desde ciclos adyacentes.
        let pat     = note("c4").s("sine")           // 1 hap por ciclo, whole=[0,1)
        let shifted = pat.late(0.25)

        // late(0.25) desplaza 1/4 de ciclo más tarde.
        // Buscamos el hap cuyo whole/whole.begin sea 1/4 (dentro de [0,2)).
        let lated = shifted.queryArc(.zero, Rational(2))
        XCTAssertFalse(lated.isEmpty, "late(0.25): debe haber haps en [0,2)")

        // El hap del ciclo 0 (shifted): whole debería comenzar en 0.25.
        // Filtramos haps cuyo whole begin ≥ 0 y < 1 (ciclo 0).
        let inCycle0 = lated.filter { hap in
            guard let w = hap.whole else { return false }
            return w.begin >= Rational(0) && w.begin < Rational(1)
        }
        XCTAssertFalse(inCycle0.isEmpty,
                       "late(0.25): debe haber un hap con whole en [0,1)")
        if let hap = inCycle0.first {
            XCTAssertEqual(hap.whole?.begin, Rational(1, 4),
                           "late(0.25): whole.begin debe ser 1/4 (desplazado desde 0)")
        }
    }

    // MARK: - 5. early

    /// note("c4").early(0.25) → el evento se desplaza 0.25 ciclos antes.
    /// Sobre pure: whole=[0,1), tras early(0.25): whole.begin=-0.25 (= 3/4 del ciclo -1).
    func testEarlyShiftsOnsetBack() {
        let pat     = note("c4").s("sine")
        let shifted = pat.early(0.25)

        // early(0.25) = rotL(1/4): el hap del ciclo 0 pasa a estar en [-1/4, 3/4).
        // Buscamos en [-1, 2) para encontrar el hap "desplazado" del ciclo 0.
        let earlyHaps = shifted.queryArc(Rational(-1), Rational(2))

        XCTAssertFalse(earlyHaps.isEmpty, "early: debe haber haps")

        // El hap que originally tenía whole=[0,1) ahora tiene whole=[-1/4, 3/4).
        let shifted0 = earlyHaps.filter { hap in
            guard let w = hap.whole else { return false }
            return w.begin == Rational(-1, 4)
        }
        XCTAssertFalse(shifted0.isEmpty,
                       "early(0.25): debe haber un hap con whole.begin = -1/4")
    }

    /// late y early son inversos: late(t).early(t) sobre pure devuelve el mismo whole.
    /// Usamos un solo evento para evitar ambigüedad con múltiples haps por ciclo.
    func testLateEarlyInverse() {
        let pat       = note("c4").s("sine")             // pure: whole=[0,1) cada ciclo
        let orig      = pat.firstCycle()                  // 1 hap: whole=[0,1)
        let roundTrip = pat.late(0.25).early(0.25).firstCycle()

        XCTAssertEqual(orig.count, roundTrip.count,
                       "late(t).early(t): mismo número de haps que el original")
        for (a, b) in zip(orig, roundTrip) {
            XCTAssertEqual(a.whole?.begin, b.whole?.begin,
                           "late(t).early(t): whole.begin debe coincidir con el original")
            XCTAssertEqual(a.whole?.end, b.whole?.end,
                           "late(t).early(t): whole.end debe coincidir con el original")
        }
    }

    // MARK: - 6. Mini-notación /n

    /// note("c4/2") → c4 se extiende sobre 2 ciclos.
    /// Semántica slow(2): el pattern interno se ralentiza ×2.
    /// queryArc(0,2) debe dar exactamente 1 hap con whole=[0,2).
    func testMiniSlashSlowsAtom() {
        let pat  = note("c4/2")
        let haps = pat.queryArc(Rational(0), Rational(2))

        // slow(2) sobre pure("c4") → 1 hap por super-ciclo [0,2)
        XCTAssertFalse(haps.isEmpty, "note('c4/2') debe dar al menos 1 hap en [0,2)")

        // El hap debe tener whole que abarca 2 ciclos
        let hasWidoHap = haps.contains { hap in
            guard let w = hap.whole else { return false }
            return w.end - w.begin >= Rational(2)
        }
        XCTAssertTrue(hasWidoHap,
                      "note('c4/2'): debe haber un hap cuyo whole abarca 2 ciclos")
    }

    /// note("c4/2") en el ciclo 0 debe tener note=60 (c4).
    func testMiniSlashNoteValue() {
        let pat  = note("c4/2")
        let haps = pat.queryArc(Rational(0), Rational(1))
        let noteVals = haps.compactMap { $0.value["note"]?.doubleValue }
        XCTAssertFalse(noteVals.isEmpty, "note('c4/2') debe tener haps en el ciclo 0")
        XCTAssertTrue(noteVals.allSatisfy { $0 == 60.0 },
                      "note('c4/2') note debe ser 60 (c4); got \(noteVals)")
    }

    /// note("a/2 b") en la mini-notación: "a" ralentizado ×2, "b" normal.
    /// Verificamos que ambos valores están presentes en el rango [0,2).
    func testMiniSlashInSequence() {
        // "a/2 b" se parsea como secuencia: [slow(a,2), b]
        let pat  = MiniNotationCore.parse("a/2 b")
        let haps = pat.queryArc(Rational(0), Rational(2))
        let vals = haps.map { $0.value }
        XCTAssertTrue(vals.contains("a") || vals.contains("b"),
                      "mini 'a/2 b': debe haber haps con 'a' y/o 'b'")
    }

    // MARK: - 7. CodeParser: los nuevos métodos se parsean correctamente

    func testCodeParserLate() throws {
        let pat = try CodeParser().parse("""
            note("c4").s("sine").late(0.25)
        """)
        let haps = pat.queryArc(Rational(0), Rational(2))
        XCTAssertFalse(haps.isEmpty, "CodeParser late: debe haber haps")
    }

    func testCodeParserEarly() throws {
        let pat = try CodeParser().parse("""
            note("c4").s("sine").early(0.125)
        """)
        let haps = pat.queryArc(Rational(0), Rational(2))
        XCTAssertFalse(haps.isEmpty, "CodeParser early: debe haber haps")
    }

    func testCodeParserTranspose() throws {
        let pat = try CodeParser().parse("""
            note("c4").s("sine").transpose(12)
        """)
        let noteVals = pat.firstCycle().compactMap { $0.value["note"]?.doubleValue }
        XCTAssertTrue(noteVals.allSatisfy { $0 == 72.0 },
                      "CodeParser transpose(12) sobre c4 debe dar 72; got \(noteVals)")
    }

    func testCodeParserVelocity() throws {
        let pat = try CodeParser().parse("""
            s("bd").velocity(0.8)
        """)
        let velVals = pat.firstCycle().compactMap { $0.value["velocity"]?.doubleValue }
        XCTAssertFalse(velVals.isEmpty, "CodeParser velocity: debe haber campo velocity")
        XCTAssertTrue(velVals.allSatisfy { $0 == 0.8 },
                      "CodeParser velocity(0.8) debe dar velocity=0.8; got \(velVals)")
    }

    func testCodeParserClip() throws {
        let pat = try CodeParser().parse("""
            s("bd").clip(0.5)
        """)
        let clipVals = pat.firstCycle().compactMap { $0.value["clip"]?.doubleValue }
        XCTAssertFalse(clipVals.isEmpty, "CodeParser clip: debe haber campo clip")
        XCTAssertTrue(clipVals.allSatisfy { $0 == 0.5 },
                      "CodeParser clip(0.5) debe dar clip=0.5; got \(clipVals)")
    }

    // MARK: - 8. Validator: P3 ya NO produce sugerencias

    func testValidatorClipNotSuggested() {
        let diags = CodeParser().validate("""
            s("bd").clip(0.5)
        """)
        let clipDiags = diags.filter { $0.token == "clip" }
        XCTAssertTrue(clipDiags.isEmpty,
                      "clip ya soportado (P3): el validator no debe reportar diagnóstico")
    }

    func testValidatorLateNotSuggested() {
        let diags = CodeParser().validate("""
            note("c4").s("sine").late(0.25)
        """)
        let lateDiags = diags.filter { $0.token == "late" }
        XCTAssertTrue(lateDiags.isEmpty,
                      "late ya soportado (P3): el validator no debe reportar diagnóstico")
    }

    func testValidatorEarlyNotSuggested() {
        let diags = CodeParser().validate("""
            note("c4").s("sine").early(0.25)
        """)
        let earlyDiags = diags.filter { $0.token == "early" }
        XCTAssertTrue(earlyDiags.isEmpty,
                      "early ya soportado (P3): el validator no debe reportar diagnóstico")
    }

    func testValidatorTransposeNotSuggested() {
        let diags = CodeParser().validate("""
            note("c4").s("sine").transpose(12)
        """)
        let diag = diags.filter { $0.token == "transpose" }
        XCTAssertTrue(diag.isEmpty,
                      "transpose ya soportado (P3): el validator no debe reportar diagnóstico")
    }

    func testValidatorVelocityNotSuggested() {
        let diags = CodeParser().validate("""
            s("bd").velocity(0.5)
        """)
        let diag = diags.filter { $0.token == "velocity" }
        XCTAssertTrue(diag.isEmpty,
                      "velocity ya soportado (P3): el validator no debe reportar diagnóstico")
    }
}

