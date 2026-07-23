// ---------------------------------------------------------------------------
// PatternValidator — valida sintaxis de código de patrón antes de reproducir.
//
// Detecta funciones no soportadas y JavaScript arbitrario, reportando
// diagnósticos legibles en español sin jamás lanzar ni crashear.
// ---------------------------------------------------------------------------

import Foundation

// MARK: - Tipo público de diagnóstico

public struct PatternDiagnostic: Equatable {
    public enum Kind: Equatable {
        case unsupported
        case arbitraryJS
        case info
    }

    public let kind: Kind
    /// Función/sintaxis ofensora (ej. "pickOut").
    public let token: String
    /// Mensaje legible en español.
    public let message: String
    /// Alternativa sugerida, si existe.
    public let suggestion: String?
    /// Línea del código (1-based) donde aparece el problema.
    public let line: Int
}

// MARK: - validate(_:) en CodeParser

extension CodeParser {

    // Construcciones base reconocidas que no son métodos encadenados
    private static let recognizedBase: Set<String> = [
        "s", "sound", "note", "n", "stack", "samples", "setcps", "setcpm",
        // señales continuas como base
        "sine", "saw", "isaw", "tri", "square", "cosine", "rand", "perlin"
    ]

    // Sugerencias para casos conocidos
    private static let suggestions: [String: String] = [
        "pickOut":      "usa `<>` para alternar secciones o `pick`",
        "pick":         "no soportado aún (P2)",
        "pickRestart":  "no soportado aún (P2)",
        "clip":         "expresión no soportada aún (P3)",
        "late":         "expresión no soportada aún (P3)",
        "early":        "expresión no soportada aún (P3)",
        "transpose":    "expresión no soportada aún (P3)",
        "velocity":     "expresión no soportada aún (P3)",
        "chord":        "acordes por nombre no soportados aún (P4)",
        "voicing":      "acordes por nombre no soportados aún (P4)",
        "anchor":       "acordes por nombre no soportados aún (P4)",
        "layer":        "no soportado aún (P2); usa stack()"
    ]

    /// Valida el código de patrón y devuelve una lista de diagnósticos.
    /// Nunca lanza ni crashea — todo error interno queda silenciado.
    public func validate(_ code: String) -> [PatternDiagnostic] {
        guard !code.isEmpty else { return [] }

        var diagnostics: [PatternDiagnostic] = []
        // Usamos un Set para deduplicar por (token, line)
        var seen: Set<String> = []

        let lines = code.components(separatedBy: .newlines)

        for (lineIdx, rawLine) in lines.enumerated() {
            let lineNumber = lineIdx + 1

            // Ignorar líneas de comentario puras
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("//") { continue }

            // Eliminar comentarios al final de la línea para análisis
            let cleanLine = stripLineComment(rawLine)

            // ── a) Detectar JavaScript arbitrario ──────────────────────────
            if looksLikeArbitraryJS(cleanLine) {
                let key = "js:\(lineNumber)"
                if !seen.contains(key) {
                    seen.insert(key)
                    diagnostics.append(PatternDiagnostic(
                        kind: .arbitraryJS,
                        token: cleanLine.trimmingCharacters(in: .whitespacesAndNewlines),
                        message: "JavaScript arbitrario no soportado — el motor es parser de mini-notación + scheduler, no intérprete JS.",
                        suggestion: nil,
                        line: lineNumber
                    ))
                }
                continue   // no buscar métodos en esta línea
            }

            // ── b) Detectar funciones no soportadas ────────────────────────
            let methodNames = extractMethodNames(from: cleanLine)

            for name in methodNames {
                // Está soportado? (consulta directa al set de CodeParser)
                if knownMethods.contains(name) { continue }
                // Es una base reconocida?
                if CodeParser.recognizedBase.contains(name) { continue }

                let key = "\(name):\(lineNumber)"
                if seen.contains(key) { continue }
                seen.insert(key)

                let suggestion = CodeParser.suggestions[name]
                let isFriendly = friendlyUnknown.contains(name)

                let message: String
                if isFriendly {
                    message = "`\(name)` aún no está implementada en este motor."
                } else if let sug = suggestion {
                    message = "`\(name)` no soportado — \(sug)."
                } else {
                    message = "`\(name)` no soportado por el motor."
                }

                diagnostics.append(PatternDiagnostic(
                    kind: .unsupported,
                    token: name,
                    message: message,
                    suggestion: suggestion,
                    line: lineNumber
                ))
            }
        }

        // Ordenar por línea
        return diagnostics.sorted { $0.line < $1.line }
    }

    // MARK: - Helpers privados

    /// Determina si una línea limpia (sin comentario) parece JS arbitrario.
    private func looksLikeArbitraryJS(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }

        // Patrones de JS: declaraciones, arrow functions, register
        if t.hasPrefix("const ") || t.hasPrefix("let ") || t.hasPrefix("var ") ||
           t.hasPrefix("function ") {
            return true
        }
        if t.contains("=>") { return true }
        if t.contains("register(") { return true }

        return false
    }

    /// Extrae nombres de métodos/funciones invocadas en una línea.
    /// Combina regex sobre `.nombre(` y nombres base `nombre(`.
    private func extractMethodNames(from line: String) -> [String] {
        var names: [String] = []

        // Regex: captura el identificador justo antes de `(`
        // Cubre `.nombre(` y también `nombre(` al principio de expresión
        let pattern = #"(?:^|[\s.(,])([a-zA-Z_][a-zA-Z0-9_]*)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        let matches = regex.matches(in: line, range: range)

        for match in matches {
            if match.numberOfRanges > 1 {
                let captureRange = match.range(at: 1)
                if captureRange.location != NSNotFound {
                    let name = nsLine.substring(with: captureRange)
                    names.append(name)
                }
            }
        }

        return names
    }

    /// Elimina el comentario `//` de una línea, respetando strings.
    private func stripLineComment(_ line: String) -> String {
        var result = ""
        var inDoubleQuote = false
        var inSingleQuote = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            let next = line.index(after: i)

            if ch == "\"" && !inSingleQuote { inDoubleQuote.toggle() }
            else if ch == "'" && !inDoubleQuote { inSingleQuote.toggle() }

            let inString = inDoubleQuote || inSingleQuote
            if !inString && ch == "/" && next < line.endIndex && line[next] == "/" {
                break
            }

            result.append(ch)
            i = next
        }
        return result
    }
}
