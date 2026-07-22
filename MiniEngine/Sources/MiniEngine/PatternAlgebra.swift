// ---------------------------------------------------------------------------
// PatternAlgebra.swift — Fase 2 / Tier 3: Pattern combinators
//
// Clean-room from public documentation (strudel.cc/learn, Tidal papers).
// No Strudel JS source was read.
//
// Implements: rev, ply, every, sometimes/often/rarely, off, jux, struct
// ---------------------------------------------------------------------------

import Foundation

// MARK: - PRNG (deterministic, seed-based)

/// A minimal xorshift64 PRNG for deterministic per-event randomness.
/// Seeded by (cycle, eventIndex) to ensure stable, reproducible results.
///
/// Strudel's internal `rand` signal is time-based and non-deterministic from
/// our vantage point (AGPL, clean-room constraint). Our `sometimes`/`often`/`rarely`
/// therefore cannot produce bit-identical output to Strudel per-event; instead,
/// we guarantee:
///   - Determinism: same seed → same sequence, every time.
///   - Correct probability: measured over many cycles, the rate converges to the
///     specified probability (0.5, 0.75, 0.25).
///
/// Seeding formula: seed = hash(cycle ⊕ eventIndex * 2654435761)
struct MiniPRNG {
    private var state: UInt64

    /// Seed with cycle number and event index (position within that cycle).
    init(cycle: Int, eventIndex: Int) {
        // splitmix64 mixing to produce a well-distributed seed from two ints
        var h = UInt64(bitPattern: Int64(cycle)) &* 0x9e3779b97f4a7c15
        h ^= UInt64(bitPattern: Int64(eventIndex)) &* 0x6c62272e07bb0142
        h ^= h >> 30
        h = h &* 0xbf58476d1ce4e5b9
        h ^= h >> 27
        h = h &* 0x94d049bb133111eb
        h ^= h >> 31
        // Ensure non-zero state for xorshift
        self.state = h == 0 ? 0xcafebabe : h
    }

    /// Advance state and return a value in [0, 1).
    mutating func nextDouble() -> Double {
        // xorshift64
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        // Map to [0, 1) using upper 53 bits
        return Double(x >> 11) / Double(1 << 53)
    }
}

// MARK: - rev

extension Pattern {
    /// Reverse the pattern within each cycle.
    /// Events that were at time t within [cycleN, cycleN+1) are mapped to
    /// time (cycleN+1 - duration) - (t - cycleN) = cycleN+1 - (t - cycleN) - duration
    ///
    /// Public semantics: rev mirrors time within each cycle.
    ///   s("pad bell").rev → bell fires first (at [0, 1/2)), pad fires second ([1/2, 1)).
    public var rev: Pattern<T> {
        splitQueries(Pattern { span in
            let cycleN   = span.begin.floorInt
            let cycleEnd = Rational(cycleN + 1)

            // Mirror a time point about the cycle midpoint:
            //   mirror(t) = cycleEnd - (t - cycleStart) = cycleEnd - t + cycleStart
            let mirror: (Rational) -> Rational = { t in
                cycleEnd - t + Rational(cycleN)
            }

            // We query the mirrored span (swapping begin/end after mirror)
            let mirroredBegin = mirror(span.end)
            let mirroredEnd   = mirror(span.begin)
            let mirroredSpan  = TimeSpan(mirroredBegin, mirroredEnd)

            return self.query(mirroredSpan).map { hap in
                let newWhole = hap.whole.map { w in
                    TimeSpan(mirror(w.end), mirror(w.begin))
                }
                let newPart = TimeSpan(mirror(hap.part.end), mirror(hap.part.begin))
                return Hap(whole: newWhole, part: newPart, value: hap.value)
            }
        })
    }
}

// MARK: - ply

extension Pattern {
    /// Repeat each event `n` times within its structural duration.
    /// Each hap is subdivided into n equal sub-events.
    /// ply(2) on s("pad bell") → 4 events (pad×2, bell×2).
    public func ply(_ n: Int) -> Pattern<T> {
        guard n > 0 else { return .silence }
        if n == 1 { return self }

        return Pattern { span in
            let baseHaps = self.query(span)
            var result: [Hap<T>] = []

            for hap in baseHaps {
                // The structural span of this hap (where it "lives")
                let structural = hap.whole ?? hap.part
                let duration   = structural.end - structural.begin
                let subDur     = duration / Rational(n)

                for i in 0..<n {
                    let subBegin = structural.begin + subDur * Rational(i)
                    let subEnd   = structural.begin + subDur * Rational(i + 1)
                    let subWhole = TimeSpan(subBegin, subEnd)

                    // Only emit sub-events that overlap the queried span
                    guard let subPart = subWhole.intersection(span) else { continue }
                    result.append(Hap(whole: subWhole, part: subPart, value: hap.value))
                }
            }
            return result
        }
    }
}

