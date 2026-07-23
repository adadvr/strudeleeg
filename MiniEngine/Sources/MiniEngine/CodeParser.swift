// ---------------------------------------------------------------------------
// CodeParser — parses the top-level Strudel-like editor code into a ControlPattern.
//
// Supports:
//   setcps(x) / setcpm(x)  — top-level tempo statement (applied to scheduler)
//   stack(expr, expr, ...)
//   s("mini") .note("mini") .slow(n) .fast(n) .gain(n|"mini") .room(n) .cutoff(n)
//   .pan(n|"mini")  — stereo position 0..1
//   .delay(n) .delaytime(n) .delayfeedback(n)  — echo effect
//   .euclid(k,n) / .euclid(k,n,rot)  — Euclidean rhythm
//   n("mini") + .scale("Root:name")  — scale-based melody
//   // line comments (stripped before parsing)
//
// Unknown methods produce a friendly warning (not a hard error).
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

/// Result of parsing a code block: the pattern plus any top-level tempo setting.
public struct ParseResult {
    public let pattern: ControlPattern
    /// Cycles-per-second if setcps/setcpm appeared in the code, else nil.
    public let cps: Double?
}

public struct CodeParser {

    public init() {}

    // MARK: - Public API

    /// Parse a full code string and return a ControlPattern.
    /// setcps/setcpm statements are parsed and discarded (use parseWithTempo to get cps).
    public func parse(_ rawCode: String) throws -> ControlPattern {
        try parseWithTempo(rawCode).pattern
    }

