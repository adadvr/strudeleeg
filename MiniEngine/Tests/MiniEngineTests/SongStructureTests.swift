// ---------------------------------------------------------------------------
// SongStructureTests — Tests para P2: estructura de canción.
//
// Cubre:
//   1. pick — selección por índice, tiempo absoluto (no reinicia)
//   2. pickOut — alias de pick, mismo comportamiento
//   3. pickRestart — selección por índice con reinicio en onset del slot
//   4. indexPattern — conversión de mini-notación a Pattern<Int>
//   5. Pattern.layer — aplica transformaciones en paralelo y apila
//   6. CodeParser: pick / pickOut / pickRestart como base
//   7. CodeParser: s("...").layer(lambda) como método
//   8. Patrones etiquetados `nombre: expr` equivalen a $:
//   9. Validador: pick / pickOut / pickRestart / layer ya NO se reportan como no soportados
// ---------------------------------------------------------------------------

import XCTest
@testable import MiniEngine

final class SongStructureTests: XCTestCase {

    // MARK: - 1. pick — selección por índice, tiempo absoluto

    /// pick(<0 1>, [s("bd"), s("hh")]): ciclo 0 → bd, ciclo 1 → hh
    func testPickAlternatesCycles() {
        let idx  = indexPattern("<0 1>")
        let pats: [ControlPattern] = [s("bd"), s("hh")]
        let pat  = pick(idx, pats)

        // Ciclo 0: debe sonar "bd"
        let haps0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertFalse(haps0.isEmpty, "pick ciclo 0 debe producir eventos")
        for hap in haps0 {
            XCTAssertEqual(hap.value["s"]?.stringValue, "bd",
                           "pick ciclo 0 debe seleccionar s=bd")
        }

        // Ciclo 1: debe sonar "hh"
        let haps1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertFalse(haps1.isEmpty, "pick ciclo 1 debe producir eventos")
        for hap in haps1 {
            XCTAssertEqual(hap.value["s"]?.stringValue, "hh",
                           "pick ciclo 1 debe seleccionar s=hh")
        }
    }

    /// Índice fuera de rango: wrap modular. índice 5 con 2 patrones → 5 % 2 = 1 → segundo patrón.
    func testPickOutOfRangeWraps() {
        let idx  = indexPattern("5")   // <5> = constante 5
        let pats: [ControlPattern] = [s("bd"), s("hh")]
        let pat  = pick(idx, pats)

        let haps = pat.queryArc(Rational(0), Rational(1))
        XCTAssertFalse(haps.isEmpty, "pick con índice 5 y 2 pats debe producir eventos (5%2=1 → hh)")
        for hap in haps {
            XCTAssertEqual(hap.value["s"]?.stringValue, "hh",
                           "índice 5 con 2 pats → wrap a 1 → s=hh")
        }
    }

    // MARK: - 2. pickOut — alias de pick

    func testPickOutIsAliasOfPick() {
        let idx   = indexPattern("<0 1>")
        let pats: [ControlPattern] = [s("bd"), s("hh")]

        let pickPat    = pick(idx, pats)
        let pickOutPat = pickOut(idx, pats)

        // Deben producir el mismo número de haps en el mismo rango
        let haps0Pick    = pickPat.queryArc(.zero, Rational(2))
        let haps0PickOut = pickOutPat.queryArc(.zero, Rational(2))

        XCTAssertEqual(haps0Pick.count, haps0PickOut.count,
                       "pickOut debe producir los mismos haps que pick")

        // Verificar que los valores coinciden (mismos onsets y s values)
        let sortedPick    = haps0Pick.sorted    { $0.part.begin < $1.part.begin }
        let sortedPickOut = haps0PickOut.sorted { $0.part.begin < $1.part.begin }
        for (p, q) in zip(sortedPick, sortedPickOut) {
            XCTAssertEqual(p.value["s"]?.stringValue, q.value["s"]?.stringValue,
                           "pickOut debe tener mismos valores que pick")
        }
    }

    // MARK: - 3. pickRestart — reinicia el patrón en el onset del slot

    /// pickRestart reinicia: los haps del sub-patrón deben comenzar dentro del slot del índice.
    func testPickRestartResetsOnset() {
        // Patrón con 4 eventos por ciclo (para verificar que se alinean al inicio del slot)
        let inner = s("bd sd hh cp")  // 4 eventos en [0,1)
        let idx   = indexPattern("0") // siempre índice 0 → siempre el mismo patrón
        let pat   = pickRestart(idx, [inner])

        let haps = pat.queryArc(Rational(0), Rational(1))
        // Debe haber eventos y todos deben estar dentro de [0, 1)
        XCTAssertFalse(haps.isEmpty, "pickRestart debe producir eventos")
        for hap in haps {
            XCTAssertGreaterThanOrEqual(hap.part.begin, Rational(0),
                                        "pickRestart: onset debe ser >= 0")
            XCTAssertLessThan(hap.part.begin, Rational(1),
                              "pickRestart: onset debe ser < 1 (dentro del slot)")
        }
    }

