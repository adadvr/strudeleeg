// ---------------------------------------------------------------------------
// MiniNotationCore — parses mini-notation strings to Pattern<String>
// Clean-room from public strudel.cc/learn docs.
//
// Supported:
//   sequence: "a b c"        → fastcat of pure values
//   group:    "[a b] c"      → fastcat of the group as one step
//   slowcat:  "<a b>"        → slowcat (one alternative per cycle)
//   silence:  "~"            → silence
//   multiply: "a*2"          → fast(2) on that step (subdivide into 2)
//   replicate:"a!2" / "a!"   → repeat step as N equal steps (default 2)
//   weight:   "a@3"          → step occupies 3 weight-units in the cycle
// ---------------------------------------------------------------------------

import Foundation

public enum MiniNotationCore {

    // MARK: - Public entry point

    /// Parse a mini-notation string into Pattern<String>.
    public static func parse(_ input: String) -> Pattern<String> {
        do {
            let atoms = try tokenize(input)
            return atomsToPattern(atoms)
        } catch {
            // On parse error return silence
            return .silence
        }
    }

    // MARK: - AST

    indirect enum Atom {
        case name(String)           // a word
        case silence                // ~
        case group([Atom])          // [a b c]
        case slowcat([[Atom]])      // <a b c>
        // Modifier wrappers (set after parsing base atom)
        case fast(Atom, Int)        // a*n  — play n times faster (subdivide)
        case replicate(Atom, Int)   // a!n  — repeat as n equal steps
        case weight(Atom, Int)      // a@w  — this step has weight w
    }

    // MARK: - Tokenizer

    static func tokenize(_ input: String) throws -> [Atom] {
        var scalars = Array(input.unicodeScalars)
        var idx = scalars.startIndex
        return try parseSequence(&scalars, idx: &idx, terminators: [])
    }

    private static func parseSequence(
        _ scalars: inout [Unicode.Scalar],
        idx: inout Array<Unicode.Scalar>.Index,
        terminators: Set<Unicode.Scalar>
    ) throws -> [Atom] {
        var atoms: [Atom] = []

        while idx < scalars.endIndex {
            let ch = scalars[idx]

            if terminators.contains(ch) { break }

            switch ch {
            case " ", "\t", "\n", "\r":
                idx = scalars.index(after: idx)

            case "~":
                idx = scalars.index(after: idx)
                var atom: Atom = .silence
                atom = try parseModifiers(&scalars, idx: &idx, base: atom)
                atoms.append(atom)

            case "[":
                idx = scalars.index(after: idx)
                let sub = try parseSequence(&scalars, idx: &idx, terminators: ["]"])
                if idx < scalars.endIndex && scalars[idx] == "]" {
                    idx = scalars.index(after: idx)
                }
                var atom: Atom = .group(sub)
                atom = try parseModifiers(&scalars, idx: &idx, base: atom)
                atoms.append(atom)

            case "<":
                idx = scalars.index(after: idx)
                var alts: [[Atom]] = []
                // Inside <...>, each whitespace-separated atom is one cycle alternative.
                // If an atom has a ! (replicate) modifier, expand it into N separate
                // alternatives so that <a!3 b> = <a a a b> (one per cycle, not one slot).
                while idx < scalars.endIndex && scalars[idx] != ">" {
                    // skip whitespace
                    while idx < scalars.endIndex,
                          scalars[idx] == " " || scalars[idx] == "\t" {
                        idx = scalars.index(after: idx)
                    }
                    if idx < scalars.endIndex && scalars[idx] != ">" {
                        let atom = try parseSingleAtom(&scalars, idx: &idx)
                        // If the atom is wrapped in .replicate, expand to N separate
                        // alternatives instead of one multi-step alternative.
                        // <a!3 b> → [a, a, a, b] as cycle alternatives (4 total),
                        // not [a a a, b] (a as 3-step sequence in one cycle slot).
                        if case .replicate(let inner, let count) = atom {
                            for _ in 0..<count {
                                alts.append([inner])
                            }
                        } else {
                            alts.append([atom])
                        }
                    }
                }
                if idx < scalars.endIndex && scalars[idx] == ">" {
                    idx = scalars.index(after: idx)
                }
                var atom: Atom = .slowcat(alts)
                atom = try parseModifiers(&scalars, idx: &idx, base: atom)
                atoms.append(atom)

            default:
                // word token
                var word = ""
                while idx < scalars.endIndex {
                    let c = scalars[idx]
                    if isWordChar(c) {
                        word.append(Character(c))
                        idx = scalars.index(after: idx)
                    } else {
                        break
                    }
                }
                if !word.isEmpty {
                    var atom: Atom = .name(word)
                    atom = try parseModifiers(&scalars, idx: &idx, base: atom)
                    atoms.append(atom)
                }
            }
        }
        return atoms
    }

