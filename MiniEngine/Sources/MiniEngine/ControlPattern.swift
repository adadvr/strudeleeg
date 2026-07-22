// ---------------------------------------------------------------------------
// ControlPattern — Pattern<[String: ControlValue]>
// Each control (s, note, gain, room, cutoff…) is a pattern of a single-field
// map; they are combined with appLeft so structure comes from the base pattern.
// ---------------------------------------------------------------------------

/// A tagged union for control parameter values.
public enum ControlValue: Hashable, CustomStringConvertible, Sendable {
    case string(String)
    case double(Double)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let d) = self { return d }
        return nil
    }

    public var description: String {
        switch self {
        case .string(let s): return s
        case .double(let d): return d.truncatingRemainder(dividingBy: 1) == 0
                              ? "\(Int(d))" : "\(d)"
        }
    }
}

/// A pattern of a dictionary of control values.
public typealias ControlPattern = Pattern<[String: ControlValue]>

// MARK: - Combining control maps

/// Merge two control maps; right-side wins on conflict.
public func mergeControls(_ a: [String: ControlValue], _ b: [String: ControlValue]) -> [String: ControlValue] {
    var result = a
    for (k, v) in b { result[k] = v }
    return result
}

// MARK: - ControlPattern combinators

extension Pattern where T == [String: ControlValue] {
    /// Combine with another ControlPattern: structure comes from SELF (base),
    /// control values from OTHER are merged in.
    ///
    /// Semantics (from Tidal / Strudel docs):
    ///   For each base hap, query the control pattern over the base hap's
    ///   *whole* extent. Each control hap whose whole/part overlaps the base
    ///   hap's whole generates one combined output hap, whose:
    ///     - whole = base hap's whole  (structure from base, NOT from control)
    ///     - part  = intersection of base hap's part and control hap's whole
    ///     - value = mergeControls(base_value, control_value)
    ///
    /// This is what Strudel calls "appLeft" / `<*` in Haskell notation.
    public func withControl(_ other: ControlPattern) -> ControlPattern {
        Pattern { span in
            let baseHaps = self.query(span)
            var result: [Hap<[String: ControlValue]>] = []

            for baseHap in baseHaps {
                // Query control over the base hap's whole structural extent
                let querySpan = baseHap.whole ?? baseHap.part
                let controlHaps = other.query(querySpan)

                for controlHap in controlHaps {
                    // Control hap's "extent" for intersection purposes
                    let controlExtent = controlHap.whole ?? controlHap.part
                    // Part = intersection of base part and control extent
                    guard let newPart = baseHap.part.intersection(controlExtent) else { continue }
                    result.append(Hap(
                        whole: baseHap.whole,  // structure from base
                        part:  newPart,
                        value: mergeControls(baseHap.value, controlHap.value)
                    ))
                }
            }
            return result
        }
    }

    // MARK: - Control method chaining

    public func gain(_ value: Double) -> ControlPattern {
        withControl(.pure(["gain": .double(value)]))
    }

    public func gain(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["gain": .double(Double($0) ?? 1.0)] })
    }

    public func room(_ value: Double) -> ControlPattern {
        withControl(.pure(["room": .double(value)]))
    }

    public func room(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["room": .double(Double($0) ?? 0.0)] })
    }

    public func cutoff(_ value: Double) -> ControlPattern {
        withControl(.pure(["cutoff": .double(value)]))
    }

    public func cutoff(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["cutoff": .double(Double($0) ?? 20000.0)] })
    }

    public func pan(_ value: Double) -> ControlPattern {
        withControl(.pure(["pan": .double(value)]))
    }

    public func pan(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["pan": .double(Double($0) ?? 0.5)] })
    }

    public func s(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["s": .string($0)] })
    }

    public func note(_ pattern: String) -> ControlPattern {
        withControl(notePattern(pattern))
    }

    // MARK: - Delay controls

    public func delay(_ value: Double) -> ControlPattern {
        withControl(.pure(["delay": .double(value)]))
    }

    public func delay(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["delay": .double(Double($0) ?? 0.0)] })
    }

    public func delaytime(_ value: Double) -> ControlPattern {
        withControl(.pure(["delaytime": .double(value)]))
    }

    public func delaytime(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["delaytime": .double(Double($0) ?? 0.25)] })
    }

    public func delayfeedback(_ value: Double) -> ControlPattern {
        withControl(.pure(["delayfeedback": .double(value)]))
    }

    public func delayfeedback(_ pattern: String) -> ControlPattern {
        withControl(parseMini(pattern).map { ["delayfeedback": .double(Double($0) ?? 0.5)] })
    }

    // MARK: - Scale / n

    public func n(_ pattern: String) -> ControlPattern {
        withControl(nPattern(pattern))
    }

    public func scale(_ value: String) -> ControlPattern {
        withControl(.pure(["scale": .string(value)])).resolveScale()
    }

    /// Resolve any hap that has both "n" and "scale" fields into a "note" (MIDI).
    /// After resolution, "n" and "scale" fields are removed and replaced with "note".
    public func resolveScale() -> ControlPattern {
        Pattern { span in
            self.query(span).map { hap in
                guard let scaleStr = hap.value["scale"]?.stringValue,
                      let nVal = hap.value["n"]?.doubleValue,
                      let (root, intervals) = parseScale(scaleStr) else {
                    return hap
                }
                let idx = Int(nVal.rounded())
                let midi = scaleDegreeToMidi(index: idx, root: root, intervals: intervals)
                var newValue = hap.value
                newValue["note"] = .double(Double(midi))
                newValue.removeValue(forKey: "n")
                newValue.removeValue(forKey: "scale")
                return Hap(whole: hap.whole, part: hap.part, value: newValue)
            }
        }
    }
}

