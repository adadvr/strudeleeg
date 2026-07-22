import Foundation

// ---------------------------------------------------------------------------
// MiniNotationParser — F1
// Clean-room implementation based solely on strudel.cc/learn public docs.
// Supports: stack, s, note, slow, fast, <...>, [...], sequences, ~, gain, room, cutoff
// ---------------------------------------------------------------------------

// MARK: - Error

public enum ParseError: Error, LocalizedError {
    case unsupported(String)
    case unknownSample(String)
    case syntaxError(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let fn):
            return "Función no soportada en la demo: \(fn)"
        case .unknownSample(let name):
            return "Sample desconocido en la demo: \(name)"
        case .syntaxError(let msg):
            return "Error de sintaxis: \(msg)"
        }
    }
}

// MARK: - Data model

/// One discrete event within a cycle (fractional 0..<1 time range).
public struct PatternEvent {
    /// Onset within the cycle, fractional [0, 1)
    public let cycleOnset: Double
    /// Duration within the cycle, fractional (0, 1]
    public let cycleDuration: Double
    /// MIDI note number, if any (e.g. note("c4") → 60)
    public let midiNote: Int?

    public init(cycleOnset: Double, cycleDuration: Double, midiNote: Int?) {
        self.cycleOnset = cycleOnset
        self.cycleDuration = cycleDuration
        self.midiNote = midiNote
    }
}

/// One fully-parsed layer coming out of the parser.
public struct Layer {
    /// Sample name ("pad", "bell", etc.)
    public let sample: String
    /// Events per cycle (one entry per cycle position in the base pattern).
    /// For alternation (<...>) each cycle index rotates through the alternatives.
    public let events: [PatternEvent]
    /// If the pattern uses alternation, events are only one slot — caller must
    /// call eventsForCycle(_:) instead.
    public let isAlternation: Bool
    public let alternatives: [[PatternEvent]]   // non-empty only when isAlternation == true

    /// Time-stretch factor (slow(n) → n; fast(n) → 1/n)
    public let slowFactor: Double   // > 1 = slower, < 1 = faster

    // Effects — stored now, applied in F2
    public let gain: Double?
    public let room: Double?
    public let cutoff: Double?

    /// Returns the events that fire in a given cycle (handles alternation).
    public func eventsForCycle(_ cycleIndex: Int) -> [PatternEvent] {
        if isAlternation {
            guard !alternatives.isEmpty else { return [] }
            return alternatives[cycleIndex % alternatives.count]
        }
        return events
    }
}

// MARK: - Known samples

private let knownSamples: Set<String> = ["pad", "bell"]

// MARK: - Mini-notation string parser

/// Parses the content of quoted strings like "a b [c d] <e f>".
private struct TokenParser {

    // ---------------------------------------------------------------------------
    // Internal atoms after tokenising
    // ---------------------------------------------------------------------------
    indirect enum Atom {
        case name(String)              // a word token (note name or sample)
        case silence                   // ~
        case group([Atom])             // [a b]
        case alternation([[Atom]])     // <a b c>
    }

    // ---------------------------------------------------------------------------
    // Tokenise + build atoms from the mini-notation string
    // ---------------------------------------------------------------------------

    static func parse(_ input: String) throws -> [Atom] {
        var chars = ArraySlice(input.unicodeScalars)
        return try parseSequence(&chars, terminators: [])
    }

