// ---------------------------------------------------------------------------
// ValidatorTests — Tests para el validador de patrones (P0).
//
// Verifica que CodeParser.validate(_:) detecte correctamente:
//   - Funciones soportadas → sin diagnósticos
//   - Funciones no soportadas → .unsupported con token y suggestion
//   - JavaScript arbitrario → .arbitraryJS
//   - Strings vacíos o basura → no crashea
// ---------------------------------------------------------------------------

import XCTest
@testable import MiniEngine

final class ValidatorTests: XCTestCase {

    // MARK: - 1. Patrón válido → sin diagnósticos

    func testValidPatternNoDiagnostics() {
        let code = """
        s("bd hh sd").gain(0.5)
        """
        let diags = CodeParser().validate(code)
        XCTAssertEqual(diags, [], "Patrón simple soportado no debe generar diagnósticos")
    }

    // MARK: - 2. pickOut → unsupported con suggestion

    func testPickOutUnsupported() {
        let code = """
        note("c e g").pickOut(2)
        """
        let diags = CodeParser().validate(code)
        XCTAssertEqual(diags.count, 1, "Debe haber exactamente 1 diagnóstico para pickOut")

        let diag = diags[0]
        XCTAssertEqual(diag.kind, .unsupported)
        XCTAssertEqual(diag.token, "pickOut")
        XCTAssertNotNil(diag.suggestion, "pickOut debe tener sugerencia")
        XCTAssertEqual(diag.line, 1)
    }

    // MARK: - 3. JavaScript arbitrario

    func testArbitraryJSConst() {
        let code = "const x = 1"
        let diags = CodeParser().validate(code)
        XCTAssertEqual(diags.count, 1, "const x = 1 debe generar 1 diagnóstico arbitraryJS")
        XCTAssertEqual(diags[0].kind, .arbitraryJS)
        XCTAssertEqual(diags[0].line, 1)
    }

    func testArbitraryJSArrow() {
        let code = "const fn = x => x + 1"
        let diags = CodeParser().validate(code)
        let jsCount = diags.filter { $0.kind == .arbitraryJS }.count
        XCTAssertGreaterThan(jsCount, 0, "Arrow function debe generar diagnóstico arbitraryJS")
    }

    // MARK: - 4. clip → soportado desde P3 (sin diagnóstico)

    func testClipUnsupported() {
        // clip fue marcado "unsupported (P3)" hasta P2. Ahora que P3 está implementado,
        // clip está en knownMethods y NO debe generar diagnóstico.
        let code = """
        s("bd").clip(0.5)
        """
        let diags = CodeParser().validate(code)
        let clipDiags = diags.filter { $0.token == "clip" }
        XCTAssertTrue(clipDiags.isEmpty,
                      "clip ya está soportado (P3): no debe generar diagnóstico")
    }

    // MARK: - 5. Patrón multi-línea con stack → sin diagnósticos

    func testMultiLineStackNoDiagnostics() {
        let code = """
        stack(
          s("bd hh sd").gain(0.8).room(0.3),
          note("c4 e4 g4").s("sine").slow(2).cutoff(1200)
        )
        """
        let diags = CodeParser().validate(code)
        XCTAssertEqual(diags, [], "stack con funciones soportadas no debe generar diagnósticos")
    }

    // MARK: - 6. String vacío → no crashea

    func testEmptyStringNoCrash() {
        let diags = CodeParser().validate("")
        XCTAssertNotNil(diags, "validate('') debe devolver una lista (vacía), no crashear")
        XCTAssertEqual(diags, [], "validate('') debe devolver []")
    }

    // MARK: - 7. String con basura → no crashea

    func testGarbageStringNoCrash() {
        let code = "!@#$%^&*()_+{}|:<>?"
        let diags = CodeParser().validate(code)
        // Puede retornar diagnósticos o no, pero no debe crashear
        XCTAssertNotNil(diags, "validate con basura no debe crashear")
    }

    // MARK: - 8. Comentarios son ignorados

    func testLineCommentsIgnored() {
        let code = """
        // const x = 1
        s("bd").gain(0.5)
        """
        let diags = CodeParser().validate(code)
        XCTAssertEqual(diags, [], "Líneas de comentario no deben generar diagnósticos")
    }

    // MARK: - 9. Múltiples funciones no soportadas, deduplicación por línea

    func testMultipleUnsupportedDeduplication() {
        // clip fue actualizado a soportado en P3; ahora solo pickOut es no soportado.
        // Verificamos que pickOut se detecta y clip ya NO genera diagnóstico (soportado P3).
        let code = """
        note("c e g").pickOut(2).clip(0.5)
        """
        let diags = CodeParser().validate(code)
        let tokens = diags.map { $0.token }
        XCTAssertTrue(tokens.contains("pickOut"), "Debe detectar pickOut")
        // clip ya está soportado (P3): no debe aparecer en diagnósticos
        XCTAssertFalse(tokens.contains("clip"), "clip ya soportado (P3): no debe generar diagnóstico")
        // No duplicados del mismo token+línea
        let pickOutCount = diags.filter { $0.token == "pickOut" && $0.line == 1 }.count
        XCTAssertEqual(pickOutCount, 1, "pickOut en línea 1 no debe estar duplicado")
    }

    // MARK: - 10. layer → unsupported con suggestion
    // Nota: el argumento usa sintaxis JS (lambda), pero la detección de la función
    // `layer` como no soportada se verifica con un argumento no-JS válido.

    func testLayerUnsupported() {
        // Usamos una invocación de layer sin lambda (para que arbitraryJS no enmascare
        // el diagnóstico de unsupported en esa misma línea).
        let code = "s(\"bd\").layer(2)"
        let diags = CodeParser().validate(code)
        let layerDiags = diags.filter { $0.token == "layer" }
        XCTAssertFalse(layerDiags.isEmpty, "layer debe ser detectado como no soportado")
        XCTAssertNotNil(layerDiags.first?.suggestion, "layer debe tener sugerencia")
    }

    // MARK: - 11. Funciones P2 válidas no generan diagnósticos

    func testP2FunctionsNoDiagnostics() {
        let code = """
        s("bd hh sd").arp("up").iter(3).palindrome
        """
        let diags = CodeParser().validate(code)
        XCTAssertEqual(diags, [], "Funciones P2 soportadas no deben generar diagnósticos")
    }

    // MARK: - 12. setcps, setcpm → no generan diagnósticos

    func testSetcpsNoDiagnostics() {
        let code = """
        setcps(0.5)
        s("bd hh sd").gain(0.8)
        """
        let diags = CodeParser().validate(code)
        XCTAssertEqual(diags, [], "setcps más patrón válido no debe generar diagnósticos")
    }
}
