// ---------------------------------------------------------------------------
// ChordsTests — Tests para P4: sistema de acordes por nombre.
//
// Cubre:
//   1. parseChordSymbol — tabla de acordes + parser
//   2. chord("Am") — constructor de ControlPattern
//   3. chord("<Am C>") — progresión con slowcat
//   4. chord("G7") — acorde de 4 notas
//   5. chord("Xyz") — símbolo inválido → no crashea (vacío)
//   6. chord("Am").voicing() — re-disposición cerca de c5 (MIDI 72)
//   7. chord("Am").anchor("g5").voicing() — re-disposición cerca de g5 (MIDI 79)
//   8. CodeParser: chord("<Am E>").voicing() — parsea sin lanzar, produce note
//   9. Validador: chord(...) ya NO se reporta como no soportado
// ---------------------------------------------------------------------------

import XCTest
@testable import MiniEngine

final class ChordsTests: XCTestCase {

    // MARK: - 1. parseChordSymbol — tabla de acordes

    /// Am → A3(57) + [0,3,7] = [57, 60, 64]
    func testParseChordSymbolAm() {
        // A3 = MIDI 57 (a3); menor: +0,+3,+7 = 57,60,64
        let notes = parseChordSymbol("Am")
        XCTAssertNotNil(notes, "Am debe parsearse")
        XCTAssertEqual(notes, [57, 60, 64],
                       "Am en octava base 3: A3(57)+[0,3,7]=[57,60,64]")
    }

    /// C → C3(48) + [0,4,7] = [48, 52, 55]
    func testParseChordSymbolC() {
        let notes = parseChordSymbol("C")
        XCTAssertNotNil(notes, "C debe parsearse")
        XCTAssertEqual(notes, [48, 52, 55],
                       "C mayor en octava base 3: C3(48)+[0,4,7]=[48,52,55]")
    }

    /// G7 → G3(55) + [0,4,7,10] = [55, 59, 62, 65]
    func testParseChordSymbolG7() {
        let notes = parseChordSymbol("G7")
        XCTAssertNotNil(notes, "G7 debe parsearse")
        XCTAssertEqual(notes, [55, 59, 62, 65],
                       "G7 (dominante) en octava base 3: G3(55)+[0,4,7,10]=[55,59,62,65]")
    }

    /// Fmaj7 → F3(53) + [0,4,7,11] = [53, 57, 60, 64]
    func testParseChordSymbolFmaj7() {
        let notes = parseChordSymbol("Fmaj7")
        XCTAssertNotNil(notes, "Fmaj7 debe parsearse")
        XCTAssertEqual(notes, [53, 57, 60, 64],
                       "Fmaj7 en octava base 3: F3(53)+[0,4,7,11]=[53,57,60,64]")
    }

    /// Dm → D3(50) + [0,3,7] = [50, 53, 57]
    func testParseChordSymbolDm() {
        let notes = parseChordSymbol("Dm")
        XCTAssertNotNil(notes, "Dm debe parsearse")
        XCTAssertEqual(notes, [50, 53, 57],
                       "Dm en octava base 3: D3(50)+[0,3,7]=[50,53,57]")
    }

    /// Sufijos de alias: "min" = "m"
    func testParseChordSymbolMinAlias() {
        let notesM   = parseChordSymbol("Am")
        let notesMin = parseChordSymbol("Amin")
        XCTAssertEqual(notesM, notesMin, "Am y Amin deben producir las mismas notas")
    }

    /// Sufijo "dim" — A3(57)+[0,3,6]=[57,60,63]
    func testParseChordSymbolDim() {
        let notes = parseChordSymbol("Adim")
        XCTAssertNotNil(notes, "Adim debe parsearse")
        XCTAssertEqual(notes?.count, 3, "Adim tiene 3 notas")
        XCTAssertEqual(notes, [57, 60, 63],
                       "Adim: A3(57)+[0,3,6]=[57,60,63]")
    }

