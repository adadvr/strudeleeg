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
//   degrade:  "a?"           → randomly omit with probability 0.5 (default)
//             "a?0.3"        → randomly omit with probability 0.3
//   polymeter:"{a b, c d e}" → parallel sub-sequences, each maintaining own step count
//             "{a b, c d e}%4" → 4 steps per cycle (overrides)
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
        case chord([[Atom]])        // [a,b,c] or "a,b" — parallel stack (simultaneous)
        case polymeter([[Atom]], Int?)  // {a b, c d e}%n — polymeter (each branch own step count)
        // Modifier wrappers (set after parsing base atom)
        case fast(Atom, Int)        // a*n  — play n times faster (subdivide)
        case replicate(Atom, Int)   // a!n  — repeat as n equal steps
        case weight(Atom, Int)      // a@w  — this step has weight w
        case degrade(Atom, Double)  // a?p  — random omission with probability p
    }

    // MARK: - Tokenizer

    static func tokenize(_ input: String) throws -> [Atom] {
        var scalars = Array(input.unicodeScalars)
        var idx = scalars.startIndex
        // Parse the top-level with comma awareness: if we find a comma at the
        // outermost level the entire string is a chord (parallel stack).
        return try parseParallelBranches(&scalars, idx: &idx, terminators: [])
    }

    /// Parse a sequence that may contain comma-separated branches (chord / parallel stack).
    /// Each branch is itself a sequence; if there is only one branch, returns it directly.
    /// If there are multiple branches, returns [.chord([[Atom]])].
    private static func parseParallelBranches(
        _ scalars: inout [Unicode.Scalar],
        idx: inout Array<Unicode.Scalar>.Index,
        terminators: Set<Unicode.Scalar>
    ) throws -> [Atom] {
        var branches: [[Atom]] = []
        let commaTerminators = terminators.union([","])
        let firstBranch = try parseSequence(&scalars, idx: &idx, terminators: commaTerminators)
        // If we stopped at something other than comma, only one branch
        if idx >= scalars.endIndex || scalars[idx] != "," || terminators.contains(",") {
            return firstBranch
        }
        branches.append(firstBranch)
        // Collect additional branches separated by commas
        while idx < scalars.endIndex && scalars[idx] == "," {
            idx = scalars.index(after: idx)   // consume ','
            let branch = try parseSequence(&scalars, idx: &idx, terminators: commaTerminators)
            branches.append(branch)
        }
        // Wrap in a single chord atom
        return [.chord(branches)]
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
                // Parse inside [...] with chord support: commas create parallel branches.
                // We use a local helper that passes "]" as terminator so comma-branches
                // also stop at the closing bracket.
                let sub = try parseGroupContent(&scalars, idx: &idx)
                if idx < scalars.endIndex && scalars[idx] == "]" {
                    idx = scalars.index(after: idx)
                }
                var atom: Atom = sub
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

            case "{":
                // Polymeter: {a b, c d e}%n
                // Multiple branches in parallel, each maintaining its own step count.
                // The optional %n overrides steps-per-cycle.
                idx = scalars.index(after: idx)
                var branches: [[Atom]] = []
                let firstBranch = try parseSequence(&scalars, idx: &idx, terminators: ["}", ","])
                if firstBranch.isEmpty == false || true {
                    branches.append(firstBranch)
                }
                while idx < scalars.endIndex && scalars[idx] == "," {
                    idx = scalars.index(after: idx)   // consume ','
                    let branch = try parseSequence(&scalars, idx: &idx, terminators: ["}", ","])
                    branches.append(branch)
                }
                if idx < scalars.endIndex && scalars[idx] == "}" {
                    idx = scalars.index(after: idx)  // consume '}'
                }
                // Check for optional %n (steps per cycle override)
                var stepsPerCycle: Int? = nil
                if idx < scalars.endIndex && scalars[idx] == "%" {
                    idx = scalars.index(after: idx)
                    stepsPerCycle = parseOptionalInt(&scalars, idx: &idx)
                }
                var pmAtom: Atom = .polymeter(branches, stepsPerCycle)
                pmAtom = try parseModifiers(&scalars, idx: &idx, base: pmAtom)
                atoms.append(pmAtom)

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

    /// Parse optional modifier characters: *, !, @, ? after a base atom.
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
            case "?":
                // Random degradation: a? → omit with probability 0.5
                // a?0.3 → omit with probability 0.3
                idx = scalars.index(after: idx)
                let prob = parseOptionalDouble(&scalars, idx: &idx) ?? 0.5
                atom = .degrade(atom, prob)
            default:
                return atom
            }
        }
        return atom
    }

    /// Read an optional double literal immediately (digits and optional decimal).
    /// Used for ? probability parsing: a?0.3 → 0.3.
    private static func parseOptionalDouble(
        _ scalars: inout [Unicode.Scalar],
        idx: inout Array<Unicode.Scalar>.Index
    ) -> Double? {
        var digits = ""
        while idx < scalars.endIndex {
            let c = scalars[idx]
            if (c >= "0" && c <= "9") || c == "." {
                digits.append(Character(c))
                idx = scalars.index(after: idx)
            } else {
                break
            }
        }
        return digits.isEmpty ? nil : Double(digits)
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
            // Use parseGroupContent to support chords inside [...] within <...>
            let inner = try parseGroupContent(&scalars, idx: &idx)
            if idx < scalars.endIndex && scalars[idx] == "]" {
                idx = scalars.index(after: idx)
            }
            atom = inner
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

    /// Parse the content inside [...], returning a .group or .chord atom.
    /// Commas create parallel branches (chord/stack); each branch is a sequence.
    private static func parseGroupContent(
        _ scalars: inout [Unicode.Scalar],
        idx: inout Array<Unicode.Scalar>.Index
    ) throws -> Atom {
        // Parse first branch (stops at ',' or ']')
        let firstBranch = try parseSequence(&scalars, idx: &idx, terminators: ["]", ","])
        // If stopped at ']' (or end), single branch → regular group
        if idx >= scalars.endIndex || scalars[idx] != "," {
            return .group(firstBranch)
        }
        // Comma found: collect all branches
        var branches: [[Atom]] = [firstBranch]
        while idx < scalars.endIndex && scalars[idx] == "," {
            idx = scalars.index(after: idx)   // consume ','
            let branch = try parseSequence(&scalars, idx: &idx, terminators: ["]", ","])
            branches.append(branch)
        }
        return .chord(branches)
    }

    private static func isWordChar(_ c: Unicode.Scalar) -> Bool {
        let prohibited: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "[", "]", "<", ">", "{", "}", ",", "*", "!", "@", "?"]
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
        case .chord(let branches):
            // Each branch is a parallel sub-sequence; stack them all simultaneously.
            // The individual branches may have different step counts (like [bd bd, hh hh hh]).
            let pats = branches.map { atomsToPattern($0) }
            return stack(pats)
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
        case .degrade(let inner, let prob):
            // a? → randomly omit this step with probability prob
            // Uses PRNG seeded by cycle and event index (deterministic, documented non-bitwise-equiv).
            return degradePattern(atomToPattern(inner), prob: prob)
        case .polymeter(let branches, let stepsOverride):
            // {a b, c d e}%n — parallel branches with independent step counts.
            return polymeterPattern(branches, stepsPerCycle: stepsOverride)
        }
    }

    // MARK: - degrade helper

    /// Apply random omission to a pattern with given probability.
    ///
    /// Semantics: for each hap in each cycle, use a deterministic PRNG
    /// seeded by (cycle, eventIndex) to decide if the hap is omitted.
    /// prob is the OMISSION probability: prob=0.5 → ~50% of steps silent.
    ///
    /// DOCUMENTED APPROXIMATION: Strudel's degradeBy uses a continuous
    /// time-based rand signal with time-hash RNG. Our PRNG is different
    /// (splitmix64 seeded by cycle+index vs. time-keyed murmur).
    /// We guarantee: determinism (same seed = same result), correct
    /// proportion (measured over many cycles ≈ prob), no bit-exact match.
    static func degradePattern(_ pat: Pattern<String>, prob: Double) -> Pattern<String> {
        guard prob > 0 else { return pat }
        guard prob < 1 else { return .silence }
        return splitQueries(Pattern { span in
            let cycleN = span.begin.floorInt
            let haps   = pat.query(span).sorted { $0.part.begin < $1.part.begin }
            return haps.enumerated().compactMap { (idx, hap) -> Hap<String>? in
                var rng = MiniPRNG(cycle: cycleN, eventIndex: idx)
                let r = rng.nextDouble()
                return r < prob ? nil : hap   // omit if r < prob
            }
        })
    }

    // MARK: - polymeter helper

    /// Build a polymeter pattern from multiple branches.
    ///
    /// Semantics (Strudel public docs / strudel.cc/learn/mini-notation):
    ///   {a b, c d e} — each branch maintains its own step count per cycle.
    ///   Branch 0 has 2 steps/cycle, branch 1 has 3 steps/cycle.
    ///   They are stacked (simultaneous): at any given cycle, all branches play
    ///   their own full cycle's worth of steps.
    ///
    ///   {a b, c d e} over 6 cycles:
    ///     branch "a b": a b | a b | a b | a b | a b | a b  (2 steps each)
    ///     branch "c d e": c d e | c d e | c d e | ...     (3 steps each)
    ///   Both run in parallel, each taking a full cycle.
    ///
    ///   With stepsOverride (%n): forces each branch to treat its content as
    ///   fitting exactly n steps per cycle, compressing or stretching accordingly.
    ///   {a b c}%4: plays a b c over a cycle divided into 4 steps, so it stretches.
    ///
    ///   Oracle: {bd sn, hh hh hh} →
    ///     bd at [0,1/2), sn at [1/2,1) simultaneous with
    ///     hh at [0,1/3), hh at [1/3,2/3), hh at [2/3,1)
    ///   This is structurally identical to [bd sn, hh hh hh] but differs in
    ///   multi-cycle behaviour: polymeter rotates step offsets, comma-chord doesn't.
    ///
    ///   Without stepsOverride, the stack semantics for a single cycle are the same
    ///   as a chord `[...]` (each branch fills a full cycle). The polymeter difference
    ///   emerges in how many cycles it takes to complete one "super-cycle".
    static func polymeterPattern(_ branches: [[Atom]], stepsPerCycle: Int?) -> Pattern<String> {
        guard !branches.isEmpty else { return .silence }

        if let n = stepsPerCycle {
            // With %n: each branch is forced to n steps per cycle.
            // The branch pattern is fast(branchLen/n) so it fits n steps.
            // Actually: we run each branch at its own natural rate but query
            // it aligned to n steps per cycle.
            let branchPats = branches.map { atomsToPattern($0) }
            // Compute each branch length (number of top-level atoms)
            let branchLengths = branches.map { atoms -> Int in
                let expanded = atoms.flatMap { expandReplicate($0) }
                return expanded.count
            }
            // Each branch: stretch/compress to fit n steps per cycle
            let stretchedPats = zip(branchPats, branchLengths).map { (pat, len) -> Pattern<String> in
                guard len > 0, n > 0 else { return pat }
                // ratio = len/n: if len=3, n=4, ratio=3/4, so fast(3/4) makes 3 fit in 4 slots
                let ratio = Rational(len, n)
                return pat.fast(ratio)
            }
            return stack(stretchedPats)
        } else {
            // Without %n: each branch plays its own full cycle independently.
            // This is equivalent to stacking the branch patterns as full-cycle patterns.
            // Each branch fills the entire [0,1) span with its step count.
            // This is the "pure polymeter" where step counts differ.
            let branchPats = branches.map { atomsToPattern($0) }
            return stack(branchPats)
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
