// ---------------------------------------------------------------------------
// EuclidPattern — Euclidean rhythm generator using Bjorklund's algorithm.
//
// Clean-room implementation from:
//   • Toussaint, G.T. (2005) "The Euclidean Algorithm Generates Traditional
//     Musical Rhythms" (public paper available at ircam.fr)
//   • E. Bjorklund (2003) "A Note on the Calculation of Musical Intervals"
//   • strudel.cc/learn (public documentation)
//
// euclid(k, n)      → k onsets distributed evenly across n steps
// euclid(k, n, rot) → same, rotated by rot steps
//
// Usage:
//   s("bell").euclid(3, 8)       → [x . . x . . x .]
//   s("bell").euclid(3, 8, 2)    → [. . x . . x . x]
// ---------------------------------------------------------------------------

// MARK: - Bjorklund algorithm

/// Generate a Euclidean rhythm as a boolean array of length `n`.
/// `k` is the number of onsets; `n` is the total number of steps.
/// Returns an array of `n` Booleans where `true` = onset.
///
/// Algorithm: iterative Bjorklund recursive group-merging.
/// Each iteration pairs groups and remainders, reducing total groups.
/// This matches the Strudel oracle's output exactly.
public func euclideanRhythm(k: Int, n: Int) -> [Bool] {
    guard n > 0 else { return [] }
    guard k > 0 else { return Array(repeating: false, count: n) }
    let k = min(k, n)   // clamp

    if k == n { return Array(repeating: true, count: n) }

    // Build initial groups and remainders
    // groups = k groups of [1]; remainders = (n-k) groups of [0]
    var groups: [[Int]] = (0..<k).map { _ in [1] }
    var remainders: [[Int]] = (0..<(n - k)).map { _ in [0] }

    while remainders.count > 1 {
        let pairs = min(groups.count, remainders.count)

        // Merge each group[i] with remainders[i]
        var newGroups: [[Int]] = []
        for i in 0..<pairs {
            newGroups.append(groups[i] + remainders[i])
        }

        // Leftovers: whichever list was longer
        let leftovers: [[Int]]
        if groups.count > remainders.count {
            leftovers = Array(groups[remainders.count...])
        } else {
            leftovers = Array(remainders[groups.count...])
        }

        groups = newGroups
        remainders = leftovers
    }

    let flat = (groups + remainders).flatMap { $0 }
    return flat.map { $0 == 1 }
}

/// Rotate a sequence right by `amount` steps (onsets shift forward = rotate right).
/// This matches Strudel's euclidRot semantics where rot=2 shifts each onset
/// forward by 2 steps (equivalent to rotating the boolean array to the right).
public func rotateRight<T>(_ seq: [T], by amount: Int) -> [T] {
    guard !seq.isEmpty else { return seq }
    let n = seq.count
    let rot = ((amount % n) + n) % n
    if rot == 0 { return seq }
    return Array(seq[(n - rot)...] + seq[..<(n - rot)])
}

// MARK: - euclid combinator on ControlPattern

extension Pattern where T == [String: ControlValue] {
    /// Apply a Euclidean rhythm gate: emit events only on the `k` Euclidean
    /// onset positions among `n` equal subdivisions of each cycle.
    ///
    /// - Parameters:
    ///   - k:   Number of onsets.
    ///   - n:   Number of steps per cycle.
    ///   - rot: Rotation offset (default 0).
    public func euclid(_ k: Int, _ n: Int, _ rot: Int = 0) -> Pattern<T> {
        let rhythm = rotateRight(euclideanRhythm(k: k, n: n), by: rot)

        // Build a boolean pattern: fastcat of n steps, true where onset
        let stepPats: [Pattern<Bool>] = rhythm.map { on in
            on ? .pure(true) : .silence
        }
        let gate: Pattern<Bool> = fastcat(stepPats)

        // Apply gate: for each hap in self, emit only if gate is true at that time
        return Pattern { span in
            let baseHaps = self.query(span)
            var result: [Hap<T>] = []
            for baseHap in baseHaps {
                let querySpan = baseHap.whole ?? baseHap.part
                let gateHaps = gate.query(querySpan)
                for gateHap in gateHaps {
                    // gateHap is only emitted if onset (silence = no hap)
                    let gateExtent = gateHap.whole ?? gateHap.part
                    guard let newPart = baseHap.part.intersection(gateExtent) else { continue }
                    result.append(Hap(
                        whole: baseHap.whole,
                        part:  newPart,
                        value: baseHap.value
                    ))
                }
            }
            return result
        }
    }
}
