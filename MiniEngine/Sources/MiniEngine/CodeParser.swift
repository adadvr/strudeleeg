// ---------------------------------------------------------------------------
// CodeParser — parses the top-level Strudel-like editor code into a ControlPattern.
//
// Supports:
//   stack(expr, expr, ...)
//   s("mini") .note("mini") .slow(n) .fast(n) .gain(n|"mini") .room(n) .cutoff(n)
//   // line comments (stripped before parsing)
// ---------------------------------------------------------------------------

import Foundation

public enum CodeParseError: Error, LocalizedError {
    case syntaxError(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .syntaxError(let m): return "Syntax error: \(m)"
        case .unsupported(let f): return "Unsupported function: \(f)"
        }
    }
}

public struct CodeParser {

    public init() {}

    /// Parse a full code string and return a ControlPattern.
    public func parse(_ rawCode: String) throws -> ControlPattern {
        let code = stripLineComments(rawCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if code.hasPrefix("stack(") {
            let inner = try extractArgs(code, function: "stack")
            let parts = splitTopLevelCommas(inner)
            let layers = try parts.map { try parseLayerExpr($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return stackCP(layers)
        } else {
            return try parseLayerExpr(code)
        }
    }

    // MARK: - Comment stripping

    /// Remove // ... end-of-line comments, but not inside quoted strings.
    private func stripLineComments(_ code: String) -> String {
        var result: [Character] = []
        var inString = false
        var i = code.startIndex

        while i < code.endIndex {
            let ch = code[i]
            let next = code.index(after: i)

            if ch == "\"" {
                inString.toggle()
                result.append(ch)
                i = next
                continue
            }

            if !inString && ch == "/" && next < code.endIndex && code[next] == "/" {
                // Skip to end of line
                var j = next
                while j < code.endIndex && code[j] != "\n" {
                    j = code.index(after: j)
                }
                i = j
                continue
            }

            result.append(ch)
            i = next
        }
        return String(result)
    }

    // MARK: - Layer expression parser

    /// Parse a single layer expression like:
    ///   s("pad").slow(4).gain(0.5).room(0.6)
    ///   note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7)
    private func parseLayerExpr(_ expr: String) throws -> ControlPattern {
        let chain = try parseMethodChain(expr)

        guard !chain.isEmpty else {
            throw CodeParseError.syntaxError("Empty expression")
        }

        let supportedMethods: Set<String> = ["s", "note", "slow", "fast", "gain", "room", "cutoff", "stack"]
        for token in chain where !supportedMethods.contains(token.name) {
            // For now, warn and skip unknown methods rather than hard-fail
            // (facilitates forward-compatibility)
        }

        // Determine the base pattern (s or note)
        var base: ControlPattern?

        if let sToken = chain.first(where: { $0.name == "s" }), let sArg = sToken.arg {
            base = s(unquote(sArg))
        }

        if let noteToken = chain.first(where: { $0.name == "note" }), let noteArg = noteToken.arg {
            let notePat = note(unquote(noteArg))
            if let existing = base {
                base = existing.withControl(notePat)
            } else {
                base = notePat
            }
        }

        guard var pattern = base else {
            throw CodeParseError.syntaxError("Layer must start with s(...) or note(...): \(expr)")
        }

        // Apply timing modifiers
        if let slowToken = chain.first(where: { $0.name == "slow" }),
           let arg = slowToken.arg, let factor = Double(arg.trimmingCharacters(in: .whitespaces)) {
            pattern = pattern.slow(factor)
        } else if let fastToken = chain.first(where: { $0.name == "fast" }),
                  let arg = fastToken.arg, let factor = Double(arg.trimmingCharacters(in: .whitespaces)) {
            pattern = pattern.fast(factor)
        }

        // Apply effect controls
        for token in chain {
            switch token.name {
            case "gain":
                if let arg = token.arg {
                    let trimmed = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(trimmed) {
                        pattern = pattern.gain(v)
                    } else {
                        pattern = pattern.gain(unquote(trimmed))
                    }
                }
            case "room":
                if let arg = token.arg {
                    let trimmed = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(trimmed) {
                        pattern = pattern.room(v)
                    } else {
                        pattern = pattern.room(unquote(trimmed))
                    }
                }
            case "cutoff":
                if let arg = token.arg {
                    let trimmed = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(trimmed) {
                        pattern = pattern.cutoff(v)
                    } else {
                        pattern = pattern.cutoff(unquote(trimmed))
                    }
                }
            default:
                break
            }
        }

        return pattern
    }

    // MARK: - Method chain tokenizer

    private struct ChainToken {
        let name: String
        let arg: String?
    }

    private func parseMethodChain(_ expr: String) throws -> [ChainToken] {
        var tokens: [ChainToken] = []
        var remaining = expr.trimmingCharacters(in: .whitespacesAndNewlines)

        while !remaining.isEmpty {
            if remaining.hasPrefix(".") {
                remaining = String(remaining.dropFirst())
            }

            // Read identifier
            var ident = ""
            while let first = remaining.first, (first.isLetter || first.isNumber || first == "_") {
                ident.append(first)
                remaining = String(remaining.dropFirst())
            }
            guard !ident.isEmpty else {
                remaining = String(remaining.dropFirst())
                continue
            }

            remaining = remaining.trimmingCharacters(in: .whitespaces)

            if remaining.hasPrefix("(") {
                remaining = String(remaining.dropFirst())
                let (arg, rest) = try extractParenContent(remaining)
                remaining = rest.trimmingCharacters(in: .whitespaces)
                tokens.append(ChainToken(name: ident, arg: arg))
            } else {
                tokens.append(ChainToken(name: ident, arg: nil))
            }
        }
        return tokens
    }

    private func extractParenContent(_ s: String) throws -> (String, String) {
        var depth = 0
        var content = ""
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "(" { depth += 1; content.append(ch) }
            else if ch == ")" {
                if depth == 0 {
                    idx = s.index(after: idx)
                    return (content, String(s[idx...]))
                }
                depth -= 1
                content.append(ch)
            } else {
                content.append(ch)
            }
            idx = s.index(after: idx)
        }
        throw CodeParseError.syntaxError("Unmatched '(' in expression")
    }

    // MARK: - Helpers

    private func extractArgs(_ code: String, function fn: String) throws -> String {
        let prefix = "\(fn)("
        guard code.hasPrefix(prefix) else {
            throw CodeParseError.syntaxError("Expected \(fn)(...)")
        }
        var depth = 0
        let startIdx = code.index(code.startIndex, offsetBy: prefix.count)
        var endIdx: String.Index? = nil
        for (i, ch) in code[startIdx...].enumerated() {
            let idx = code.index(startIdx, offsetBy: i)
            if ch == "(" { depth += 1 }
            else if ch == ")" {
                if depth == 0 { endIdx = idx; break }
                depth -= 1
            }
        }
        guard let end = endIdx else {
            throw CodeParseError.syntaxError("Unmatched parenthesis in \(fn)")
        }
        return String(code[startIdx..<end])
    }

    private func splitTopLevelCommas(_ s: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        var inString = false
        var prevChar: Character = "\0"
        for ch in s {
            if ch == "\"" && prevChar != "\\" { inString.toggle() }
            if !inString {
                if ch == "(" || ch == "[" { depth += 1 }
                else if ch == ")" || ch == "]" { depth -= 1 }
                else if ch == "," && depth == 0 {
                    parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                    prevChar = ch
                    continue
                }
            }
            current.append(ch)
            prevChar = ch
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    private func unquote(_ s: String) -> String {
        var r = s.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("\"") { r = String(r.dropFirst()) }
        if r.hasSuffix("\"") { r = String(r.dropLast()) }
        return r
    }
}