    /// Parse optional modifier characters: *, !, @ after a base atom.
    /// Modifiers can chain: a*2@3 is allowed by Strudel (fast then weight).
    private static func parseModifiers(
        _ scalars: inout [Unicode.Scalar],
        idx: inout Array<Unicode.Scalar>.Index,
        base: Atom
    ) throws -> Atom {
        var atom = base
        while idx < scalars.endIndex {
            let ch = scalars[idx]
            switch ch {
            case "*":
                idx = scalars.index(after: idx)
                let n = parseOptionalInt(&scalars, idx: &idx) ?? 2
                atom = .fast(atom, n)
            case "!":
                idx = scalars.index(after: idx)
                let n = parseOptionalInt(&scalars, idx: &idx) ?? 2
                atom = .replicate(atom, n)
            case "@":
                idx = scalars.index(after: idx)
                let n = parseOptionalInt(&scalars, idx: &idx) ?? 1
                atom = .weight(atom, n)
            default:
                return atom
            }
        }
        return atom
    }

    /// Read an optional integer immediately (no whitespace). Returns nil if no digit follows.
    private static func parseOptionalInt(
        _ scalars: inout [Unicode.Scalar],
        idx: inout Array<Unicode.Scalar>.Index
    ) -> Int? {
        var digits = ""
        while idx < scalars.endIndex, scalars[idx] >= "0" && scalars[idx] <= "9" {
            digits.append(Character(scalars[idx]))
            idx = scalars.index(after: idx)
        }
        return Int(digits)
    }

    /// Parse a single atom (used inside <...>).
    private static func parseSingleAtom(
        _ scalars: inout [Unicode.Scalar],
        idx: inout Array<Unicode.Scalar>.Index
    ) throws -> Atom {
        guard idx < scalars.endIndex else {
            return .silence
        }
        let ch = scalars[idx]
        var atom: Atom
        switch ch {
        case "~":
            idx = scalars.index(after: idx)
            atom = .silence
        case "[":
            idx = scalars.index(after: idx)
            let sub = try parseSequence(&scalars, idx: &idx, terminators: ["]"])
            if idx < scalars.endIndex && scalars[idx] == "]" {
                idx = scalars.index(after: idx)
            }
            atom = .group(sub)
        default:
            var word = ""
            while idx < scalars.endIndex, isWordChar(scalars[idx]) {
                word.append(Character(scalars[idx]))
                idx = scalars.index(after: idx)
            }
            atom = .name(word)
        }
        atom = try parseModifiers(&scalars, idx: &idx, base: atom)
        return atom
    }