    private static func parseSequence(
        _ chars: inout ArraySlice<Unicode.Scalar>,
        terminators: Set<Unicode.Scalar>
    ) throws -> [Atom] {
        var atoms: [Atom] = []
        while let ch = chars.first {
            if terminators.contains(ch) { break }
            switch ch {
            case " ", "\t", "\n", "\r":
                chars = chars.dropFirst()
            case "~":
                chars = chars.dropFirst()
                atoms.append(.silence)
            case "[":
                chars = chars.dropFirst()
                let sub = try parseSequence(&chars, terminators: ["]"])
                if chars.first == "]" { chars = chars.dropFirst() }
                atoms.append(.group(sub))
            case "]":
                // consumed by caller
                break
            case "<":
                chars = chars.dropFirst()
                // Inside <...>, each whitespace-separated atom is one alternative.
                // Collect all inner atoms, then each atom becomes its own alternative.
                let innerAtoms = try parseSequence(&chars, terminators: [">"])
                if chars.first == ">" { chars = chars.dropFirst() }
                // Each inner atom is one alternative (one value per cycle rotation)
                let alts: [[Atom]] = innerAtoms.map { [$0] }
                atoms.append(.alternation(alts))
            case ">":
                break
            default:
                // collect a word token
                var word = ""
                while let c = chars.first, !" \t\n\r[]<>".unicodeScalars.contains(c) {
                    word.append(Character(c))
                    chars = chars.dropFirst()
                }
                atoms.append(.name(word))
            }
            // If we hit a terminator-char without consuming it, stop
            if let ch = chars.first, terminators.contains(ch) { break }
        }
        return atoms
    }

    // ---------------------------------------------------------------------------
    // Convert atoms → PatternEvents, given a time window [onset, onset+duration)
    // ---------------------------------------------------------------------------

    static func expand(
        atoms: [Atom],
        onset: Double,
        duration: Double,
        noteSource: (String) -> Int?   // maps note names to MIDI
    ) -> [[PatternEvent]] {
        // atoms at this level are divided equally
        guard !atoms.isEmpty else { return [] }

        // check for alternation at top level
        if atoms.count == 1, case .alternation(let alts) = atoms[0] {
            // Return one group per alternative
            return alts.map { altAtoms in
                expandFlat(atoms: altAtoms, onset: onset, duration: duration, noteSource: noteSource)
            }
        }

        return [expandFlat(atoms: atoms, onset: onset, duration: duration, noteSource: noteSource)]
    }

    /// Expand atoms into a flat list of events at this time window.
    static func expandFlat(
        atoms: [Atom],
        onset: Double,
        duration: Double,
        noteSource: (String) -> Int?
    ) -> [PatternEvent] {
        let step = duration / Double(atoms.count)
        var events: [PatternEvent] = []
        for (i, atom) in atoms.enumerated() {
            let atomOnset = onset + Double(i) * step
            switch atom {
            case .silence:
                break
            case .name(let word):
                let midi = noteSource(word)
                events.append(PatternEvent(cycleOnset: atomOnset, cycleDuration: step, midiNote: midi))
            case .group(let subAtoms):
                let sub = expandFlat(atoms: subAtoms, onset: atomOnset, duration: step, noteSource: noteSource)
                events.append(contentsOf: sub)
            case .alternation(let alts):
                // Inside a sequence, alternation acts as a single step that rotates per cycle.
                // We can't resolve cycle index here, so we embed a placeholder.
                // Strategy: expand each alt separately and caller must handle.
                // For now we just pick the first (will be overridden by isAlternation path).
                if let first = alts.first {
                    let sub = expandFlat(atoms: first, onset: atomOnset, duration: step, noteSource: noteSource)
                    events.append(contentsOf: sub)
                }
            }
        }
        return events
    }
}

// MARK: - Top-level parser

/// Parses a full Strudel-subset code string into layers.
public struct MiniNotationParser {

    public init() {}

    public func parse(_ code: String) throws -> [Layer] {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        // Expect stack(...) or a single layer
        if trimmed.hasPrefix("stack(") {
            let inner = try extractArgs(from: trimmed, function: "stack")
            return try parseLayerList(inner)
        } else {
            // Single layer expression
            return [try parseLayer(trimmed)]
        }
    }

    // MARK: - Private helpers