// MARK: - Top-level constructors

/// s("pad bell") → ControlPattern with field "s"
public func s(_ miniNotation: String) -> ControlPattern {
    parseMini(miniNotation).map { ["s": .string($0)] }
}

/// note("c4 e4 g4") → ControlPattern with field "note" (MIDI number as double)
public func note(_ miniNotation: String) -> ControlPattern {
    notePattern(miniNotation)
}

// MARK: - Helpers

/// Parse a mini-notation string as Pattern<String>.
func parseMini(_ notation: String) -> Pattern<String> {
    MiniNotationCore.parse(notation)
}

/// Parse a note mini-notation and convert note names to MIDI doubles.
func notePattern(_ notation: String) -> ControlPattern {
    parseMini(notation).map { token -> [String: ControlValue] in
        if let midi = midiNote(for: token) {
            return ["note": .double(Double(midi))]
        } else if let n = Double(token) {
            return ["note": .double(n)]
        }
        // Unknown: pass as string (will be ignored by scheduler)
        return ["note": .string(token)]
    }
}

// MARK: - stack overload for ControlPattern

/// Top-level pan constructor
public func pan(_ miniNotation: String) -> ControlPattern {
    parseMini(miniNotation).map { ["pan": .double(Double($0) ?? 0.5)] }
}

// MARK: - n() helper

/// Parse n mini-notation and produce {"n": double} control map.
func nPattern(_ notation: String) -> ControlPattern {
    parseMini(notation).map { token -> [String: ControlValue] in
        if let v = Double(token) {
            return ["n": .double(v)]
        }
        return ["n": .string(token)]
    }
}

/// Top-level n constructor
public func n(_ miniNotation: String) -> ControlPattern {
    nPattern(miniNotation)
}

// MARK: - scale() helper — resolves n+scale to MIDI note

/// Scale definitions: maps scale name → intervals from root (semitones, repeating per octave).
/// Documented: these are the intervals for one octave; index wraps with octave shifts.
private let scaleIntervals: [String: [Int]] = [
    "major":       [0, 2, 4, 5, 7, 9, 11],
    "minor":       [0, 2, 3, 5, 7, 8, 10],   // natural minor
    "dorian":      [0, 2, 3, 5, 7, 9, 10],
    "mixolydian":  [0, 2, 4, 5, 7, 9, 10],
    "pentatonic":  [0, 2, 4, 7, 9],
]

/// Root note names → MIDI number for octave 3 (Strudel default: C3 = MIDI 48).
/// Verified against oracle: n(0).scale("C:minor") → MIDI 48.
private let rootMidi: [String: Int] = [
    "C": 48, "C#": 49, "Db": 49,
    "D": 50, "D#": 51, "Eb": 51,
    "E": 52,
    "F": 53, "F#": 54, "Gb": 54,
    "G": 55, "G#": 56, "Ab": 56,
    "A": 57, "A#": 58, "Bb": 58,
    "B": 59,
]

/// Parse "Root:scalename" → (rootMidi, intervals).
public func parseScale(_ scaleStr: String) -> (Int, [Int])? {
    let parts = scaleStr.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    let rootStr = String(parts[0]).trimmingCharacters(in: .whitespaces)
    let scaleName = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
    guard let root = rootMidi[rootStr],
          let intervals = scaleIntervals[scaleName] else { return nil }
    return (root, intervals)
}

/// Convert scale degree index → MIDI note.
/// Negative indices and indices beyond the octave wrap correctly.
public func scaleDegreeToMidi(index: Int, root: Int, intervals: [Int]) -> Int {
    let stepsPerOctave = intervals.count
    // Wrap index to [0, stepsPerOctave) and compute octave shift
    let octaveShift = index >= 0
        ? index / stepsPerOctave
        : (index - stepsPerOctave + 1) / stepsPerOctave
    let wrappedIdx = ((index % stepsPerOctave) + stepsPerOctave) % stepsPerOctave
    return root + 12 * octaveShift + intervals[wrappedIdx]
}

/// stack for ControlPatterns — calls the generic Pattern stack.
/// We cast to the base type first to avoid ambiguous dispatch to this overload.
public func stackCP(_ patterns: [ControlPattern]) -> ControlPattern {
    // Use the generic stack via the pattern's query — avoids circular overload resolution.
    Pattern { span in
        patterns.flatMap { $0.query(span) }
    }
}

public func stackCP(_ patterns: ControlPattern...) -> ControlPattern {
    stackCP(patterns)
}