// MARK: - every

extension Pattern {
    /// Apply transformation `f` every `n` cycles, starting at cycle 0.
    /// Cycles 0, n, 2n, … get f applied; other cycles are unchanged.
    ///
    /// Convention confirmed with oracle: cycle 0 of each block of n is transformed.
    /// E.g. every(4, fast(2)): cycles 0,4,8,... have 4 events; 1,2,3,5,6,7,... have 2.
    public func every(_ n: Int, _ f: @escaping (Pattern<T>) -> Pattern<T>) -> Pattern<T> {
        guard n > 0 else { return f(self) }

        return splitQueries(Pattern { span in
            let cycleN = span.begin.floorInt
            // cycle 0 of each block of n → transform; otherwise identity
            let inBlock = ((cycleN % n) + n) % n
            if inBlock == 0 {
                return f(self).query(span)
            } else {
                return self.query(span)
            }
        })
    }
}

// MARK: - sometimes / often / rarely

extension Pattern {
    /// Apply `f` to this pattern with probability `prob` per event.
    ///
    /// Implementation: for each cycle, query both the original and the transformed
    /// pattern. For each original hap, use a deterministic PRNG seeded by
    /// (cycle, eventIndex within cycle) to decide whether to emit the original
    /// or the corresponding transformed haps.
    ///
    /// Uses a deterministic PRNG seeded by (cycleNumber, eventIndex).
    /// This ensures reproducibility; note that Strudel's internal RNG is
    /// time-based and non-deterministic from our perspective (clean-room).
    /// Equivalence is statistical (proportion), not bit-for-bit per event.
    ///
    /// - Parameters:
    ///   - prob: Probability in [0, 1] that the transformation is applied.
    ///   - f: Transformation to apply probabilistically.
    public func sometimesBy(_ prob: Double, _ f: @escaping (Pattern<T>) -> Pattern<T>) -> Pattern<T> {
        guard prob > 0 else { return self }
        guard prob < 1 else { return f(self) }

        let transformed = f(self)

        return splitQueries(Pattern { span in
            let cycleN   = span.begin.floorInt
            let origHaps = self.query(span)
            let xformHaps = transformed.query(span)
            var result: [Hap<T>] = []

            // Sort both by onset for stable indexing
            let origSorted  = origHaps.sorted  { $0.part.begin < $1.part.begin }
            let xformSorted = xformHaps.sorted { $0.part.begin < $1.part.begin }

            // For each original hap, flip a coin
            for (idx, hap) in origSorted.enumerated() {
                var rng = MiniPRNG(cycle: cycleN, eventIndex: idx)
                let r = rng.nextDouble()
                if r < prob {
                    // Emit the transformed hap(s) that land in this hap's window
                    // We use the whole structural extent of the original hap as the window
                    let window = hap.whole ?? hap.part
                    let matching = xformSorted.filter { xhap in
                        let xbegin = xhap.whole?.begin ?? xhap.part.begin
                        return xbegin >= window.begin && xbegin < window.end
                    }
                    if matching.isEmpty {
                        // If no matching transformed hap, emit the original
                        result.append(hap)
                    } else {
                        result.append(contentsOf: matching)
                    }
                } else {
                    result.append(hap)
                }
            }
            return result
        })
    }

    /// Apply `f` with probability 0.5 (sometimes).
    public func sometimes(_ f: @escaping (Pattern<T>) -> Pattern<T>) -> Pattern<T> {
        sometimesBy(0.5, f)
    }

    /// Apply `f` with probability 0.75 (often).
    public func often(_ f: @escaping (Pattern<T>) -> Pattern<T>) -> Pattern<T> {
        sometimesBy(0.75, f)
    }

    /// Apply `f` with probability 0.25 (rarely).
    public func rarely(_ f: @escaping (Pattern<T>) -> Pattern<T>) -> Pattern<T> {
        sometimesBy(0.25, f)
    }
}

// MARK: - off

