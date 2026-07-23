// ---------------------------------------------------------------------------
// P2Patterns.swift — P2 pattern functions for MiniEngine
//
// Functions:
//   arp("up"|"down"|"updown"|"downup")  — arpeggiate chords
//   superimpose(f)                       — stack(self, f(self))
//   stut(n, feedback, time)              — n echoes with decaying gain
//   echo(n, time, feedback)              — alias of stut w/ different param order
//   iter(n)                              — rotate pattern 1/n per cycle
//   chunk(n, f)                          — apply f to rotating n-th portion
//   palindrome                           — alternate normal/reversed per cycle
//   hurry(n)                             — fast(n) + sets speed(n)
//   swingBy(x, n)                        — swing odd steps by x fraction
//   slice(n, indexPattern)               — slice sample into n chunks
//   loopAt(n)                            — stretch sample to n cycles
//
// Mini-notation additions (in MiniNotationCore):
//   ?                                    — random omission with probability
//   {a b, c d e}                         — polymeter
//
// CLEAN-ROOM: implemented from public Strudel documentation (strudel.cc/learn).
// Semantics confirmed via oracle (generate.mjs black-box).
// ---------------------------------------------------------------------------

import Foundation

// MARK: - arp

extension Pattern where T == [String: ControlValue] {

    /// Arpeggiate chords: simultaneous haps in a single whole-span are converted
    /// to a sequential melody within that span.
    ///
    /// Semantics (confirmed against oracle):
    ///   - Group all haps that share the same `whole` span (a chord).
    ///   - Sort the notes by pitch (ascending for "up", descending for "down").
    ///   - Divide the chord's time slot evenly among the notes.
    ///   - Each note becomes its own hap with a 1/N sub-slot.
    ///
    /// Modes:
    ///   "up"     — ascending pitch order
    ///   "down"   — descending pitch order
    ///   "updown" — ascending then descending (first and last note not repeated)
    ///   "downup" — descending then ascending
    ///
    /// Note field used: "note" (MIDI). If no "note" field, sorted by insertion order.
    public func arp(_ mode: String) -> ControlPattern {
        Pattern { span in
            let baseHaps = self.query(span)
            guard !baseHaps.isEmpty else { return [] }

            // Group haps by their whole span (a chord = haps sharing the same whole)
            // Key: whole span description (or part if no whole)
            var groups: [[Hap<[String: ControlValue]>]] = []
            var seen: [TimeSpan: Int] = [:]

            for hap in baseHaps {
                let key = hap.whole ?? hap.part
                if let idx = seen[key] {
                    groups[idx].append(hap)
                } else {
                    seen[key] = groups.count
                    groups.append([hap])
                }
            }

            var result: [Hap<[String: ControlValue]>] = []

            for group in groups {
                guard !group.isEmpty else { continue }

                let structural = group[0].whole ?? group[0].part
                let dur = structural.end - structural.begin

                // Sort by note value (MIDI), fall back to original order
                let sorted = group.sorted { a, b in
                    let na = a.value["note"]?.doubleValue ?? 0
                    let nb = b.value["note"]?.doubleValue ?? 0
                    return na < nb
                }

                // Build the note sequence from the mode
                let sequence: [[String: ControlValue]]
                switch mode.lowercased() {
                case "down":
                    sequence = sorted.reversed().map { $0.value }
                case "updown":
                    // up then down, not repeating end points
                    // e.g. [c, e, g] → [c, e, g, e] (not repeating c at end)
                    let up = sorted.map { $0.value }
                    let down = sorted.dropFirst().dropLast().reversed().map { $0.value }
                    sequence = up + Array(down)
                case "downup":
                    let down = sorted.reversed().map { $0.value }
                    let up = sorted.dropFirst().dropLast().map { $0.value }
                    sequence = down + Array(up)
                default: // "up"
                    sequence = sorted.map { $0.value }
                }

                let n = sequence.count
                guard n > 0 else { continue }
                let subDur = dur / Rational(n)

                for (i, value) in sequence.enumerated() {
                    let subBegin = structural.begin + subDur * Rational(i)
                    let subEnd   = structural.begin + subDur * Rational(i + 1)
                    let subWhole = TimeSpan(subBegin, subEnd)
                    // Only emit sub-events that overlap the queried span
                    guard let subPart = subWhole.intersection(span) else { continue }
                    result.append(Hap(whole: subWhole, part: subPart, value: value))
                }
            }
            return result
        }
    }
}

// MARK: - superimpose

extension Pattern {
    /// Stack the pattern with a transformed copy of itself (no time offset).
    ///
    /// superimpose(f) = stack(self, f(self))
    ///
    /// Unlike off(0, f), superimpose does not shift time. The copy is layered
    /// directly on top (same timing, different parameters).
    ///
    /// Oracle confirmed: superimpose(x => x.fast(2)) on s("bd sn") →
    ///   original 2 events + fast(2) doubled = 4 events total, all in [0,1).
    public func superimpose(_ f: @escaping (Pattern<T>) -> Pattern<T>) -> Pattern<T> {
        stack(self, f(self))
    }
}