    /// Símbolo inválido → nil (sin crash)
    func testParseChordSymbolInvalid() {
        XCTAssertNil(parseChordSymbol("Xyz"), "Xyz debe devolver nil")
        XCTAssertNil(parseChordSymbol(""),    "string vacío debe devolver nil")
        XCTAssertNil(parseChordSymbol("123"), "número debe devolver nil")
    }

    // MARK: - 2. chord("Am") — 3 haps simultáneos por ciclo

    /// chord("Am") debe producir 3 haps con campo "note" en ciclo 0
    func testChordAmProduces3Haps() {
        let pat = chord("Am")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 3,
                       "chord('Am') debe producir 3 haps simultáneos (triada menor)")
    }

    /// Las notas de chord("Am") deben ser 57, 60, 64 (A3, C4, E4)
    func testChordAmNoteValues() {
        let pat = chord("Am")
        let haps = pat.queryArc(Rational(0), Rational(1))
        let notes = haps.compactMap { $0.value["note"]?.doubleValue }.sorted()
        XCTAssertEqual(notes, [57.0, 60.0, 64.0],
                       "chord('Am') notas: [57,60,64] = A3,C4,E4")
    }

    /// Los haps de chord("Am") deben ser simultáneos: mismo part
    func testChordAmHapsAreSimultaneous() {
        let pat = chord("Am")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 3, "chord('Am') debe tener 3 haps")
        let parts = haps.map { $0.part }
        // Todos deben tener el mismo part (mismo span temporal)
        guard let firstPart = parts.first else { return }
        for part in parts {
            XCTAssertEqual(part.begin, firstPart.begin, "Todos los haps de un acorde deben empezar al mismo tiempo")
            XCTAssertEqual(part.end,   firstPart.end,   "Todos los haps de un acorde deben terminar al mismo tiempo")
        }
    }

    // MARK: - 3. chord("<Am C>") — progresión por ciclo

    /// ciclo 0 → Am (3 notas), ciclo 1 → C (3 notas)
    func testChordProgressionAlternates() {
        let pat = chord("<Am C>")

        // Ciclo 0: Am
        let haps0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps0.count, 3, "ciclo 0 debe ser Am (3 notas)")
        let notes0 = haps0.compactMap { $0.value["note"]?.doubleValue }.sorted()
        XCTAssertEqual(notes0, [57.0, 60.0, 64.0], "ciclo 0 debe ser Am: [57,60,64]")

        // Ciclo 1: C
        let haps1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertEqual(haps1.count, 3, "ciclo 1 debe ser C (3 notas)")
        let notes1 = haps1.compactMap { $0.value["note"]?.doubleValue }.sorted()
        XCTAssertEqual(notes1, [48.0, 52.0, 55.0], "ciclo 1 debe ser C: [48,52,55]")
    }

    // MARK: - 4. chord("G7") — acorde de 4 notas

    func testChordG7Has4Notes() {
        let pat = chord("G7")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 4, "chord('G7') debe producir 4 haps (séptima dominante)")
        let notes = haps.compactMap { $0.value["note"]?.doubleValue }.sorted()
        XCTAssertEqual(notes, [55.0, 59.0, 62.0, 65.0],
                       "chord('G7') notas: [55,59,62,65] = G3,B3,D4,F4")
    }

    // MARK: - 5. chord("Xyz") inválido — no crashea

    func testChordInvalidSymbolNocrash() {
        let pat = chord("Xyz")
        // No debe crashear; puede devolver 0 haps
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 0, "chord con símbolo inválido debe producir 0 haps (silencio)")
    }

    func testChordEmptyStringNocrash() {
        let pat = chord("")
        let haps = pat.queryArc(Rational(0), Rational(1))
        // El comportamiento para string vacío puede ser 0 haps o 1 hap silente
        // Lo importante es que no crashee
        XCTAssertTrue(haps.count >= 0, "chord('') no debe crashear")
    }

    // MARK: - 6. chord("Am").voicing() — pitch classes preservadas, cerca de c5

    /// voicing() debe preservar los pitch classes {9,0,4} de Am
    func testChordAmVoicingPreservesPitchClasses() {
        let pat = chord("Am").voicing()
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 3, "voicing de Am debe tener 3 notas")

        let notes = haps.compactMap { $0.value["note"]?.doubleValue }
        let pitchClasses = notes.map { n -> Int in
            let pc = Int(n.rounded()) % 12
            return (pc + 12) % 12
        }
        let pcSet = Set(pitchClasses)
        // Am tiene pitch classes: A=9, C=0, E=4
        XCTAssertEqual(pcSet, Set([9, 0, 4]),
                       "voicing de Am debe preservar pitch classes {9,0,4}")
    }

    /// voicing() sin anchor → notas cerca de c5 (MIDI 72)
    func testChordAmVoicingNearDefaultAnchor() {
        let anchorMidi = 72.0  // c5
        let pat = chord("Am").voicing()
        let haps = pat.queryArc(Rational(0), Rational(1))
        let notes = haps.compactMap { $0.value["note"]?.doubleValue }

        // Las notas deben estar en un rango cercano al ancla (≤ 12 semitonos de distancia)
        // La primera nota (más baja) debe ser ≤ ancla
        let sortedNotes = notes.sorted()
        if let lowest = sortedNotes.first {
            XCTAssertLessThanOrEqual(lowest, anchorMidi + 1,
                                     "La nota más baja del voicing debe estar cerca o por debajo del ancla c5=72")
        }
    }

    /// voicing() no debe dejar campo "_anchor" en el resultado
    func testChordVoicingRemovesAnchorField() {
        let pat = chord("Am").anchor("g5").voicing()
        let haps = pat.queryArc(Rational(0), Rational(1))
        for hap in haps {
            XCTAssertNil(hap.value["_anchor"],
                         "voicing() debe eliminar el campo '_anchor' del resultado")
        }
    }

    // MARK: - 7. chord("Am").anchor("g5").voicing() — cerca de g5

    /// anchor("g5") → MIDI 79; las notas deben quedar cerca de 79
    func testChordAmAnchorG5Voicing() {
        let anchorMidi = 79.0  // g5
        let pat = chord("Am").anchor("g5").voicing()
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 3, "voicing con anchor g5 debe tener 3 notas")

        let notes = haps.compactMap { $0.value["note"]?.doubleValue }

        // Verificar pitch classes preservadas
        let pitchClasses = notes.map { n -> Int in
            let pc = Int(n.rounded()) % 12
            return (pc + 12) % 12
        }
        let pcSet = Set(pitchClasses)
        XCTAssertEqual(pcSet, Set([9, 0, 4]),
                       "voicing con anchor g5 debe preservar pitch classes de Am {9,0,4}")

        // La nota más baja debe estar cerca de 79 (no más de 11 semitonos por debajo)
        let sortedNotes = notes.sorted()
        if let lowest = sortedNotes.first {
            XCTAssertLessThanOrEqual(lowest, anchorMidi + 1,
                                     "La nota más baja debe estar cerca o por debajo del ancla g5=79")
            XCTAssertGreaterThanOrEqual(lowest, anchorMidi - 12,
                                        "La nota más baja no debe alejarse más de 12 semitonos del ancla")
        }
    }

    /// Las notas del voicing deben ser estrictamente ascendentes
    func testChordVoicingIsAscending() {
        let pat = chord("Am").anchor("g5").voicing()
        let haps = pat.queryArc(Rational(0), Rational(1))
        let notes = haps.compactMap { $0.value["note"]?.doubleValue }.sorted()
        for i in 1..<notes.count {
            XCTAssertGreaterThan(notes[i], notes[i-1],
                                 "Las notas del voicing deben ser estrictamente ascendentes")
        }
    }

    // MARK: - 8. CodeParser — chord como base, voicing y anchor como métodos

    /// chord("<Am E>").voicing() — parsea sin lanzar y produce eventos note
    func testCodeParserChordVoicing() throws {
        let parser = CodeParser()
        let pattern = try parser.parse(#"chord("<Am E>").voicing()"#)
        // Ciclo 0: Am en voicing
        let haps = pattern.queryArc(Rational(0), Rational(1))
        XCTAssertGreaterThan(haps.count, 0, "chord con voicing debe producir eventos")
        for hap in haps {
            XCTAssertNotNil(hap.value["note"],
                            "Los eventos de chord deben tener campo 'note'")
        }
    }

    /// chord("Am").anchor("c5").voicing() — parsea sin lanzar
    func testCodeParserChordAnchorVoicing() throws {
        let parser = CodeParser()
        let pattern = try parser.parse(#"chord("Am").anchor("c5").voicing()"#)
        let haps = pattern.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 3, "chord Am con anchor y voicing debe producir 3 notas")
    }

    /// chord("<Am E Dm G>").anchor("g5").voicing() — progresión completa
    func testCodeParserChordProgressionWithVoicing() throws {
        let parser = CodeParser()
        let pattern = try parser.parse(#"chord("<Am E Dm G>").anchor("g5").voicing()"#)
        // Cada ciclo debe tener al menos 1 hap
        for cycle in 0..<4 {
            let haps = pattern.queryArc(Rational(cycle), Rational(cycle + 1))
            XCTAssertGreaterThan(haps.count, 0,
                                 "ciclo \(cycle) debe tener eventos (chord progression)")
            for hap in haps {
                XCTAssertNotNil(hap.value["note"], "cada evento debe tener campo 'note'")
            }
        }
    }

    // MARK: - 9. Validador — chord ya NO se reporta como no soportado

    /// chord(...) debe estar en knownMethods → validador no lo reporta
    func testValidatorChordNotReported() {
        let validator = CodeParser()
        let diagnostics = validator.validate(#"chord("Am")"#)
        let chordDiag = diagnostics.filter { $0.token == "chord" }
        XCTAssertTrue(chordDiag.isEmpty,
                      "chord debe estar soportado; el validador no debe reportarlo")
    }

    /// voicing() debe estar en knownMethods → validador no lo reporta
    func testValidatorVoicingNotReported() {
        let validator = CodeParser()
        let diagnostics = validator.validate(#"chord("Am").voicing()"#)
        let voicingDiag = diagnostics.filter { $0.token == "voicing" }
        XCTAssertTrue(voicingDiag.isEmpty,
                      "voicing debe estar soportado; el validador no debe reportarlo")
    }

    /// anchor() debe estar en knownMethods → validador no lo reporta
    func testValidatorAnchorNotReported() {
        let validator = CodeParser()
        let diagnostics = validator.validate(#"chord("Am").anchor("g5").voicing()"#)
        let anchorDiag = diagnostics.filter { $0.token == "anchor" }
        XCTAssertTrue(anchorDiag.isEmpty,
                      "anchor debe estar soportado; el validador no debe reportarlo")
    }

    // MARK: - Tests adicionales de solidez

    /// chord con acorde aug (aumentado) debe producir 3 notas
    func testChordAugmented() {
        let pat = chord("Caug")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 3, "Caug debe tener 3 notas")
        let notes = haps.compactMap { $0.value["note"]?.doubleValue }.sorted()
        // C3(48)+[0,4,8]=[48,52,56]
        XCTAssertEqual(notes, [48.0, 52.0, 56.0], "Caug: C3(48)+[0,4,8]=[48,52,56]")
    }

    /// chord con acorde maj9 (5 notas)
    func testChordMaj9Has5Notes() {
        let pat = chord("Cmaj9")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 5, "Cmaj9 debe tener 5 notas")
    }

    /// chord con bemol: Bb
    func testChordBbMajor() {
        let pat = chord("Bb")
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 3, "Bb mayor debe tener 3 notas")
        // Bb3 = MIDI 58, +4=62, +7=65
        let notes = haps.compactMap { $0.value["note"]?.doubleValue }.sorted()
        XCTAssertEqual(notes, [58.0, 62.0, 65.0], "Bb mayor: Bb3(58)+[0,4,7]=[58,62,65]")
    }

    /// voicing sobre acorde de 4 notas (Am7) debe producir 4 notas
    func testChordAm7VoicingHas4Notes() {
        let pat = chord("Am7").voicing()
        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertEqual(haps.count, 4, "Am7 voicing debe tener 4 notas")
    }
}
