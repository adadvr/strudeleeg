// ---------------------------------------------------------------------------
// Pattern<T> — FRP model from Tidal Cycles / Strudel public documentation.
//
// A Pattern is a pure function: (TimeSpan) -> [Hap<T>]
// Combinators are built from public semantics (strudel.cc/learn, Tidal papers).
// CLEAN-ROOM: no JS source was read.
// ---------------------------------------------------------------------------

public struct Pattern<T> {
    public let query: (TimeSpan) -> [Hap<T>]

    public init(_ query: @escaping (TimeSpan) -> [Hap<T>]) {
        self.query = query
    }
}

// MARK: - splitQueries helper

/// Run the query per-cycle and concatenate results.
/// When a span crosses a cycle boundary, each cycle is queried independently
/// so that per-cycle combinators (fastcat, slowcat) work correctly.
public func splitQueries<T>(_ pat: Pattern<T>) -> Pattern<T> {
    Pattern { span in
        span.splitByCycles().flatMap { subSpan in
            pat.query(subSpan)
        }
    }
}

// MARK: - pure / silence

extension Pattern {
    /// A pattern that repeats `value` once per cycle, always.
    /// whole = [floor(t), floor(t)+1); part = queried intersection.
    public static func pure(_ value: T) -> Pattern<T> {
        Pattern { span in
            // For each cycle touched by span, emit one hap.
            var haps: [Hap<T>] = []
            for s in span.splitByCycles() {
                let cycleN = s.begin.floorInt
                let whole  = TimeSpan(Rational(cycleN), Rational(cycleN + 1))
                // part = intersection of whole and queried sub-span
                if let part = whole.intersection(s) {
                    haps.append(Hap(whole: whole, part: part, value: value))
                }
            }
            return haps
        }
    }

    /// A pattern that never emits events (silence).
    public static var silence: Pattern<T> {
        Pattern { _ in [] }
    }
}

// MARK: - map / withValue

extension Pattern {
    public func map<U>(_ f: @escaping (T) -> U) -> Pattern<U> {
        Pattern<U> { span in
            self.query(span).map { $0.withValue(f) }
        }
    }
}

// MARK: - stack

/// Merge multiple patterns: all events from all patterns.
public func stack<T>(_ patterns: [Pattern<T>]) -> Pattern<T> {
    Pattern { span in
        patterns.flatMap { $0.query(span) }
    }
}

public func stack<T>(_ patterns: Pattern<T>...) -> Pattern<T> {
    stack(patterns)
}

// MARK: - fastcat / slowcat

/// Concatenate patterns within one cycle (divide the cycle equally).
/// Each pattern gets an equal sub-division of each cycle.
public func fastcat<T>(_ patterns: [Pattern<T>]) -> Pattern<T> {
    guard !patterns.isEmpty else { return .silence }
    let n = patterns.count
    return splitQueries(Pattern { span in
        // Within one cycle [cycleN, cycleN+1):
        let cycleN = span.begin.floorInt
        let rN = Rational(n)
        var haps: [Hap<T>] = []
        for (i, pat) in patterns.enumerated() {
            // This pattern's slot within the cycle: [cycleN + i/n, cycleN + (i+1)/n)
            let slotBegin = Rational(cycleN) + Rational(i, n)
            let slotEnd   = Rational(cycleN) + Rational(i + 1, n)
            let slotSpan  = TimeSpan(slotBegin, slotEnd)
            guard let querySpan = slotSpan.intersection(span) else { continue }

            // Map the slot span to the sub-pattern's coordinate space.
            // We preserve the outer cycle number (cycleN) so that time-varying
            // sub-patterns (e.g. slowcat) advance correctly across repetitions.
            // Mapping: t_inner = (t_outer - offset) * rN + cycleN
            //   → a full slot [offset, offset+1/rN) maps to [cycleN, cycleN+1)
            //   → slowcat inside the sub-pattern uses cycleN to pick its alternative
            let offset = Rational(cycleN) + Rational(i, n)
            let rCycleN = Rational(cycleN)
            let mappedBegin = (querySpan.begin - offset) * rN + rCycleN
            let mappedEnd   = (querySpan.end   - offset) * rN + rCycleN
            let mappedSpan  = TimeSpan(mappedBegin, mappedEnd)

            let subHaps = pat.query(mappedSpan)

            // Map hap times back to the slot
            // Inverse: t_outer = (t_inner - cycleN) / rN + offset
            for hap in subHaps {
                let mapBack: (Rational) -> Rational = { t in
                    (t - rCycleN) / rN + offset
                }
                let newWhole = hap.whole.map { w in
                    TimeSpan(mapBack(w.begin), mapBack(w.end))
                }
                let newPart = TimeSpan(mapBack(hap.part.begin), mapBack(hap.part.end))
                haps.append(Hap(whole: newWhole, part: newPart, value: hap.value))
            }
        }
        return haps
    })
}

public func fastcat<T>(_ patterns: Pattern<T>...) -> Pattern<T> {
    fastcat(patterns)
}

