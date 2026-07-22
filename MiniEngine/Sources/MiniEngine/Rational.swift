// ---------------------------------------------------------------------------
// Rational — exact fractional time representation
// Clean-room implementation based on public Tidal Cycles / Strudel docs.
// All times in MiniEngine use Rational to match oracle exactly (1/3 ≠ 0.3333).
// ---------------------------------------------------------------------------

/// A rational number n/d (always reduced, d > 0).
public struct Rational: Hashable, CustomStringConvertible, Sendable {
    public let numerator: Int
    public let denominator: Int

    public static let zero = Rational(0, 1)
    public static let one  = Rational(1, 1)

    // MARK: - Init

    public init(_ numerator: Int, _ denominator: Int) {
        precondition(denominator != 0, "Rational denominator must be non-zero")
        let sign = denominator < 0 ? -1 : 1
        let n = numerator * sign
        let d = abs(denominator)
        let g = gcd(abs(n), d)
        self.numerator   = n / g
        self.denominator = d / g
    }

    /// Convenience: integer as rational.
    public init(_ n: Int) {
        self.init(n, 1)
    }

    /// Convenience: from Double (converts to a nearby rational via 10^6 denominator).
    /// Use only when exact representation is not required.
    public init(approximating d: Double) {
        let scale = 1_000_000
        self.init(Int(d * Double(scale)), scale)
    }

    // MARK: - Arithmetic

    public static func + (lhs: Rational, rhs: Rational) -> Rational {
        Rational(lhs.numerator * rhs.denominator + rhs.numerator * lhs.denominator,
                 lhs.denominator * rhs.denominator)
    }

    public static func - (lhs: Rational, rhs: Rational) -> Rational {
        Rational(lhs.numerator * rhs.denominator - rhs.numerator * lhs.denominator,
                 lhs.denominator * rhs.denominator)
    }

    public static func * (lhs: Rational, rhs: Rational) -> Rational {
        Rational(lhs.numerator * rhs.numerator,
                 lhs.denominator * rhs.denominator)
    }

    public static func / (lhs: Rational, rhs: Rational) -> Rational {
        Rational(lhs.numerator * rhs.denominator,
                 lhs.denominator * rhs.numerator)
    }

    public static prefix func - (r: Rational) -> Rational {
        Rational(-r.numerator, r.denominator)
    }

    // MARK: - Comparison

    public static func < (lhs: Rational, rhs: Rational) -> Bool {
        lhs.numerator * rhs.denominator < rhs.numerator * lhs.denominator
    }

    public static func <= (lhs: Rational, rhs: Rational) -> Bool {
        lhs.numerator * rhs.denominator <= rhs.numerator * lhs.denominator
    }

    public static func > (lhs: Rational, rhs: Rational) -> Bool {
        rhs < lhs
    }

    public static func >= (lhs: Rational, rhs: Rational) -> Bool {
        rhs <= lhs
    }

    // MARK: - Floor / ceil

    /// Returns the floor as an Int.
    public var floorInt: Int {
        if numerator >= 0 {
            return numerator / denominator
        } else {
            // For negative, floor rounds toward -∞
            return (numerator - denominator + 1) / denominator
        }
    }

    /// Returns the floor as a Rational.
    public var floor: Rational { Rational(floorInt) }

    /// Returns the ceiling as a Rational.
    public var ceil: Rational {
        if numerator % denominator == 0 { return self }
        return Rational(floorInt + 1)
    }

    // MARK: - Conversion

    public var toDouble: Double {
        Double(numerator) / Double(denominator)
    }

    // MARK: - Description

    public var description: String {
        denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)"
    }
}

// MARK: - Comparable conformance

extension Rational: Comparable {}

// MARK: - GCD helper

private func gcd(_ a: Int, _ b: Int) -> Int {
    var a = a; var b = b
    while b != 0 { let t = b; b = a % b; a = t }
    return a == 0 ? 1 : a
}