    /// Parse code and also return the tempo (cps) if setcps/setcpm was specified.
    public func parseWithTempo(_ rawCode: String) throws -> ParseResult {
        let lines = rawCode.components(separatedBy: .newlines)

        var cps: Double? = nil
        var patternLines: [String] = []

        for line in lines {
            let stripped = stripLineCommentsFromLine(line)
            let trimmed  = stripped.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty { continue }

            // Detect setcps(x) or setcpm(x) as standalone statement
            if trimmed.hasPrefix("setcps(") {
                if let inner = extractSimpleArg(trimmed, fn: "setcps"),
                   let v = Double(inner.trimmingCharacters(in: .whitespaces)) {
                    cps = v
                }
                continue
            }
            if trimmed.hasPrefix("setcpm(") {
                if let inner = extractSimpleArg(trimmed, fn: "setcpm"),
                   let v = Double(inner.trimmingCharacters(in: .whitespaces)) {
                    cps = v / 60.0
                }
                continue
            }

            patternLines.append(stripped)
        }

        let code = patternLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !code.isEmpty else {
            return ParseResult(pattern: .silence, cps: cps)
        }

        let pattern: ControlPattern
        if code.hasPrefix("stack(") {
            let inner = try extractArgs(code, function: "stack")
            let parts = splitTopLevelCommas(inner)
            let layers = try parts.map { try parseLayerExpr($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            pattern = stackCP(layers)
        } else {
            pattern = try parseLayerExpr(code)
        }

        return ParseResult(pattern: pattern, cps: cps)
    }

    // MARK: - Comment stripping

    private func stripLineCommentsFromLine(_ line: String) -> String {
        var result: [Character] = []
        var inString = false
        var i = line.startIndex

        while i < line.endIndex {
            let ch = line[i]
            let next = line.index(after: i)

            if ch == "\"" {
                inString.toggle()
                result.append(ch)
                i = next
                continue
            }

            if !inString && ch == "/" && next < line.endIndex && line[next] == "/" {
                break  // rest of line is comment
            }

            result.append(ch)
            i = next
        }
        return String(result)
    }

    // MARK: - Layer expression parser

    private let knownMethods: Set<String> = [
        "s", "sound", "note", "n", "scale",
        "slow", "fast",
        "gain", "room", "cutoff",
        "pan",
        "delay", "delaytime", "delayfeedback",
        "euclid",
        "stack",
        // Fase 2 / Tier 3
        "rev", "ply", "every", "sometimes", "often", "rarely",
        "off", "jux", "struct",
        // Fase 3: synths
        "attack", "decay", "sustain", "release",
        "lpf", "hpf", "resonance",
        "speed",
        // Fase 4: DSP / granular
        "shape", "distort", "crush", "vowel",
        "chop", "striate",
        // Fase 4: chorus/phaser (not implemented — forwarded with warning)
        "chorus", "phaser"
    ]

    private let friendlyUnknown: Set<String> = [
        "chorus", "phaser"   // Fase 4: not implemented, warn but don't error
    ]

    private func parseLayerExpr(_ expr: String) throws -> ControlPattern {
        let chain = try parseMethodChain(expr)

        guard !chain.isEmpty else {
            throw CodeParseError.syntaxError("Empty expression")
        }

        // Warn about unrecognised methods instead of hard-failing
        for token in chain where !knownMethods.contains(token.name) {
            if friendlyUnknown.contains(token.name) {
                print("[CodeParser] '\(token.name)' is not yet supported — skipping.")
            }
        }

        // ── Determine the base pattern ──────────────────────────────────────
        var base: ControlPattern?

        // s("...") or sound("...") as standalone or in chain (sound is alias of s in Strudel)
        if let sToken = chain.first(where: { $0.name == "s" || $0.name == "sound" }), let sArg = sToken.arg {
            base = s(unquote(sArg))
        }

        // note("...")
        if let noteToken = chain.first(where: { $0.name == "note" }), let noteArg = noteToken.arg {
            let notePat = note(unquote(noteArg))
            base = base?.withControl(notePat) ?? notePat
        }

        // n("...") — scale-degree indices
        if let nToken = chain.first(where: { $0.name == "n" }), let nArg = nToken.arg {
            let nPat = n(unquote(nArg))
            base = base?.withControl(nPat) ?? nPat
        }

        guard var pattern = base else {
            throw CodeParseError.syntaxError("Layer must start with s(...), note(...), or n(...): \(expr)")
        }

        // ── Effect / control modifiers (in chain order) ─────────────────────
        for token in chain {
            switch token.name {

            // ── Timing ───────────────────────────────────────────────────────
            case "slow":
                if let arg = token.arg,
                   let factor = Double(arg.trimmingCharacters(in: .whitespaces)) {
                    pattern = pattern.slow(factor)
                }

            case "fast":
                if let arg = token.arg,
                   let factor = Double(arg.trimmingCharacters(in: .whitespaces)) {
                    pattern = pattern.fast(factor)
                }

            // ── Audio controls ───────────────────────────────────────────────
            case "gain":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.gain(v) }
                    else                 { pattern = pattern.gain(unquote(t)) }
                }

            case "room":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.room(v) }
                    else                 { pattern = pattern.room(unquote(t)) }
                }

            case "cutoff":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.cutoff(v) }
                    else                 { pattern = pattern.cutoff(unquote(t)) }
                }

            case "pan":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.pan(v) }
                    else                 { pattern = pattern.pan(unquote(t)) }
                }

            case "delay":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.delay(v) }
                    else                 { pattern = pattern.delay(unquote(t)) }
                }

            case "delaytime":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.delaytime(v) }
                    else                 { pattern = pattern.delaytime(unquote(t)) }
                }

            case "delayfeedback":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.delayfeedback(v) }
                    else                 { pattern = pattern.delayfeedback(unquote(t)) }
                }

            case "euclid":
                if let arg = token.arg {
                    let parts = splitTopLevelCommas(arg)
                    let nums = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if nums.count >= 2 {
                        let rot = nums.count >= 3 ? nums[2] : 0
                        pattern = pattern.euclid(nums[0], nums[1], rot)
                    }
                }

            // ── Fase 3: ADSR ─────────────────────────────────────────────────
            case "attack":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.attack(v) }
                    else                 { pattern = pattern.attack(unquote(t)) }
                }

            case "decay":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.decay(v) }
                    else                 { pattern = pattern.decay(unquote(t)) }
                }

            case "sustain":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.sustain(v) }
                    else                 { pattern = pattern.sustain(unquote(t)) }
                }

            case "release":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.release(v) }
                    else                 { pattern = pattern.release(unquote(t)) }
                }

            // ── Fase 3: Filters ───────────────────────────────────────────────
            case "lpf":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.lpf(v) }
                    else                 { pattern = pattern.lpf(unquote(t)) }
                }

            case "hpf":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.hpf(v) }
                    else                 { pattern = pattern.hpf(unquote(t)) }
                }

            case "resonance":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.resonance(v) }
                    else                 { pattern = pattern.resonance(unquote(t)) }
                }

            // ── Fase 3: speed ─────────────────────────────────────────────────
            case "speed":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.speed(v) }
                    else                 { pattern = pattern.speed(unquote(t)) }
                }

            case "scale":
                if let arg = token.arg {
                    let t = unquote(arg.trimmingCharacters(in: .whitespaces))
                    pattern = pattern.scale(t)
                }

            // ── Fase 2 / Tier 3: Pattern algebra ─────────────────────────────

            case "rev":
                // rev has no args (used as property: .rev or as method call .rev())
                pattern = pattern.rev

            case "ply":
                if let arg = token.arg,
                   let n = Int(arg.trimmingCharacters(in: .whitespaces)) {
                    pattern = pattern.ply(n)
                }

            case "every":
                if let arg = token.arg {
                    let parts = splitTopLevelCommas(arg)
                    if parts.count == 2,
                       let n = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       let f = parseLambda(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                        pattern = pattern.every(n, f)
                    } else {
                        print("[CodeParser] 'every' could not parse args: \(arg)")
                    }
                }

            case "sometimes":
                if let arg = token.arg,
                   let f = parseLambda(arg.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    pattern = pattern.sometimes(f)
                } else {
                    print("[CodeParser] 'sometimes' could not parse lambda arg")
                }

            case "often":
                if let arg = token.arg,
                   let f = parseLambda(arg.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    pattern = pattern.often(f)
                } else {
                    print("[CodeParser] 'often' could not parse lambda arg")
                }

            case "rarely":
                if let arg = token.arg,
                   let f = parseLambda(arg.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    pattern = pattern.rarely(f)
                } else {
                    print("[CodeParser] 'rarely' could not parse lambda arg")
                }

            case "off":
                if let arg = token.arg {
                    let parts = splitTopLevelCommas(arg)
                    if parts.count == 2,
                       let t = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                       let f = parseLambda(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                        pattern = pattern.off(t, f)
                    } else {
                        print("[CodeParser] 'off' could not parse args: \(arg)")
                    }
                }

            case "jux":
                if let arg = token.arg,
                   let f = parseLambda(arg.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    pattern = pattern.jux(f)
                } else {
                    print("[CodeParser] 'jux' could not parse lambda arg")
                }

            case "struct":
                if let arg = token.arg {
                    let t = unquote(arg.trimmingCharacters(in: .whitespaces))
                    pattern = pattern.structGate(t)
                }

            // ── Fase 4: Distortion / Saturation ──────────────────────────────

            case "shape":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.shape(v) }
                    else                 { pattern = pattern.shape(unquote(t)) }
                }

            case "distort":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.distort(v) }
                    else                 { pattern = pattern.distort(unquote(t)) }
                }

            // ── Fase 4: Bitcrusher ────────────────────────────────────────────

            case "crush":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = Double(t) { pattern = pattern.crush(v) }
                    else                 { pattern = pattern.crush(unquote(t)) }
                }

            // ── Fase 4: Vowel formant filter ──────────────────────────────────

            case "vowel":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    pattern = pattern.vowel(unquote(t))
                }

            // ── Fase 4: Granular — chop / striate ────────────────────────────

            case "chop":
                if let arg = token.arg,
                   let n = Int(arg.trimmingCharacters(in: .whitespaces)) {
                    pattern = pattern.chop(n)
                }

            case "striate":
                if let arg = token.arg,
                   let n = Int(arg.trimmingCharacters(in: .whitespaces)) {
                    pattern = pattern.striate(n)
                }

            // ── Fase 4: chorus / phaser — not implemented ─────────────────────
            // See COMPATIBILITY.md for rationale.

            case "chorus":
                print("[CodeParser] 'chorus' is not implemented in Fase 4 — skipping. See COMPATIBILITY.md")

            case "phaser":
                print("[CodeParser] 'phaser' is not implemented in Fase 4 — skipping. See COMPATIBILITY.md")

            default:
                break
            }
        }

        return pattern
    }

    // MARK: - Lambda parser
    // Parses: `x => x.method(args)` or `x => x.m1(a).m2(b)...`
    // Supports only methods already known to CodeParser (applied to the input pattern).
    // Returns nil if the lambda cannot be parsed.

    private func parseLambda(_ s: String) -> ((ControlPattern) -> ControlPattern)? {
        // Expect: identifier WS* => WS* identifier(.method chain)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the arrow =>
        guard let arrowRange = trimmed.range(of: "=>") else { return nil }

        let paramPart = trimmed[..<arrowRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyPart  = trimmed[arrowRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate param is a simple identifier
        guard !paramPart.isEmpty,
              paramPart.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        let paramName = paramPart

        // Body must start with `paramName.` or just be `paramName`
        var chainStr = bodyPart
        if chainStr.hasPrefix(paramName + ".") {
            chainStr = String(chainStr.dropFirst(paramName.count + 1))
        } else if chainStr == paramName {
            // identity lambda: x => x
            return { $0 }
        } else {
            return nil
        }

        // Parse the method chain on chainStr and turn it into a ControlPattern transform
        guard let tokens = try? parseMethodChain("dummy." + chainStr) else { return nil }
        // Drop the dummy token
        let methodTokens = tokens.dropFirst()

        // Build a transform function
        return { (pat: ControlPattern) -> ControlPattern in
            var result = pat
            for token in methodTokens {
                switch token.name {
                case "slow":
                    if let arg = token.arg, let v = Double(arg.trimmingCharacters(in: .whitespaces)) {
                        result = result.slow(v)
                    }
                case "fast":
                    if let arg = token.arg, let v = Double(arg.trimmingCharacters(in: .whitespaces)) {
                        result = result.fast(v)
                    }
                case "gain":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = Double(t) { result = result.gain(v) }
                        else                 { result = result.gain(unquote(t)) }
                    }
                case "room":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = Double(t) { result = result.room(v) }
                        else                 { result = result.room(unquote(t)) }
                    }
                case "cutoff":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = Double(t) { result = result.cutoff(v) }
                        else                 { result = result.cutoff(unquote(t)) }
                    }
                case "pan":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = Double(t) { result = result.pan(v) }
                        else                 { result = result.pan(unquote(t)) }
                    }
                case "delay":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = Double(t) { result = result.delay(v) }
                    }
                case "rev":
                    result = result.rev
                case "ply":
                    if let arg = token.arg, let v = Int(arg.trimmingCharacters(in: .whitespaces)) {
                        result = result.ply(v)
                    }
                default:
                    print("[CodeParser] Lambda: unknown method '\(token.name)' — skipping")
                }
            }
            return result
        }
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

    private func extractSimpleArg(_ code: String, fn: String) -> String? {
        let prefix = "\(fn)("
        guard code.hasPrefix(prefix) else { return nil }
        let rest = String(code.dropFirst(prefix.count))
        guard let paren = rest.firstIndex(of: ")") else { return nil }
        return String(rest[..<paren])
    }

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
