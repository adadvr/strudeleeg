// ---------------------------------------------------------------------------
// Hap — one event returned by a Pattern query.
// Based on Tidal Cycles / Strudel public model.
//
// • whole — the full structural span of the event (nil for continuous signals).
// • part  — the fragment of the event that falls within the queried span.
// • value — the payload.
// ---------------------------------------------------------------------------

public struct Hap<T>: CustomStringConvertible {
    /// Structural extent of the event (onset + duration in cycles).
    /// nil for continuous signals (not used in Phase 0).
    public let whole: TimeSpan?
    /// The queried fragment (what we actually heard/triggered).
    public let part: TimeSpan
    /// The payload.
    public let value: T

    public init(whole: TimeSpan?, part: TimeSpan, value: T) {
        self.whole = whole
        self.part  = part
        self.value = value
    }

    /// The onset of the event: beginning of `part`.
    public var onset: Rational { part.begin }

    /// The effective begin — from whole if present, else from part.
    public var wholeOrPart: TimeSpan { whole ?? part }

    /// Returns a new Hap with the value mapped.
    public func withValue<U>(_ f: (T) -> U) -> Hap<U> {
        Hap<U>(whole: whole, part: part, value: f(value))
    }

    /// Returns a new Hap with part replaced.
    public func withPart(_ newPart: TimeSpan) -> Hap<T> {
        Hap(whole: whole, part: newPart, value: value)
    }

    public var description: String {
        "Hap(whole: \(whole.map { $0.description } ?? "nil"), part: \(part), value: \(value))"
    }
}

// MARK: - Equatable / Hashable for Hap<[String: ControlValue]>

extension Hap: Equatable where T: Equatable {}
extension Hap: Hashable where T: Hashable {}