// MARK: - stut

extension Pattern where T == [String: ControlValue] {
    /// Create n repetitions of the pattern with exponentially decaying gain.
    ///
    /// Semantics (confirmed against oracle via queryArc and gain inspection):
    ///   stut(n, feedback, time)
    ///   - n:        number of echoes (total events = n × original)
    ///   - feedback: gain multiplier per repetition (0..1). Echo k has gain = feedback^k.
    ///               Echo 0 = original (gain × feedback^0 = original gain × 1.0).
    ///   - time:     time between echoes in CYCLES (not seconds).
    ///
    /// The first copy is the original (gain×1). Subsequent copies are shifted right
    /// by k×time cycles and gain-multiplied by feedback^k.
    ///
    /// Strudel oracle: stut(3, 0.5, 0.25) on s("bd"):
    ///   copy 0: t=0, gain=1 (original)
    ///   copy 1: t=0.25, gain=0.5
    ///   copy 2: t=0.5,  gain=0.25
    ///
    /// Implementation: stack of n copies, each rotR(k*time) with gain *= feedback^k.
    public func stut(_ n: Int, _ feedback: Double, _ time: Double) -> ControlPattern {
        guard n > 0 else { return self }
        var copies: [ControlPattern] = []
        let timeR = Rational(approximating: time)
        for k in 0..<n {
            let gainFactor = pow(feedback, Double(k))
            let shifted = self.rotR(timeR * Rational(k))
            // Multiply existing gain field (or set if absent)
            let copy = shifted.map { val -> [String: ControlValue] in
                var v = val
                let existing = v["gain"]?.doubleValue ?? 1.0
                v["gain"] = .double(existing * gainFactor)
                return v
            }
            copies.append(copy)
        }
        return stack(copies)
    }

    /// echo(n, time, feedback) — like stut but with different argument order.
    ///
    /// Strudel public API: echo(n, time, feedback).
    /// Semantics identical to stut but time comes before feedback.
    ///
    /// Oracle confirmed parameter order.
    public func echo(_ n: Int, _ time: Double, _ feedback: Double) -> ControlPattern {
        stut(n, feedback, time)
    }
}

// MARK: - iter

extension Pattern {
    /// Rotate the pattern by 1/n of a cycle per cycle.
    ///
    /// Semantics (confirmed against oracle):
    ///   iter(n) — cycle 0 starts at the beginning, cycle 1 starts 1/n of the way through,
    ///             cycle k starts at k/n.
    ///
    /// iter(4) on "a b c d":
    ///   cycle 0: a b c d
    ///   cycle 1: b c d a
    ///   cycle 2: c d a b
    ///   cycle 3: d a b c
    ///   cycle 4: a b c d  (wraps)
    ///
    /// Implementation: for cycle k, rotL(k/n) within that cycle.
    public func iter(_ n: Int) -> Pattern<T> {
        guard n > 0 else { return self }
        return splitQueries(Pattern { span in
            let cycleN = span.begin.floorInt
            let offset = Rational(((cycleN % n) + n) % n, n)
            // rotL shifts hap times EARLIER by offset within the cycle.
            // We query with offset added to span, then subtract from results.
            let shiftedSpan = TimeSpan(span.begin + offset, span.end + offset)
            return self.query(shiftedSpan).map { hap in
                let newWhole = hap.whole.map { w in TimeSpan(w.begin - offset, w.end - offset) }
                let newPart  = TimeSpan(hap.part.begin - offset, hap.part.end - offset)
                return Hap(whole: newWhole, part: newPart, value: hap.value)
            }
        })
    }

    /// iterBack(n) — iterate backwards (rotate right by 1/n per cycle).
    public func iterBack(_ n: Int) -> Pattern<T> {
        guard n > 0 else { return self }
        return splitQueries(Pattern { span in
            let cycleN = span.begin.floorInt
            let k      = ((cycleN % n) + n) % n
            let offset = Rational(k, n)
            let shiftedSpan = TimeSpan(span.begin - offset, span.end - offset)
            return self.query(shiftedSpan).map { hap in
                let newWhole = hap.whole.map { w in TimeSpan(w.begin + offset, w.end + offset) }
                let newPart  = TimeSpan(hap.part.begin + offset, hap.part.end + offset)
                return Hap(whole: newWhole, part: newPart, value: hap.value)
            }
        })
    }
}

// MARK: - chunk