extension Pattern {
    /// Stack the original pattern with a time-shifted copy that has `f` applied.
    /// off(t, f) = stack(self, f(self).rotR(t))
    ///
    /// The shifted copy appears t cycles LATER than the original (rotR shifts events right).
    /// E.g. off(0.25, gain(0.5)): original events at [0,1), + gain=0.5 copy shifted +0.25 cycles.
    ///
    /// Oracle confirmed (from Strudel black-box):
    ///   off(0.25, ...) → copy has whole=[-3/4, 1/4) and [1/4, 5/4), i.e. shifted RIGHT by 0.25.
    ///   Semantics: the copy of the pattern is displaced forward by t cycles, creating an echo effect.
    public func off(_ t: Rational, _ f: @escaping (Pattern<T>) -> Pattern<T>) -> Pattern<T> {
        let shifted = f(self).rotR(t)
        return stack(self, shifted)
    }

    public func off(_ t: Double, _ f: @escaping (Pattern<T>) -> Pattern<T>) -> Pattern<T> {
        off(Rational(approximating: t), f)
    }
}

// MARK: - jux

extension Pattern where T == [String: ControlValue] {
    /// Split into stereo: original at pan=0 (left), f(copy) at pan=1 (right).
    ///
    /// Oracle confirmed: jux uses pan=0 for original and pan=1 for the transformed copy.
    ///
    /// Implementation: stack(self.pan(0), f(self).pan(1))
    public func jux(_ f: @escaping (ControlPattern) -> ControlPattern) -> ControlPattern {
        let left  = self.pan(0.0)
        let right = f(self).pan(1.0)
        return stack(left, right)
    }
}

// MARK: - struct

extension Pattern where T == [String: ControlValue] {
    /// Apply a boolean structure pattern as a gate.
    /// Events fire only at positions where the mask has `true` values.
    ///
    /// The mask is a Pattern<Bool> (or Pattern<String> with "t"/"f"/"~").
    /// Strudel's `struct` takes a boolean pattern and uses it to gate the base.
    ///
    /// Oracle: s("bell").struct(fastcat(true, false, true, true))
    ///   → 3 events at slots 0, 2, 3 (slot 1 is silent/false)
    public func structGate(_ mask: Pattern<Bool>) -> ControlPattern {
        Pattern { span in
            let baseHaps = self.query(span)
            var result: [Hap<[String: ControlValue]>] = []

            for baseHap in baseHaps {
                let querySpan = baseHap.whole ?? baseHap.part
                let maskHaps  = mask.query(querySpan)

                for maskHap in maskHaps {
                    guard maskHap.value else { continue }
                    let maskExtent = maskHap.whole ?? maskHap.part
                    guard let newPart = baseHap.part.intersection(maskExtent) else { continue }
                    // The structural whole comes from the mask (the rhythm drives timing)
                    result.append(Hap(
                        whole: maskHap.whole,
                        part:  newPart,
                        value: baseHap.value
                    ))
                }
            }
            return result
        }
    }

    /// Parse a mini-notation string as a boolean mask and apply as struct gate.
    /// "t" and "true" → true; "~", "f", "false" → false (silence).
    public func structGate(_ miniNotation: String) -> ControlPattern {
        let mask: Pattern<Bool> = parseMiniAsBool(miniNotation)
        return structGate(mask)
    }
}

/// Parse a mini-notation string into a Pattern<Bool>.
/// "t"/"true" → true at the timing slot; "~"/"f"/"false" → silence (no event).
///
/// The result preserves the timing structure of the mini-notation.
/// Each "t" slot becomes a Bool=true hap at exactly that slot's position.
func parseMiniAsBool(_ notation: String) -> Pattern<Bool> {
    // Map string tokens to Bool, keeping timing from the outer (string) pattern.
    // We use the outer hap's whole/part as the Bool hap's whole/part.
    parseMini(notation).mapTokensToBool()
}

// MARK: - mapTokensToBool for Pattern<String>

extension Pattern where T == String {
    /// Convert each string token to a Bool hap, preserving timing from the outer pattern.
    /// "t"/"true" → Hap<Bool>(whole=outer.whole, part=outer.part, value=true)
    /// Anything else → dropped (silence)
    func mapTokensToBool() -> Pattern<Bool> {
        Pattern<Bool> { span in
            self.query(span).compactMap { hap -> Hap<Bool>? in
                switch hap.value.lowercased() {
                case "t", "true":
                    return Hap<Bool>(whole: hap.whole, part: hap.part, value: true)
                default:
                    return nil  // silence
                }
            }
        }
    }
}