    /// pickRestart con índice alternante: el onset del patrón seleccionado debe
    /// siempre ser relativo al inicio del slot del índice (no al tiempo global).
    func testPickRestartAlignsToSlot() {
        // Un patrón con evento a t=0 (por ciclo)
        let inner = s("bd")  // un evento por ciclo, onset en inicio del ciclo
        let idx   = indexPattern("<0 1>")
        let pats: [ControlPattern] = [inner, s("hh")]
        let pat   = pickRestart(idx, pats)

        // En ciclo 0: slot del índice <0> = [0,1) → el sub-patrón 0 se reinicia a t=0
        // El onset de bd debe caer en [0,1)
        let haps0 = pat.queryArc(Rational(0), Rational(1))
        XCTAssertFalse(haps0.isEmpty, "pickRestart ciclo 0 debe tener eventos")
        let onsets0 = haps0.map { $0.part.begin }
        XCTAssertTrue(onsets0.allSatisfy { $0 >= .zero && $0 < .one },
                      "pickRestart ciclo 0: todos los onsets deben estar en [0,1)")

        // En ciclo 1: slot del índice <1> = [1,2) → el sub-patrón 1 se reinicia relativo a t=1
        let haps1 = pat.queryArc(Rational(1), Rational(2))
        XCTAssertFalse(haps1.isEmpty, "pickRestart ciclo 1 debe tener eventos")
        let onsets1 = haps1.map { $0.part.begin }
        XCTAssertTrue(onsets1.allSatisfy { $0 >= .one && $0 < Rational(2) },
                      "pickRestart ciclo 1: todos los onsets deben estar en [1,2)")
    }

    // MARK: - 4. indexPattern