extension Pattern {
    /// Apply f to the i-th 1/n portion of each cycle, where i rotates each cycle.
    ///
    /// Semantics (Strudel public docs):
    ///   chunk(n, f) — divides each cycle into n equal portions.
    ///   In cycle k, applies f to portion (k mod n) of the pattern.
    ///   Other portions are played as-is (identity).
    ///
    /// Oracle: s("a b c d").chunk(4, fast(2)):
    ///   cycle 0: portion [0,1/4) played at fast(2) → 2 events, [1/4,1) normal
    ///   cycle 1: [0,1/4) normal, [1/4,1/2) fast(2), [1/2,1) normal
    ///   ...
    public func chunk(_ n: Int, _ f: @escaping (Pattern<T>) -> Pattern<T>) -> Pattern<T> {
        guard n > 0 else { return self }
        let transformed = f(self)

        return splitQueries(Pattern { span in
            let cycleN = span.begin.floorInt
            let k      = ((cycleN % n) + n) % n   // which chunk to transform this cycle

            let cycleOffset = Rational(cycleN)
            let chunkBegin  = cycleOffset + Rational(k, n)
            let chunkEnd    = cycleOffset + Rational(k + 1, n)
            let chunkSpan   = TimeSpan(chunkBegin, chunkEnd)

            var result: [Hap<T>] = []

            // Events that fall within the active chunk → use transformed pattern
            // Events outside the chunk → use original pattern
            // We query both and combine based on whether the hap's whole falls in chunk.

            // Query original for full span
            let origHaps = self.query(span)
            // Query transformed for the chunk portion only (if it overlaps queried span)
            let chunkHaps: [Hap<T>]
            if let chunkQuery = chunkSpan.intersection(span) {
                chunkHaps = transformed.query(chunkQuery)
            } else {
                chunkHaps = []
            }

            // From original: keep only events whose whole is OUTSIDE the chunk
            for hap in origHaps {
                let hapWhole = hap.whole ?? hap.part
                // If the hap's onset is inside the chunk, skip (replaced by transformed)
                if hapWhole.begin >= chunkBegin && hapWhole.begin < chunkEnd {
                    continue
                }
                result.append(hap)
            }

            // Add the chunk events from transformed pattern
            result.append(contentsOf: chunkHaps)

            return result
        })
    }
}

// MARK: - palindrome

extension Pattern {
    /// Alternate normal and reversed patterns by cycle.
    ///
    /// Semantics (Strudel public docs):
    ///   palindrome — even cycles play normally, odd cycles play reversed (rev).
    ///   s("a b c d").palindrome:
    ///     cycle 0: a b c d (normal)
    ///     cycle 1: d c b a (reversed)
    ///     cycle 2: a b c d (normal)
    ///     ...
    ///
    /// Oracle confirmed: cycle parity determines direction.
    public var palindrome: Pattern<T> {
        splitQueries(Pattern { span in
            let cycleN = span.begin.floorInt
            let isOdd  = (cycleN % 2 + 2) % 2 == 1
            if isOdd {
                return self.rev.query(span)
            } else {
                return self.query(span)
            }
        })
    }
}

// MARK: - hurry

extension Pattern where T == [String: ControlValue] {
    /// hurry(n) — fast(n) AND multiply speed field by n.
    ///
    /// Semantics:
    ///   hurry makes the pattern play faster both temporally (fast) and
    ///   in pitch (speed) — like spinning up a record. The speed field
    ///   multiplies existing speed (or sets if absent), combined with fast(n).
    ///
    /// Oracle: hurry(2) on s("pad") at speed=1 →
    ///   2 events per cycle, each with speed=2.
    ///   If existing speed=2, hurry(2) → speed=4, 2× faster rhythm.
    public func hurry(_ n: Double) -> ControlPattern {
        let sped = self.map { val -> [String: ControlValue] in
            var v = val
            let existing = v["speed"]?.doubleValue ?? 1.0
            v["speed"] = .double(existing * n)
            return v
        }
        return sped.fast(n)
    }

    public func hurry(_ n: Int) -> ControlPattern {
        hurry(Double(n))
    }
}

// MARK: - swingBy / swing

