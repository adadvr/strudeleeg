import XCTest
@testable import MiniEngine

final class RationalTests: XCTestCase {

    func testBasicReduction() {
        let r = Rational(2, 4)
        XCTAssertEqual(r.numerator, 1)
        XCTAssertEqual(r.denominator, 2)
    }

    func testNegativeDenominator() {
        let r = Rational(3, -6)
        XCTAssertEqual(r.numerator, -1)
        XCTAssertEqual(r.denominator, 2)
    }

    func testAddition() {
        let a = Rational(1, 3)
        let b = Rational(1, 6)
        let sum = a + b
        XCTAssertEqual(sum, Rational(1, 2))
    }

    func testSubtraction() {
        let a = Rational(3, 4)
        let b = Rational(1, 4)
        XCTAssertEqual(a - b, Rational(1, 2))
    }

    func testMultiplication() {
        let a = Rational(2, 3)
        let b = Rational(3, 4)
        XCTAssertEqual(a * b, Rational(1, 2))
    }

    func testDivision() {
        let a = Rational(1, 2)
        let b = Rational(1, 4)
        XCTAssertEqual(a / b, Rational(2, 1))
    }

    func testComparison() {
        XCTAssertLessThan(Rational(1, 3), Rational(1, 2))
        XCTAssertGreaterThan(Rational(2, 3), Rational(1, 2))
        XCTAssertEqual(Rational(2, 4), Rational(1, 2))
    }

    func testFloor() {
        XCTAssertEqual(Rational(5, 3).floorInt, 1)
        XCTAssertEqual(Rational(3, 3).floorInt, 1)
        XCTAssertEqual(Rational(0, 1).floorInt, 0)
        XCTAssertEqual(Rational(-1, 3).floorInt, -1)
    }

    func testDescription() {
        XCTAssertEqual(Rational(1, 3).description, "1/3")
        XCTAssertEqual(Rational(2, 1).description, "2")
    }

    func testZeroGCD() {
        let r = Rational(0, 5)
        XCTAssertEqual(r.numerator, 0)
        XCTAssertEqual(r.denominator, 1)
    }
}
