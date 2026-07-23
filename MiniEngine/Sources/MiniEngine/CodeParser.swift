// ---------------------------------------------------------------------------
// CodeParser — parses the top-level Strudel-like editor code into a ControlPattern.
//
// Supports:
//   setcps(x) / setcpm(x)  — top-level tempo statement (applied to scheduler)
//   stack(expr, expr, ...)
//   $: expr                 — top-level parallel patterns (Strudel $: syntax).
//                             Lines starting with $: define one pattern each;
//                             they are stacked into an implicit stack(). Muted
//                             patterns (_$:) are silently ignored.
//                             Multi-line: a pattern continues until the next
//                             line beginning with $: or _$: (simple join with \n).
//   s("mini") .note("mini") .slow(n) .fast(n) .gain(n|"mini") .room(n) .cutoff(n)
//   .pan(n|"mini")  — stereo position 0..1
//   .delay(n) .delaytime(n) .delayfeedback(n)  — echo effect
//   .euclid(k,n) / .euclid(k,n,rot)  — Euclidean rhythm
//   n("mini") + .scale("Root:name")  — scale-based melody
//   .bank("name")  — sample bank prefix; effective key = "bank_sampleName"
//   .dec(x) .att(x) .sus(x) .rel(x)  — ADSR short aliases
//   // line comments (stripped before parsing)
//
// Number literals: .4 (leading dot) is accepted as 0.4 everywhere.
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
    /// Manifest URL strings from samples('...') calls (may be "github:user/repo" or https://).
    /// Empty if no samples() statement in code. The engine registers these before playing.
    public let manifestURLs: [String]

    public init(pattern: ControlPattern, cps: Double?, manifestURLs: [String] = []) {
        self.pattern = pattern
        self.cps = cps
        self.manifestURLs = manifestURLs
    }
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
    /// Also extracts samples('...') statements as manifestURLs in the result.
    public func parseWithTempo(_ rawCode: String) throws -> ParseResult {
        let lines = rawCode.components(separatedBy: .newlines)

        var cps: Double? = nil
        var manifestURLs: [String] = []
        var patternLines: [String] = []

        // First pass: handle setcps/setcpm/samples() and collect remaining lines
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

            // Detect samples('url') or samples("url") as standalone statement.
            // Strudel convention: samples('github:tidalcycles/dirt-samples') or
            // samples('https://bucket.../strudel.json'). May appear multiple times.
            // The URL argument is the first argument (second form with base URL not supported here).
            if trimmed.hasPrefix("samples(") {
                if let inner = extractSimpleArg(trimmed, fn: "samples") {
                    let urlStr = unquote(inner.trimmingCharacters(in: .whitespaces))
                    if !urlStr.isEmpty {
                        manifestURLs.append(urlStr)
                    }
                }
                continue
            }

            patternLines.append(stripped)
        }

        // Detect $: top-level parallel pattern syntax.
        // Lines starting with "$:" each define one pattern; "_$:" lines are muted (ignored).
        // A pattern body may span multiple physical lines until the next $:/_$: line.
        // We split the collected lines at each $:/_$: boundary and join continuation lines.
        let hasDollarColon = patternLines.contains { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.hasPrefix("$:") || t.hasPrefix("_$:")
        }

        let code: String
        if hasDollarColon {
            // Collect $: segments (ignore _$: muted ones)
            var segments: [String] = []
            var current: String? = nil

            for line in patternLines {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("_$:") {
                    // Muted — flush current if any, skip this one
                    if let seg = current?.trimmingCharacters(in: .whitespacesAndNewlines), !seg.isEmpty {
                        segments.append(seg)
                    }
                    current = nil
                } else if t.hasPrefix("$:") {
                    // New active pattern — flush current if any
                    if let seg = current?.trimmingCharacters(in: .whitespacesAndNewlines), !seg.isEmpty {
                        segments.append(seg)
                    }
                    let body = String(t.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    current = body
                } else {
                    // Continuation line — append to current segment
                    if current != nil {
                        current! += "\n" + line
                    } else {
                        // Line before any $: — treat as non-$: code (fallback)
                        current = line
                    }
                }
            }
            // Flush last segment
            if let seg = current?.trimmingCharacters(in: .whitespacesAndNewlines), !seg.isEmpty {
                segments.append(seg)
            }

            if segments.isEmpty {
                return ParseResult(pattern: .silence, cps: cps, manifestURLs: manifestURLs)
            }
            if segments.count == 1 {
                // Single active pattern — parse normally (parseLayerOrStack tags _layer=0)
                let pat = try parseLayerOrStack(segments[0])
                return ParseResult(pattern: pat, cps: cps, manifestURLs: manifestURLs)
            }
            // Multiple $: segments → implicit stack; each segment is a distinct layer.
            // Re-inject _layer with the outer segment index (overriding the inner 0).
            let layers = try segments.enumerated().map { (idx, seg) -> ControlPattern in
                let pat = try parseLayerOrStack(seg)
                // Overwrite _layer using map to avoid structural expansion (see
                // the comment in parseLayerOrStack for why we use map not withControl).
                let layerVal = ControlValue.double(Double(idx))
                return pat.map { var v = $0; v["_layer"] = layerVal; return v }
            }
            return ParseResult(pattern: stackCP(layers), cps: cps, manifestURLs: manifestURLs)
        }

        // Normal (non-$:) path
        code = patternLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !code.isEmpty else {
            return ParseResult(pattern: .silence, cps: cps, manifestURLs: manifestURLs)
        }

        let pattern = try parseLayerOrStack(code)
        return ParseResult(pattern: pattern, cps: cps, manifestURLs: manifestURLs)
    }

    /// Parse a code string that may be a stack(...) call or a single layer expression.
    /// Each branch of a stack gets a `_layer` control field (double index, 0-based)
    /// so PatternScheduler can key each branch into its own effect chain + voice pool.
    /// A plain (non-stack) layer gets `_layer = 0`.
    ///
    /// Implementation note: `_layer` is injected via `.map` (not `.withControl`) to
    /// avoid the appLeft structural expansion that `.withControl(.pure(...))` would
    /// produce when base haps have whole-spans longer than 1 cycle (e.g. slow(4)).
    private func parseLayerOrStack(_ code: String) throws -> ControlPattern {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("stack(") {
            let inner = try extractArgs(trimmed, function: "stack")
            let parts = splitTopLevelCommas(inner)
            let layers = try parts.enumerated().map { (idx, part) -> ControlPattern in
                let pat = try parseLayerExpr(part.trimmingCharacters(in: .whitespacesAndNewlines))
                // Inject _layer by mapping over hap values — no structural change.
                let layerVal = ControlValue.double(Double(idx))
                return pat.map { var v = $0; v["_layer"] = layerVal; return v }
            }
            return stackCP(layers)
        }
        // Single layer — tag as layer 0
        let pat = try parseLayerExpr(trimmed)
        return pat.map { var v = $0; v["_layer"] = .double(0.0); return v }
    }

    // MARK: - Signal expression parser
    //
    // Parses a signal expression used as argument to control methods:
    //   "sine"                     → sine
    //   "sine.range(200, 2000)"    → sine.range(200, 2000)
    //   "saw.slow(4)"              → saw.slow(4)
    //   "saw.slow(4).range(0.2, 0.8)"
    //   "rand.range(0, 1)"
    //   "perlin.range(0.2, 0.8)"
    //   "sine.slow(2).segment(8)"
    //
    // Supported signal names: sine, saw, isaw, tri, square, cosine, rand, perlin
    // Supported chain methods: .range(min, max), .rangex(min, max), .slow(n), .fast(n),
    //                          .segment(n), .seg(n)
    //
    // Note: signal() with an external Swift callback has no editor syntax.
    // That API is Swift-only (for EEG integration).

    private let signalNames: Set<String> = ["sine", "saw", "isaw", "tri", "square", "cosine", "rand", "perlin"]

    /// Parse a string that looks like a signal expression.
    /// Returns nil if the string is not a signal expression (so callers can fall back to number/mini-notation).
    private func parseSignalExpression(_ s: String) -> Pattern<Double>? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Must start with a known signal name
        let base: Pattern<Double>
        var rest: String

        if trimmed.hasPrefix("sine") {
            base = sine
            rest = String(trimmed.dropFirst("sine".count))
        } else if trimmed.hasPrefix("isaw") {
            base = isaw
            rest = String(trimmed.dropFirst("isaw".count))
        } else if trimmed.hasPrefix("saw") {
            base = saw
            rest = String(trimmed.dropFirst("saw".count))
        } else if trimmed.hasPrefix("tri") {
            base = tri
            rest = String(trimmed.dropFirst("tri".count))
        } else if trimmed.hasPrefix("square") {
            base = square
            rest = String(trimmed.dropFirst("square".count))
        } else if trimmed.hasPrefix("cosine") {
            base = cosine
            rest = String(trimmed.dropFirst("cosine".count))
        } else if trimmed.hasPrefix("rand") {
            base = rand
            rest = String(trimmed.dropFirst("rand".count))
        } else if trimmed.hasPrefix("perlin") {
            base = perlin
            rest = String(trimmed.dropFirst("perlin".count))
        } else {
            return nil
        }

        // Apply chained methods
        var current = base
        rest = rest.trimmingCharacters(in: .whitespaces)
        while rest.hasPrefix(".") {
            rest = String(rest.dropFirst()) // drop the leading "."
            // Parse method name
            var methodName = ""
            while let ch = rest.first, ch.isLetter || ch.isNumber || ch == "_" {
                methodName.append(ch)
                rest = String(rest.dropFirst())
            }
            rest = rest.trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("(") else { break }
            rest = String(rest.dropFirst()) // drop "("
            // Extract args up to matching ")"
            if let (argsStr, remaining) = extractParenContentSimple(rest) {
                rest = remaining.trimmingCharacters(in: .whitespaces)
                let argParts = argsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                switch methodName {
                case "range":
                    if argParts.count == 2,
                       let a = parseDouble(argParts[0]),
                       let b = parseDouble(argParts[1]) {
                        current = current.range(a, b)
                    }
                case "rangex":
                    if argParts.count == 2,
                       let a = parseDouble(argParts[0]),
                       let b = parseDouble(argParts[1]) {
                        current = current.rangex(a, b)
                    }
                case "slow":
                    if argParts.count == 1, let f = parseDouble(argParts[0]) {
                        current = current.slow(f)
                    }
                case "fast":
                    if argParts.count == 1, let f = parseDouble(argParts[0]) {
                        current = current.fast(f)
                    }
                case "segment", "seg":
                    if argParts.count == 1, let n = Int(argParts[0]) {
                        current = current.segment(n)
                    }
                default:
                    print("[CodeParser] Signal chain: unknown method '\(methodName)' — skipping")
                }
            } else {
                break
            }
        }
        return current
    }

    /// Simple paren content extractor: extracts content up to matching ')'.
    /// Returns (content, rest) or nil on parse error.
    private func extractParenContentSimple(_ s: String) -> (String, String)? {
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
        return nil
    }

    // MARK: - Comment stripping

    private func stripLineCommentsFromLine(_ line: String) -> String {
        var result: [Character] = []
        var inDoubleQuote = false
        var inSingleQuote = false
        var i = line.startIndex

        while i < line.endIndex {
            let ch = line[i]
            let next = line.index(after: i)

            if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                result.append(ch)
                i = next
                continue
            }

            if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                result.append(ch)
                i = next
                continue
            }

            let inString = inDoubleQuote || inSingleQuote
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
        "chorus", "phaser",
        // Fase 5: bank + ADSR aliases
        "bank",
        "dec", "att", "sus", "rel",
        // P0-4: orbit
        "orbit",
        // P0-2: Señales continuas — names used as top-level expressions in signal args
        "sine", "saw", "isaw", "tri", "square", "cosine", "rand", "perlin",
        "range", "rangex", "segment", "seg",
        // P1-5: duck sidechain
        "duck", "duckattack", "duckdepth",
        // P1-6: filter envelope + lpq/hpq
        "lpenv", "hpenv", "lpq", "hpq",
        // P1-7: add()
        "add",
        // P1-8: postgain, size, roomsize, fb, dt
        "postgain", "size", "roomsize", "fb", "dt",
        // P2: pattern functions
        "arp",
        "superimpose",
        "stut", "echo",
        "iter", "iterBack",
        "chunk",
        "palindrome",
        "hurry",
        "swingBy", "swing",
        "slice", "loopAt"
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
                   let factor = parseDouble(arg.trimmingCharacters(in: .whitespaces)) {
                    pattern = pattern.slow(factor)
                }

            case "fast":
                if let arg = token.arg,
                   let factor = parseDouble(arg.trimmingCharacters(in: .whitespaces)) {
                    pattern = pattern.fast(factor)
                }

            // ── Audio controls ───────────────────────────────────────────────
            case "gain":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t)       { pattern = pattern.gain(v) }
                    else if let sig = parseSignalExpression(t) { pattern = pattern.gain(sig) }
                    else                            { pattern = pattern.gain(unquote(t)) }
                }

            case "room":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t)       { pattern = pattern.room(v) }
                    else if let sig = parseSignalExpression(t) { pattern = pattern.room(sig) }
                    else                            { pattern = pattern.room(unquote(t)) }
                }

            case "cutoff":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t)       { pattern = pattern.cutoff(v) }
                    else if let sig = parseSignalExpression(t) { pattern = pattern.cutoff(sig) }
                    else                            { pattern = pattern.cutoff(unquote(t)) }
                }

            case "pan":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t)       { pattern = pattern.pan(v) }
                    else if let sig = parseSignalExpression(t) { pattern = pattern.pan(sig) }
                    else                            { pattern = pattern.pan(unquote(t)) }
                }

            case "delay":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.delay(v) }
                    else                      { pattern = pattern.delay(unquote(t)) }
                }

            case "delaytime":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.delaytime(v) }
                    else                      { pattern = pattern.delaytime(unquote(t)) }
                }

            case "delayfeedback":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.delayfeedback(v) }
                    else                      { pattern = pattern.delayfeedback(unquote(t)) }
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
                    if let v = parseDouble(t) { pattern = pattern.attack(v) }
                    else                      { pattern = pattern.attack(unquote(t)) }
                }

            case "decay":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.decay(v) }
                    else                      { pattern = pattern.decay(unquote(t)) }
                }

            case "sustain":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.sustain(v) }
                    else                      { pattern = pattern.sustain(unquote(t)) }
                }

            case "release":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.release(v) }
                    else                      { pattern = pattern.release(unquote(t)) }
                }

            // ── Fase 3: Filters ───────────────────────────────────────────────
            case "lpf":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t)       { pattern = pattern.lpf(v) }
                    else if let sig = parseSignalExpression(t) { pattern = pattern.lpf(sig) }
                    else                            { pattern = pattern.lpf(unquote(t)) }
                }

            case "hpf":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t)       { pattern = pattern.hpf(v) }
                    else if let sig = parseSignalExpression(t) { pattern = pattern.hpf(sig) }
                    else                            { pattern = pattern.hpf(unquote(t)) }
                }

            case "resonance":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t)       { pattern = pattern.resonance(v) }
                    else if let sig = parseSignalExpression(t) { pattern = pattern.resonance(sig) }
                    else                            { pattern = pattern.resonance(unquote(t)) }
                }

            // ── Fase 3: speed ─────────────────────────────────────────────────
            case "speed":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t)       { pattern = pattern.speed(v) }
                    else if let sig = parseSignalExpression(t) { pattern = pattern.speed(sig) }
                    else                            { pattern = pattern.speed(unquote(t)) }
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
                       let t = parseDouble(parts[0].trimmingCharacters(in: .whitespaces)),
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
                    if let v = parseDouble(t) { pattern = pattern.shape(v) }
                    else                      { pattern = pattern.shape(unquote(t)) }
                }

            case "distort":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.distort(v) }
                    else                      { pattern = pattern.distort(unquote(t)) }
                }

            // ── Fase 4: Bitcrusher ────────────────────────────────────────────

            case "crush":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.crush(v) }
                    else                      { pattern = pattern.crush(unquote(t)) }
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

            // ── Fase 5: bank selection ─────────────────────────────────────────

            case "bank":
                if let arg = token.arg {
                    let t = unquote(arg.trimmingCharacters(in: .whitespaces))
                    pattern = pattern.bank(t)
                }

            // ── Fase 5: ADSR short aliases ────────────────────────────────────

            // ── P0-4: orbit ───────────────────────────────────────────────────

            case "orbit":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.orbit(v) }
                    else                      { pattern = pattern.orbit(unquote(t)) }
                }

            case "dec":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.dec(v) }
                    else                      { pattern = pattern.dec(unquote(t)) }
                }

            case "att":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.att(v) }
                    else                      { pattern = pattern.att(unquote(t)) }
                }

            case "sus":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.sus(v) }
                    else                      { pattern = pattern.sus(unquote(t)) }
                }

            case "rel":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.rel(v) }
                    else                      { pattern = pattern.rel(unquote(t)) }
                }

            // ── P1-5: duck sidechain ───────────────────────────────────────
            case "duck":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.duck(v) }
                    else                      { pattern = pattern.duck(unquote(t)) }
                }

            case "duckattack":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.duckattack(v) }
                    else                      { pattern = pattern.duckattack(unquote(t)) }
                }

            case "duckdepth":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.duckdepth(v) }
                    else                      { pattern = pattern.duckdepth(unquote(t)) }
                }

            // ── P1-6: filter envelope ──────────────────────────────────────
            case "lpenv":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.lpenv(v) }
                    else                      { pattern = pattern.lpenv(unquote(t)) }
                }

            case "hpenv":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.hpenv(v) }
                    else                      { pattern = pattern.hpenv(unquote(t)) }
                }

            case "lpq":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t)       { pattern = pattern.lpq(v) }
                    else if let sig = parseSignalExpression(t) { pattern = pattern.resonance(sig) }
                    else                            { pattern = pattern.lpq(unquote(t)) }
                }

            case "hpq":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t)       { pattern = pattern.hpq(v) }
                    else if let sig = parseSignalExpression(t) { pattern = pattern.resonance(sig) }
                    else                            { pattern = pattern.hpq(unquote(t)) }
                }

            // ── P1-7: add() ────────────────────────────────────────────────
            case "add":
                // Argument: note("...") or n("...") — a sub-pattern call
                // We parse the argument string as a ControlPattern.
                // Supported forms: add(note("...")), add(n("...")), add(bare_number)
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let addPat = parseAddArgument(t) {
                        pattern = pattern.add(addPat)
                    } else {
                        print("[CodeParser] 'add' could not parse argument: \(arg)")
                    }
                }

            // ── P1-8: postgain, size, roomsize, fb, dt ─────────────────────
            case "postgain":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.postgain(v) }
                    else                      { pattern = pattern.postgain(unquote(t)) }
                }

            case "size", "roomsize":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.size(v) }
                    else                      { pattern = pattern.size(unquote(t)) }
                }

            case "fb":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.fb(v) }
                    else                      { pattern = pattern.fb(unquote(t)) }
                }

            case "dt":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.dt(v) }
                    else                      { pattern = pattern.dt(unquote(t)) }
                }

            // ── P2: arp ────────────────────────────────────────────────────
            // arp("up"|"down"|"updown"|"downup") — arpeggiate chord events.
            case "arp":
                if let arg = token.arg {
                    let mode = unquote(arg.trimmingCharacters(in: .whitespaces))
                    pattern = pattern.arp(mode)
                }

            // ── P2: superimpose(f) ─────────────────────────────────────────
            // superimpose(x => x.method(args)) = stack(self, f(self))
            case "superimpose":
                if let arg = token.arg,
                   let f = parseLambda(arg.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    pattern = pattern.superimpose(f)
                } else {
                    print("[CodeParser] 'superimpose' could not parse lambda: \(token.arg ?? "nil")")
                }

            // ── P2: stut(n, feedback, time) ────────────────────────────────
            case "stut":
                if let arg = token.arg {
                    let parts = splitTopLevelCommas(arg)
                    if parts.count == 3,
                       let n  = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       let fb = parseDouble(parts[1].trimmingCharacters(in: .whitespaces)),
                       let t  = parseDouble(parts[2].trimmingCharacters(in: .whitespaces)) {
                        pattern = pattern.stut(n, fb, t)
                    } else {
                        print("[CodeParser] 'stut' requires 3 args (n, feedback, time): \(arg)")
                    }
                }

            // ── P2: echo(n, time, feedback) ────────────────────────────────
            case "echo":
                if let arg = token.arg {
                    let parts = splitTopLevelCommas(arg)
                    if parts.count == 3,
                       let n  = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       let t  = parseDouble(parts[1].trimmingCharacters(in: .whitespaces)),
                       let fb = parseDouble(parts[2].trimmingCharacters(in: .whitespaces)) {
                        pattern = pattern.echo(n, t, fb)
                    } else {
                        print("[CodeParser] 'echo' requires 3 args (n, time, feedback): \(arg)")
                    }
                }

            // ── P2: iter(n) / iterBack(n) ──────────────────────────────────
            case "iter":
                if let arg = token.arg,
                   let n = Int(arg.trimmingCharacters(in: .whitespaces)) {
                    pattern = pattern.iter(n)
                }

            case "iterBack":
                if let arg = token.arg,
                   let n = Int(arg.trimmingCharacters(in: .whitespaces)) {
                    pattern = pattern.iterBack(n)
                }

            // ── P2: chunk(n, f) ────────────────────────────────────────────
            case "chunk":
                if let arg = token.arg {
                    let parts = splitTopLevelCommas(arg)
                    if parts.count == 2,
                       let n = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       let f = parseLambda(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                        pattern = pattern.chunk(n, f)
                    } else {
                        print("[CodeParser] 'chunk' could not parse args: \(arg)")
                    }
                }

            // ── P2: palindrome ─────────────────────────────────────────────
            // palindrome has no arguments (used as .palindrome or .palindrome())
            case "palindrome":
                pattern = pattern.palindrome

            // ── P2: hurry(n) ───────────────────────────────────────────────
            case "hurry":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.hurry(v) }
                }

            // ── P2: swingBy(amount, period) / swing(period) ───────────────
            case "swingBy":
                if let arg = token.arg {
                    let parts = splitTopLevelCommas(arg)
                    if parts.count == 2,
                       let amount = parseDouble(parts[0].trimmingCharacters(in: .whitespaces)),
                       let period = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                        pattern = pattern.swingBy(amount, period)
                    } else {
                        print("[CodeParser] 'swingBy' requires 2 args (amount, period): \(arg)")
                    }
                }

            case "swing":
                if let arg = token.arg,
                   let period = Int(arg.trimmingCharacters(in: .whitespaces)) {
                    pattern = pattern.swing(period)
                }

            // ── P2: slice(n, indexPattern) ─────────────────────────────────
            case "slice":
                if let arg = token.arg {
                    let parts = splitTopLevelCommas(arg)
                    if parts.count == 2,
                       let n = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                        let idx = unquote(parts[1].trimmingCharacters(in: .whitespaces))
                        pattern = pattern.slice(n, idx)
                    } else {
                        print("[CodeParser] 'slice' requires 2 args (n, indexPattern): \(arg)")
                    }
                }

            // ── P2: loopAt(n) ──────────────────────────────────────────────
            case "loopAt":
                if let arg = token.arg {
                    let t = arg.trimmingCharacters(in: .whitespaces)
                    if let v = parseDouble(t) { pattern = pattern.loopAt(v) }
                    else if let n = Int(t)    { pattern = pattern.loopAt(n) }
                }

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
                    if let arg = token.arg, let v = self.parseDouble(arg.trimmingCharacters(in: .whitespaces)) {
                        result = result.slow(v)
                    }
                case "fast":
                    if let arg = token.arg, let v = self.parseDouble(arg.trimmingCharacters(in: .whitespaces)) {
                        result = result.fast(v)
                    }
                case "gain":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = self.parseDouble(t) { result = result.gain(v) }
                        else                           { result = result.gain(self.unquote(t)) }
                    }
                case "room":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = self.parseDouble(t) { result = result.room(v) }
                        else                           { result = result.room(self.unquote(t)) }
                    }
                case "cutoff":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = self.parseDouble(t) { result = result.cutoff(v) }
                        else                           { result = result.cutoff(self.unquote(t)) }
                    }
                case "pan":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = self.parseDouble(t) { result = result.pan(v) }
                        else                           { result = result.pan(self.unquote(t)) }
                    }
                case "delay":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = self.parseDouble(t) { result = result.delay(v) }
                    }
                case "rev":
                    result = result.rev
                case "ply":
                    if let arg = token.arg, let v = Int(arg.trimmingCharacters(in: .whitespaces)) {
                        result = result.ply(v)
                    }
                case "hurry":
                    if let arg = token.arg, let v = self.parseDouble(arg.trimmingCharacters(in: .whitespaces)) {
                        result = result.hurry(v)
                    }
                case "iter":
                    if let arg = token.arg, let v = Int(arg.trimmingCharacters(in: .whitespaces)) {
                        result = result.iter(v)
                    }
                case "palindrome":
                    result = result.palindrome
                case "lpf":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = self.parseDouble(t) { result = result.lpf(v) }
                    }
                case "hpf":
                    if let arg = token.arg {
                        let t = arg.trimmingCharacters(in: .whitespaces)
                        if let v = self.parseDouble(t) { result = result.hpf(v) }
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

    // MARK: - add() argument parser
    //
    // Parses the argument to .add(...):
    //   add(note("12"))       → notePattern("12")
    //   add(note("[0,.12]"))  → notePattern("[0,.12]")
    //   add(n("7"))           → nPattern("7")
    //   add(12)               → pure({"note": 12}) — bare number treated as note offset
    //
    // Returns nil if the argument cannot be parsed.

    private func parseAddArgument(_ arg: String) -> ControlPattern? {
        let t = arg.trimmingCharacters(in: .whitespacesAndNewlines)

        // note("...") or note('...')
        if t.hasPrefix("note(") {
            if let inner = extractSimpleArg(t, fn: "note") {
                let s = unquote(inner.trimmingCharacters(in: .whitespaces))
                return notePattern(s)
            }
        }

        // n("...")
        if t.hasPrefix("n(") {
            if let inner = extractSimpleArg(t, fn: "n") {
                let s = unquote(inner.trimmingCharacters(in: .whitespaces))
                return nPattern(s)
            }
        }

        // Bare number (e.g. add(12) → add 12 to note field)
        if let v = parseDouble(t) {
            return .pure(["note": .double(v)])
        }

        return nil
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
        // Strip matching outer quotes (single or double)
        if r.hasPrefix("\"") && r.hasSuffix("\"") && r.count >= 2 {
            return String(r.dropFirst().dropLast())
        }
        if r.hasPrefix("'") && r.hasSuffix("'") && r.count >= 2 {
            return String(r.dropFirst().dropLast())
        }
        // Legacy: strip individually (backward compat)
        if r.hasPrefix("\"") { r = String(r.dropFirst()) }
        if r.hasSuffix("\"") { r = String(r.dropLast()) }
        return r
    }

    /// Parse a double literal, supporting Strudel's shorthand leading-dot notation.
    /// ".4" → 0.4, ".25" → 0.25. Standard "0.4" and "-0.4" also work.
    private func parseDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(".") || t.hasPrefix("-.") {
            // Prepend "0" to make it valid for Double()
            let prefix = t.hasPrefix("-") ? "-0" : "0"
            let rest   = t.hasPrefix("-") ? String(t.dropFirst()) : t
            return Double(prefix + rest)
        }
        return Double(t)
    }
}