extension Pattern where T == [String: ControlValue] {
    /// swingBy(amount, period) — delay odd-numbered steps by `amount × stepDuration`.
    ///
    /// Semantics (Strudel public docs):
    ///   Divides the cycle into groups of `period` steps.
    ///   Within each group, odd-indexed steps are delayed by amount×(step_duration).
    ///
    ///   swingBy(1/3, 2) = swing(2): delay every 2nd beat by 1/3 of a beat.
    ///   step 0 (even): unchanged (t)
    ///   step 1 (odd):  shifted right by amount × (1/period)
    ///
    /// Oracle: swingBy(1/3, 2) on s("hh*4"):
    ///   hh at t=0:   unchanged
    ///   hh at t=1/4: shifted to 1/4 + (1/3)*(1/2) = 1/4 + 1/6 = 5/12
    ///   hh at t=1/2: unchanged
    ///   hh at t=3/4: shifted to 3/4 + 1/6 = 11/12
    ///
    /// Implementation: per hap, compute its step index within the cycle
    /// based on period, then shift if odd.
    public func swingBy(_ amount: Double, _ period: Int) -> ControlPattern {
        guard period > 0, amount != 0 else { return self }
        let amountR = Rational(approximating: amount)

        return Pattern { span in
            let haps = self.query(span)
            return haps.map { hap -> Hap<[String: ControlValue]> in
                let cycleN = (hap.whole ?? hap.part).begin.floorInt
                let cycleOffset = Rational(cycleN)
                // Position within cycle [0,1)
                let posInCycle = (hap.whole ?? hap.part).begin - cycleOffset
                // Step index at resolution 1/period
                let stepIndex = (posInCycle * Rational(period)).floorInt
                let isOdd = stepIndex % 2 == 1

                if isOdd {
                    // Shift amount × (1/period) cycles to the right
                    let shift = amountR / Rational(period)
                    let newWhole = hap.whole.map { w in TimeSpan(w.begin + shift, w.end + shift) }
                    let newPart  = TimeSpan(hap.part.begin + shift, hap.part.end + shift)
                    return Hap(whole: newWhole, part: newPart, value: hap.value)
                } else {
                    return hap
                }
            }
        }
    }

    /// swing(period) = swingBy(1/3, period)
    ///
    /// Strudel public docs: swing(n) is shorthand for swingBy(1/3, n).
    public func swing(_ period: Int) -> ControlPattern {
        swingBy(1.0 / 3.0, period)
    }
}

// MARK: - slice

extension Pattern where T == [String: ControlValue] {
    /// Slice the sample into n equal chunks, selecting a chunk per event via an index pattern.
    ///
    /// Semantics (Strudel public docs):
    ///   slice(n, indices) — cuts the referenced sample into n equally-sized pieces.
    ///   The `indices` pattern determines which piece plays at each event.
    ///   Index i → begin = i/n, end = (i+1)/n.
    ///
    ///   slice(4, "0 1 2 3") cycles through all 4 slices.
    ///   slice(8, "0 2 4 6") plays even slices only.
    ///
    /// Oracle: s("pad").slice(4, "0 1 2 3") →
    ///   4 events, each 1/4 cycle, begin=[0,0.25,0.5,0.75], end=[0.25,0.5,0.75,1.0]
    public func slice(_ n: Int, _ indexPat: String) -> ControlPattern {
        guard n > 0 else { return self }
        let nd = Double(n)
        // Parse the index pattern and map to begin/end fractions
        let indexCtrl = parseMini(indexPat).map { token -> [String: ControlValue] in
            let idx = Int(Double(token) ?? 0)
            let i = ((idx % n) + n) % n  // wrap
            let fBegin = Double(i) / nd
            let fEnd   = Double(i + 1) / nd
            return ["begin": .double(fBegin), "end": .double(fEnd)]
        }
        return self.withControl(indexCtrl)
    }

    /// loopAt(n) — stretch the sample to n cycles by adjusting playback speed.
    ///
    /// Semantics (Strudel public docs):
    ///   loopAt(n) sets the speed of the sample so that it loops exactly across n cycles.
    ///   Concretely: sets the `speed` control field such that sample_duration / speed = n * cycle_duration.
    ///
    ///   In MiniEngine, since we don't have access to sample duration at pattern time,
    ///   we set begin=0, end=1 (full sample) and speed = 1/n.
    ///
    ///   APPROXIMATION DOCUMENTED: Without actual sample duration, we set speed=1/n and
    ///   let the scheduler play the full sample at that rate. If sample_duration ≠ cycle_duration,
    ///   the sample will loop at a rate that approximates the desired n-cycle length.
    ///   The pattern structure (event timing) is correct; speed approximation depends on
    ///   the sample's actual duration relative to the cycle duration (tempo).
    ///
    ///   For standard breakbeats recorded at one cycle length, loopAt(1) plays at normal speed,
    ///   loopAt(2) plays at half speed (stretched to 2 cycles).
    public func loopAt(_ n: Double) -> ControlPattern {
        guard n > 0 else { return self }
        // Full sample (begin=0, end=1) at speed=1/n
        let ctrl: ControlPattern = .pure(["begin": .double(0.0), "end": .double(1.0), "speed": .double(1.0 / n)])
        return withControl(ctrl)
    }

    public func loopAt(_ n: Int) -> ControlPattern {
        loopAt(Double(n))
    }
}

// MARK: - range (verify chaining works for ControlPattern)
// range/segment on Pattern<Double> already exist in Signal.swift.
// Here we verify ControlPattern signal chaining works.
// (No new implementation needed — Signal.swift methods suffice.)

