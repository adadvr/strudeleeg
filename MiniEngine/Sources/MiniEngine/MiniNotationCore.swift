// ---------------------------------------------------------------------------
// MiniNotationCore — parses mini-notation strings to Pattern<String>
// Clean-room from public strudel.cc/learn docs.
//
// Supported:
//   sequence: "a b c"        → fastcat of pure values
//   group:    "[a b] c"      → fastcat of the group as one step
//   slowcat:  "<a b>"        → slowcat (one alternative per cycle)
//   silence:  "~"            → silence
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
                atoms.append(.silence)

            case "[":
                idx = scalars.index(after: idx)
                let sub = try parseSequence(&scalars, idx: &idx, terminators: ["]"])
                if idx < scalars.endIndex && scalars[idx] == "]" {
                    idx = scalars.index(after: idx)
                }
                atoms.append(.group(sub))

            case "<":
                idx = scalars.index(after: idx)
                var alts: [[Atom]] = []
                // Inside <...>, each whitespace-separated atom is one alternative
                while idx < scalars.endIndex && scalars[idx] != ">" {
                    // skip whitespace
                    while idx < scalars.endIndex,
                          scalars[idx] == " " || scalars[idx] == "\t" {
                        idx = scalars.index(after: idx)
                    }
                    if idx < scalars.endIndex && scalars[idx] != ">" {
                        let atom = try parseSingleAtom(&scalars, idx: &idx)
                        alts.append([atom])
                    }
                }
                if idx < scalars.endIndex && scalars[idx] == ">" {
                    idx = scalars.index(after: idx)
                }
                atoms.append(.slowcat(alts))

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
                    atoms.append(.name(word))
                }
            }
        }
        return atoms
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
        switch ch {
        case "~":
            idx = scalars.index(after: idx)
            return .silence
        case "[":
            idx = scalars.index(after: idx)
            let sub = try parseSequence(&scalars, idx: &idx, terminators: ["]"])
            if idx < scalars.endIndex && scalars[idx] == "]" {
                idx = scalars.index(after: idx)
            }
            return .group(sub)
        default:
            var word = ""
            while idx < scalars.endIndex, isWordChar(scalars[idx]) {
                word.append(Character(scalars[idx]))
                idx = scalars.index(after: idx)
            }
            return .name(word)
        }
    }

    private static func isWordChar(_ c: Unicode.Scalar) -> Bool {
        let prohibited: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "[", "]", "<", ">", ","]
        return !prohibited.contains(c)
    }

    // MARK: - AST → Pattern

    static func atomsToPattern(_ atoms: [Atom]) -> Pattern<String> {
        guard !atoms.isEmpty else { return .silence }
        let pats = atoms.map { atomToPattern($0) }
        return pats.count == 1 ? pats[0] : fastcat(pats)
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