    /// Splits the comma-separated top-level args of a function call.
    private func extractArgs(from code: String, function fn: String) throws -> String {
        let prefix = "\(fn)("
        guard code.hasPrefix(prefix) else {
            throw ParseError.syntaxError("Expected \(fn)(...)")
        }
        // find matching closing paren
        var depth = 0
        let startIdx = code.index(code.startIndex, offsetBy: prefix.count)
        var endIdx: String.Index? = nil
        for (i, ch) in code[startIdx...].enumerated() {
            let idx = code.index(startIdx, offsetBy: i)
            if ch == "(" { depth += 1 }
            else if ch == ")" {
                if depth == 0 {
                    endIdx = idx
                    break
                }
                depth -= 1
            }
        }
        guard let end = endIdx else {
            throw ParseError.syntaxError("Unmatched parenthesis in \(fn)")
        }
        return String(code[startIdx..<end])
    }

    /// Splits a string by top-level commas (not inside parens/brackets/quotes).
    private func splitTopLevelCommas(_ s: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        var inString = false
        var prevChar: Character = "\0"
        for ch in s {
            if ch == "\"" && prevChar != "\\" {
                inString.toggle()
            }
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

    private func parseLayerList(_ args: String) throws -> [Layer] {
        let parts = splitTopLevelCommas(args)
        return try parts.map { try parseLayer($0) }
    }

    /// Parse a single layer expression like:
    ///   s("pad").slow(4).gain(0.5).room(0.6)
    ///   note("<c4 e4 g4 b4>").s("bell").slow(2).cutoff(1500).room(0.4).gain(0.7)
    private func parseLayer(_ expr: String) throws -> Layer {
        // Tokenise the method chain
        let chain = try parseMethodChain(expr)

        // Validate functions against known subset
        let supportedMethods: Set<String> = ["s", "note", "slow", "fast", "gain", "room", "cutoff"]
        for token in chain where !supportedMethods.contains(token.name) {
            throw ParseError.unsupported(token.name)
        }

        // Extract the components
        guard let sArg = chain.first(where: { $0.name == "s" })?.arg else {
            throw ParseError.syntaxError("Missing s(\"...\") in layer: \(expr)")
        }
        let sampleName = unquote(sArg)

        // Validate known samples
        guard knownSamples.contains(sampleName) else {
            throw ParseError.unknownSample(sampleName)
        }

        let noteArg = chain.first(where: { $0.name == "note" })?.arg.flatMap { unquote($0) }

        let slowFactor: Double
        if let slowArg = chain.first(where: { $0.name == "slow" })?.arg.flatMap({ Double($0) }) {
            slowFactor = slowArg
        } else if let fastArg = chain.first(where: { $0.name == "fast" })?.arg.flatMap({ Double($0) }) {
            slowFactor = 1.0 / fastArg
        } else {
            slowFactor = 1.0
        }

        let gain   = chain.first(where: { $0.name == "gain"   })?.arg.flatMap { Double($0) }
        let room   = chain.first(where: { $0.name == "room"   })?.arg.flatMap { Double($0) }
        let cutoff = chain.first(where: { $0.name == "cutoff" })?.arg.flatMap { Double($0) }

        // Build events from note arg or simple s() hit
        if let noteStr = noteArg {
            return try buildNoteLayer(
                noteStr: noteStr,
                sample: sampleName,
                slowFactor: slowFactor,
                gain: gain, room: room, cutoff: cutoff
            )
        } else {
            // s("pad") style — single hit per cycle at t=0, duration=1
            return Layer(
                sample: sampleName,
                events: [PatternEvent(cycleOnset: 0, cycleDuration: 1.0, midiNote: nil)],
                isAlternation: false,
                alternatives: [],
                slowFactor: slowFactor,
                gain: gain, room: room, cutoff: cutoff
            )
        }
    }

    // MARK: - Method chain tokeniser

    private struct ChainToken {
        let name: String
        let arg: String?   // content inside parens, if any; nil for bare names
    }

    /// Break "note(\"<c4 e4>\").s(\"bell\").slow(2)" into tokens.
    private func parseMethodChain(_ expr: String) throws -> [ChainToken] {
        var tokens: [ChainToken] = []
        var remaining = expr.trimmingCharacters(in: .whitespacesAndNewlines)

        while !remaining.isEmpty {
            // skip leading dot
            if remaining.hasPrefix(".") {
                remaining = String(remaining.dropFirst())
            }

            // read identifier
            var ident = ""
            while let first = remaining.first, (first.isLetter || first.isNumber || first == "_") {
                ident.append(first)
                remaining = String(remaining.dropFirst())
            }
            guard !ident.isEmpty else {
                // skip stray characters
                remaining = String(remaining.dropFirst())
                continue
            }

            // read optional (...)
            if remaining.hasPrefix("(") {
                remaining = String(remaining.dropFirst()) // consume "("
                let (arg, rest) = try extractParenContent(remaining)
                remaining = rest
                tokens.append(ChainToken(name: ident, arg: arg))
            } else {
                tokens.append(ChainToken(name: ident, arg: nil))
            }
        }
        return tokens
    }

    /// Extract content up to the matching ")" and return (content, rest).
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
        throw ParseError.syntaxError("Unmatched '(' in expression")
    }

    // MARK: - Note layer builder

    private func buildNoteLayer(
        noteStr: String,
        sample: String,
        slowFactor: Double,
        gain: Double?,
        room: Double?,
        cutoff: Double?
    ) throws -> Layer {
        let atoms = try TokenParser.parse(noteStr)

        // Check if the top-level is a single alternation
        if atoms.count == 1, case .alternation(let alts) = atoms[0] {
            // Each alternative becomes a separate event group
            let alternatives = alts.map { altAtoms in
                TokenParser.expandFlat(
                    atoms: altAtoms,
                    onset: 0,
                    duration: 1.0,
                    noteSource: midiNote(for:)
                )
            }
            return Layer(
                sample: sample,
                events: alternatives.first ?? [],
                isAlternation: true,
                alternatives: alternatives,
                slowFactor: slowFactor,
                gain: gain, room: room, cutoff: cutoff
            )
        }

        // Normal sequence
        let events = TokenParser.expandFlat(
            atoms: atoms,
            onset: 0,
            duration: 1.0,
            noteSource: midiNote(for:)
        )
        return Layer(
            sample: sample,
            events: events,
            isAlternation: false,
            alternatives: [],
            slowFactor: slowFactor,
            gain: gain, room: room, cutoff: cutoff
        )
    }

    // MARK: - Utilities

    private func unquote(_ s: String) -> String {
        var result = s.trimmingCharacters(in: .whitespaces)
        if result.hasPrefix("\"") { result = String(result.dropFirst()) }
        if result.hasSuffix("\"") { result = String(result.dropLast()) }
        return result
    }

    // MARK: - MIDI note conversion

    /// Convert a note name like "c4", "e4", "g#3", "bb5" to a MIDI number.
    /// c4 = MIDI 60 (middle C).
    public func midiNote(for name: String) -> Int? {
        let s = name.lowercased()
        guard let first = s.first, first >= "a" && first <= "g" else { return nil }

        var idx = s.index(after: s.startIndex)

        // Accidental
        var semitoneOffset = 0
        if idx < s.endIndex {
            if s[idx] == "#" { semitoneOffset = 1; idx = s.index(after: idx) }
            else if s[idx] == "b" { semitoneOffset = -1; idx = s.index(after: idx) }
        }

        // Octave
        guard idx < s.endIndex, let octave = Int(String(s[idx...])) else { return nil }

        let noteNames: [Character: Int] = [
            "c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11
        ]
        guard let base = noteNames[first] else { return nil }
        // MIDI: C4 = 60, formula: (octave+1)*12 + base
        return (octave + 1) * 12 + base + semitoneOffset
    }
}