    func testIndexPatternSimple() {
        // "0 1 2" → 3 eventos por ciclo con valores 0, 1, 2
        let pat = indexPattern("0 1 2")
        let haps = pat.queryArc(.zero, .one).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 3, "indexPattern('0 1 2') debe producir 3 haps por ciclo")
        XCTAssertEqual(haps[0].value, 0, "primer valor = 0")
        XCTAssertEqual(haps[1].value, 1, "segundo valor = 1")
        XCTAssertEqual(haps[2].value, 2, "tercer valor = 2")
    }

    func testIndexPatternAlternating() {
        // "<0 1>" → slowcat: ciclo 0 = 0, ciclo 1 = 1
        let pat = indexPattern("<0 1>")
        let haps0 = pat.queryArc(.zero, .one)
        XCTAssertEqual(haps0.count, 1, "indexPattern('<0 1>') ciclo 0: 1 hap")
        XCTAssertEqual(haps0[0].value, 0, "ciclo 0 → índice 0")

        let haps1 = pat.queryArc(.one, Rational(2))
        XCTAssertEqual(haps1.count, 1, "indexPattern('<0 1>') ciclo 1: 1 hap")
        XCTAssertEqual(haps1[0].value, 1, "ciclo 1 → índice 1")
    }

    func testIndexPatternNonNumericFallsBackToZero() {
        // Valores no numéricos en mini-notación se mapean a 0
        let pat = indexPattern("abc 2")
        let haps = pat.queryArc(.zero, .one).sorted { $0.part.begin < $1.part.begin }
        XCTAssertEqual(haps.count, 2, "indexPattern con no-numérico produce 2 haps")
        XCTAssertEqual(haps[0].value, 0, "valor no numérico 'abc' → 0")
        XCTAssertEqual(haps[1].value, 2, "valor numérico '2' → 2")
    }

    // MARK: - 5. Pattern.layer

    /// layer([identity, fast(2)]) produce el stack de original + fast(2).
    func testLayerStacksTransformations() {
        // note("c") con layer([identity, fast(2)]):
        // identity → 1 evento por ciclo
        // fast(2)  → 2 eventos por ciclo
        // stack    → 3 eventos totales por ciclo
        let pat = note("c").layer([{ $0 }, { $0.fast(2) }])
        let haps = pat.queryArc(.zero, .one)
        XCTAssertEqual(haps.count, 3,
                       "layer([id, fast(2)]) sobre note('c') debe producir 1+2=3 haps por ciclo")
    }

    func testLayerSingleTransform() {
        // layer([fast(2)]) == fast(2) solo (no incluye el original)
        let pat = s("bd").layer([{ $0.fast(2) }])
        let haps = pat.queryArc(.zero, .one)
        XCTAssertEqual(haps.count, 2,
                       "layer([fast(2)]) debe producir 2 haps (solo la transformación)")
    }

    func testLayerEmptyProducesSilence() {
        // layer([]) == stack([]) == silence
        let pat = s("bd").layer([])
        let haps = pat.queryArc(.zero, .one)
        XCTAssertEqual(haps.count, 0, "layer([]) debe producir silencio")
    }

    func testLayerThreeTransforms() {
        // layer con 3 funciones: original + rev + fast(3)
        // note("c d") tiene 2 eventos; rev → 2 (reordenados); fast(3) → 6
        // total = 2 + 2 + 6 = 10
        let pat = note("c d").layer([{ $0 }, { $0.rev }, { $0.fast(3) }])
        let haps = pat.queryArc(.zero, .one)
        XCTAssertEqual(haps.count, 10,
                       "layer([id, rev, fast(3)]) sobre note('c d') debe producir 2+2+6=10 haps")
    }

    // MARK: - 6. CodeParser: pick / pickOut / pickRestart como base

    func testCodeParserPickParses() throws {
        let code = #"pick("<0 1>", [s("bd"), s("hh")])"#
        let pat = try CodeParser().parse(code)
        let haps = pat.queryArc(.zero, Rational(2))
        XCTAssertFalse(haps.isEmpty, "pick parseado desde código debe producir eventos")

        // Ciclo 0: bd
        let haps0 = haps.filter { $0.part.begin < .one }
        XCTAssertTrue(haps0.allSatisfy { $0.value["s"]?.stringValue == "bd" },
                      "pick ciclo 0 parseado debe seleccionar bd")
        // Ciclo 1: hh
        let haps1 = haps.filter { $0.part.begin >= .one }
        XCTAssertTrue(haps1.allSatisfy { $0.value["s"]?.stringValue == "hh" },
                      "pick ciclo 1 parseado debe seleccionar hh")
    }

    func testCodeParserPickOutParses() throws {
        let code = #"pickOut("<0 1>", [s("bd"), s("hh")])"#
        let pat = try CodeParser().parse(code)
        let haps = pat.queryArc(.zero, Rational(2))
        XCTAssertFalse(haps.isEmpty, "pickOut parseado desde código debe producir eventos")
    }

    func testCodeParserPickRestartParses() throws {
        let code = #"pickRestart("<0 1>", [s("bd"), s("hh")])"#
        let pat = try CodeParser().parse(code)
        let haps = pat.queryArc(.zero, Rational(2))
        XCTAssertFalse(haps.isEmpty, "pickRestart parseado desde código debe producir eventos")
    }

    func testCodeParserPickWithNotePatterns() throws {
        // pick con patrones mixtos: s() y note()
        let code = #"pick("<0 1 2>", [s("bd"), s("hh*8"), note("c e g")])"#
        let pat = try CodeParser().parse(code)
        let haps = pat.queryArc(.zero, Rational(3))
        XCTAssertFalse(haps.isEmpty, "pick con 3 patrones debe producir eventos en 3 ciclos")
    }

    // MARK: - 7. CodeParser: layer como método

    func testCodeParserLayerWithLambdas() throws {
        // s("bd").layer(x=>x.fast(2)) — apila bd + bd*2
        let code = #"s("bd").layer(x=>x.fast(2))"#
        let pat = try CodeParser().parse(code)
        let haps = pat.queryArc(.zero, .one)
        // layer con una lambda: stack([fast(2)(s("bd"))]) = 2 haps
        XCTAssertGreaterThan(haps.count, 0, "layer parseado debe producir eventos")
        // El layer aplica fast(2) → 2 haps por ciclo
        XCTAssertEqual(haps.count, 2,
                       "s('bd').layer(x=>x.fast(2)) debe producir 2 haps (solo la lambda, sin base)")
    }

    func testCodeParserLayerStacksMultipleLambdas() throws {
        // nota: la sintaxis JS con => en lambdas puede disparar el detector de arbitraryJS
        // en el validador, pero el parser no lo usa. El parser acepta el => dentro del arg.
        // Usamos la función Swift directamente para la prueba de múltiples lambdas:
        let pat = s("bd").layer([{ $0 }, { $0.fast(2) }])
        let haps = pat.queryArc(.zero, .one)
        XCTAssertEqual(haps.count, 3, "layer([id, fast(2)]) sobre bd: 1+2=3 haps")
    }

    // MARK: - 8. Patrones etiquetados `nombre: expr` equivalen a $:

    func testLabeledPatternsStack() throws {
        // Código con etiquetas → debe apilarse igual que $: / $:
        let code = """
        drm: s("bd")
        bass: note("c2")
        """
        let pat = try CodeParser().parse(code)
        let haps = pat.queryArc(.zero, .one)
        // Debe haber eventos de ambos patrones (bd y note)
        XCTAssertFalse(haps.isEmpty, "Patrones etiquetados deben producir eventos")
        let hasS    = haps.contains { $0.value["s"] != nil }
        let hasNote = haps.contains { $0.value["note"] != nil }
        XCTAssertTrue(hasS,    "Patrón drm: s('bd') debe producir eventos con campo 's'")
        XCTAssertTrue(hasNote, "Patrón bass: note('c2') debe producir eventos con campo 'note'")
    }

    func testMutedLabeledPatternIgnored() throws {
        // Etiqueta muteada (_IDENT:) debe ignorarse (equivale a _$:)
        let code = """
        drm: s("bd")
        _bass: note("c2")
        """
        let pat = try CodeParser().parse(code)
        let haps = pat.queryArc(.zero, .one)
        // Solo drm debe sonar; bass está muteado
        let hasS    = haps.contains { $0.value["s"] != nil }
        let hasNote = haps.contains { $0.value["note"] != nil }
        XCTAssertTrue(hasS,     "Patrón activo drm: debe producir eventos con 's'")
        XCTAssertFalse(hasNote, "Patrón muteado _bass: no debe producir eventos con 'note'")
    }

    func testLabeledPatternEquivalentToDollarColon() throws {
        // `drm: s("bd")` y `$: s("bd")` deben producir los mismos haps (semántica)
        let codeLabeled = "drm: s(\"bd\")"
        let codeDollar  = "$: s(\"bd\")"

        let patLabeled = try CodeParser().parse(codeLabeled)
        let patDollar  = try CodeParser().parse(codeDollar)

        let hapsLabeled = patLabeled.queryArc(.zero, .one)
        let hapsDollar  = patDollar.queryArc(.zero, .one)

        XCTAssertEqual(hapsLabeled.count, hapsDollar.count,
                       "Patrón etiquetado y $: deben producir el mismo número de haps")
        // Verificar que los valores de 's' coinciden
        let sLabeled = hapsLabeled.compactMap { $0.value["s"]?.stringValue }.sorted()
        let sDollar  = hapsDollar.compactMap  { $0.value["s"]?.stringValue }.sorted()
        XCTAssertEqual(sLabeled, sDollar, "Etiquetado y $: deben tener los mismos valores 's'")
    }

    // MARK: - 9. Validador: pick / pickOut / pickRestart / layer no reportados como unsupported

    func testValidatorPickNotReported() {
        // pick ahora está en knownMethods y recognizedBase → no debe generar diagnóstico
        let code = #"pick("<0 1>", [s("bd"), s("hh")])"#
        let diags = CodeParser().validate(code)
        let pickDiags = diags.filter { $0.token == "pick" && $0.kind == .unsupported }
        XCTAssertTrue(pickDiags.isEmpty,
                      "pick soportado (P2): no debe generar diagnóstico unsupported")
    }

    func testValidatorPickOutNotReported() {
        let code = #"pickOut("<0 1>", [s("bd"), s("hh")])"#
        let diags = CodeParser().validate(code)
        let diag = diags.filter { $0.token == "pickOut" && $0.kind == .unsupported }
        XCTAssertTrue(diag.isEmpty,
                      "pickOut soportado (P2): no debe generar diagnóstico unsupported")
    }

    func testValidatorPickRestartNotReported() {
        let code = #"pickRestart("<0 1>", [s("bd"), s("hh")])"#
        let diags = CodeParser().validate(code)
        let diag = diags.filter { $0.token == "pickRestart" && $0.kind == .unsupported }
        XCTAssertTrue(diag.isEmpty,
                      "pickRestart soportado (P2): no debe generar diagnóstico unsupported")
    }

    func testValidatorLayerNotReported() {
        // layer soportado en P2 → no debe generar diagnóstico unsupported
        let code = "s(\"bd\").layer(2)"
        let diags = CodeParser().validate(code)
        let layerDiags = diags.filter { $0.token == "layer" && $0.kind == .unsupported }
        XCTAssertTrue(layerDiags.isEmpty,
                      "layer soportado (P2): no debe generar diagnóstico unsupported")
    }
}