    private static func isWordChar(_ c: Unicode.Scalar) -> Bool {
        let prohibited: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "[", "]", "<", ">", ",", "*", "!", "@"]
        return !prohibited.contains(c)
    }

    // MARK: - AST → Pattern

    // A weighted step: (pattern, weight-in-rational-units)
    private struct WeightedPat {
        let pat: Pattern<String>
        let weight: Rational
    }

    /// Convert a list of atoms to a pattern, honouring @weight modifiers.
    static func atomsToPattern(_ atoms: [Atom]) -> Pattern<String> {
        guard !atoms.isEmpty else { return .silence }

        // Expand .replicate atoms first so weights are correct
        let expanded = atoms.flatMap { expandReplicate($0) }

        // Build weighted list
        let weighted = expanded.map { atom -> WeightedPat in
            let (inner, w) = unwrapWeight(atom)
            return WeightedPat(pat: atomToPattern(inner), weight: Rational(w))
        }

        // If all weights are 1, use plain fastcat (exact same semantics)
        let allUnit = weighted.allSatisfy { $0.weight == .one }
        if allUnit {
            let pats = weighted.map { $0.pat }
            return pats.count == 1 ? pats[0] : fastcat(pats)
        }

        // Weighted fastcat: each step occupies (weight / totalWeight) of the cycle
        let totalWeight = weighted.reduce(Rational.zero) { $0 + $1.weight }
        return weightedFastcat(weighted, total: totalWeight)
    }

    /// Expand .replicate(atom, n) into n copies of atom.
    private static func expandReplicate(_ atom: Atom) -> [Atom] {
        if case .replicate(let inner, let n) = atom {
            // Replicate n copies — no weight wrapper needed, they're equal steps
            return Array(repeating: inner, count: n)
        }
        return [atom]
    }

    /// Unwrap a .weight modifier, returning (innerAtom, weightInt).
    private static func unwrapWeight(_ atom: Atom) -> (Atom, Int) {
        if case .weight(let inner, let w) = atom {
            return (inner, w)
        }
        return (atom, 1)
    }

    /// Build a weighted fastcat: each pat gets duration = weight/total of the cycle.
    private static func weightedFastcat(
        _ items: [WeightedPat],
        total: Rational
    ) -> Pattern<String> {
        guard !items.isEmpty else { return .silence }

        return splitQueries(Pattern { span in
            let cycleN = span.begin.floorInt
            let baseOffset = Rational(cycleN)
            var haps: [Hap<String>] = []
            var cumWeight = Rational.zero

            for item in items {
                let slotBegin = baseOffset + cumWeight / total
                let slotEnd   = baseOffset + (cumWeight + item.weight) / total
                let slotSpan  = TimeSpan(slotBegin, slotEnd)
                cumWeight = cumWeight + item.weight

                guard let querySpan = slotSpan.intersection(span) else { continue }

                let slotDuration = item.weight / total   // fraction of a cycle
                let offset = slotBegin
                let rCycleN = baseOffset

                // Map queried span into the sub-pattern's coordinate space,
                // preserving the outer cycle number so that slowcat sub-patterns
                // advance correctly across weighted slots.
                // Mapping: t_inner = (t_outer - offset) / slotDuration + cycleN
                let mappedBegin = (querySpan.begin - offset) / slotDuration + rCycleN
                let mappedEnd   = (querySpan.end   - offset) / slotDuration + rCycleN
                let mappedSpan  = TimeSpan(mappedBegin, mappedEnd)

                let subHaps = item.pat.query(mappedSpan)

                for hap in subHaps {
                    let mapBack: (Rational) -> Rational = { t in (t - rCycleN) * slotDuration + offset }
                    let newWhole = hap.whole.map { w in TimeSpan(mapBack(w.begin), mapBack(w.end)) }
                    let newPart  = TimeSpan(mapBack(hap.part.begin), mapBack(hap.part.end))
                    haps.append(Hap(whole: newWhole, part: newPart, value: hap.value))
                }
            }
            return haps
        })
    }

    static func atomToPattern(_ atom: Atom) -> Pattern<String> {
        switch atom {
        case .name(let s):
            return .pure(s)
        case .silence:
            return .silence
        case .group(let inner):
            return atomsToPattern(inner)
        case .slowcat(let alts):
            let patAlts = alts.map { atomsToPattern($0) }
            return slowcat(patAlts)
        case .fast(let inner, let n):
            // a*n → play the inner pattern n times faster (subdivide into n)
            return atomToPattern(inner).fast(n)
        case .replicate(let inner, _):
            // Replicates are expanded before reaching here; handle defensively
            return atomToPattern(inner)
        case .weight(let inner, _):
            // Weight is handled at the sequence level; unwrap here
            return atomToPattern(inner)
        }
    }
}

// MARK: - MIDI note conversion (used by ControlPattern.notePattern)

/// Convert note name like "c4", "e4", "g#3", "bb5" to MIDI number.
/// c4 = MIDI 60.
public func midiNote(for name: String) -> Int? {
    let s = name.lowercased()
    guard let first = s.first, first >= "a" && first <= "g" else { return nil }

    var idx = s.index(after: s.startIndex)

    var semitoneOffset = 0
    if idx < s.endIndex {
        if s[idx] == "#" { semitoneOffset = 1; idx = s.index(after: idx) }
        else if s[idx] == "b" { semitoneOffset = -1; idx = s.index(after: idx) }
    }

    guard idx < s.endIndex, let octave = Int(String(s[idx...])) else { return nil }

    let noteNames: [Character: Int] = [
        "c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11
    ]
    guard let base = noteNames[first] else { return nil }
    return (octave + 1) * 12 + base + semitoneOffset
}

/// Convert MIDI number to note name (c4 = 60).
public func midiToNoteName(_ midi: Int) -> String {
    let names = ["c", "c#", "d", "d#", "e", "f", "f#", "g", "g#", "a", "a#", "b"]
    let octave = (midi / 12) - 1
    let name   = names[midi % 12]
    return "\(name)\(octave)"
}
