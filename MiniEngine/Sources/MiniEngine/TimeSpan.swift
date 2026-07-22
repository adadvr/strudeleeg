// ---------------------------------------------------------------------------
// TimeSpan — contiguous interval [begin, end) in rational time.
// Based on Tidal Cycles / Strudel public model.
// ---------------------------------------------------------------------------

/// A half-open interval [begin, end) in rational cycle-time.
public struct TimeSpan: Hashable, CustomStringConvertible, Sendable {
    public let begin: Rational
    public let end: Rational

    public init(_ begin: Rational, _ end: Rational) {
        self.begin = begin
        self.end   = end
    }

    /// Duration of this span.
    public var duration: Rational { end - begin }

    /// True if begin < end (non-degenerate).
    public var isValid: Bool { begin < end }

    /// Returns the intersection of two spans, or nil if they do not overlap.
    public func intersection(_ other: TimeSpan) -> TimeSpan? {
        let b = Swift.max(begin, other.begin)
        let e = Swift.min(end,   other.end)
        return b < e ? TimeSpan(b, e) : nil
    }

    /// Returns true if point t is inside [begin, end).
    public func contains(_ t: Rational) -> Bool {
        t >= begin && t < end
    }

    // MARK: - Cycle helpers

    /// Whole-number cycles covered by this span.
    public var cycleRange: ClosedRange<Int> {
        begin.floorInt ... Swift.max(begin.floorInt, (end - Rational(1, 1_000_000)).floorInt)
    }

    /// The span clipped to a single cycle [n, n+1).
    public static func cycleSpan(_ n: Int) -> TimeSpan {
        TimeSpan(Rational(n), Rational(n + 1))
    }

    /// Split this span at every integer boundary, returning one sub-span per cycle.
    public func splitByCycles() -> [TimeSpan] {
        var result: [TimeSpan] = []
        var current = begin.floorInt
        var s = begin
        while s < end {
            let e = Swift.min(end, Rational(current + 1))
            if s < e { result.append(TimeSpan(s, e)) }
            current += 1
            s = Rational(current)
        }
        return result
    }

    public var description: String { "[\(begin), \(end))" }
}