/// Concatenate patterns across multiple cycles (one pattern per cycle, rotating).
/// e.g. slowcat([a, b]) — cycle 0 plays `a`, cycle 1 plays `b`, cycle 2 plays `a`…
public func slowcat<T>(_ patterns: [Pattern<T>]) -> Pattern<T> {
    guard !patterns.isEmpty else { return .silence }
    let n = patterns.count
    return splitQueries(Pattern { span in
        let cycleN = span.begin.floorInt
        // Pick the pattern for this cycle
        let idx = ((cycleN % n) + n) % n   // handles negative cycles
        let pat = patterns[idx]
        // Offset the query: pattern [0,1) maps to cycle [cycleN, cycleN+1)
        let offset = Rational(cycleN)
        let mappedSpan = TimeSpan(span.begin - offset, span.end - offset)
        let subHaps = pat.query(mappedSpan)
        return subHaps.map { hap in
            let newWhole = hap.whole.map { w in TimeSpan(w.begin + offset, w.end + offset) }
            let newPart  = TimeSpan(hap.part.begin + offset, hap.part.end + offset)
            return Hap(whole: newWhole, part: newPart, value: hap.value)
        }
    })
}

public func slowcat<T>(_ patterns: Pattern<T>...) -> Pattern<T> {
    slowcat(patterns)
}

// MARK: - fast / slow

extension Pattern {
    /// Play the pattern `factor` times faster (compress time).
    public func fast(_ factor: Rational) -> Pattern<T> {
        guard factor > .zero else { return .silence }
        return Pattern { span in
            // Scale the query span by factor, then scale hap times back
            let scaledSpan = TimeSpan(span.begin * factor, span.end * factor)
            return self.query(scaledSpan).map { hap in
                let newWhole = hap.whole.map { w in TimeSpan(w.begin / factor, w.end / factor) }
                let newPart  = TimeSpan(hap.part.begin / factor, hap.part.end / factor)
                return Hap(whole: newWhole, part: newPart, value: hap.value)
            }
        }
    }

    /// Play the pattern `factor` times slower (stretch time).
    public func slow(_ factor: Rational) -> Pattern<T> {
        guard factor > .zero else { return .silence }
        return fast(Rational(1, 1) / factor)
    }

    // Convenience Double overloads
    public func fast(_ factor: Double) -> Pattern<T> {
        fast(Rational(approximating: factor))
    }

    public func slow(_ factor: Double) -> Pattern<T> {
        slow(Rational(approximating: factor))
    }

    public func fast(_ factor: Int) -> Pattern<T> {
        fast(Rational(factor))
    }

    public func slow(_ factor: Int) -> Pattern<T> {
        slow(Rational(factor))
    }
}

// MARK: - rotL / rotR (internal, used by phase-rotation combinator)

extension Pattern {
    /// Rotate pattern left by `offset` cycles (events happen `offset` cycles earlier).
    public func rotL(_ offset: Rational) -> Pattern<T> {
        Pattern { span in
            let shifted = TimeSpan(span.begin + offset, span.end + offset)
            return self.query(shifted).map { hap in
                let newWhole = hap.whole.map { w in TimeSpan(w.begin - offset, w.end - offset) }
                let newPart  = TimeSpan(hap.part.begin - offset, hap.part.end - offset)
                return Hap(whole: newWhole, part: newPart, value: hap.value)
            }
        }
    }

    /// Rotate pattern right by `offset` cycles.
    public func rotR(_ offset: Rational) -> Pattern<T> {
        rotL(-offset)
    }
}

// MARK: - appLeft / appBoth (structural application)

/// Apply a pattern of functions to a pattern of values using the LEFT pattern's structure.
/// The whole/structure of each result hap comes from the function hap.
/// This is how control params combine with the base pattern in Strudel:
///   s("a b").gain("<0.3 0.8>") — structure from s("a b"), gain values from gain pattern.
public func appLeft<A, B>(_ patF: Pattern<(A) -> B>, _ patA: Pattern<A>) -> Pattern<B> {
    Pattern { span in
        let fHaps = patF.query(span)
        var result: [Hap<B>] = []
        for fHap in fHaps {
            // Query value pattern over the whole extent of the function hap
            let querySpan = fHap.whole ?? fHap.part
            let aHaps = patA.query(querySpan)
            for aHap in aHaps {
                // The result's part = intersection of function's part and value's whole/part
                let aWholePart = aHap.whole ?? aHap.part
                guard let combinedPart = fHap.part.intersection(aWholePart) else { continue }
                result.append(Hap(
                    whole: fHap.whole,    // structure from left (function)
                    part:  combinedPart,
                    value: fHap.value(aHap.value)
                ))
            }
        }
        return result
    }
}

/// Apply using BOTH patterns' structures (intersection of wholes).
public func appBoth<A, B>(_ patF: Pattern<(A) -> B>, _ patA: Pattern<A>) -> Pattern<B> {
    Pattern { span in
        let fHaps = patF.query(span)
        var result: [Hap<B>] = []
        for fHap in fHaps {
            let querySpan = fHap.whole ?? fHap.part
            let aHaps = patA.query(querySpan)
            for aHap in aHaps {
                let fWhole = fHap.whole ?? fHap.part
                let aWhole = aHap.whole ?? aHap.part
                guard let combinedWhole = fWhole.intersection(aWhole),
                      let combinedPart  = fHap.part.intersection(aHap.part) else { continue }
                result.append(Hap(
                    whole: combinedWhole,
                    part:  combinedPart,
                    value: fHap.value(aHap.value)
                ))
            }
        }
        return result
    }
}

// MARK: - queryArc convenience

extension Pattern {
    /// Query the pattern over the span [begin, end).
    public func queryArc(_ begin: Rational, _ end: Rational) -> [Hap<T>] {
        query(TimeSpan(begin, end))
    }

    /// Query the first cycle [0, 1).
    public func firstCycle() -> [Hap<T>] {
        queryArc(.zero, .one)
    }
}
