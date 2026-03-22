import XCTest
@testable import Mosaic

final class UtilityTests: XCTestCase {

    // MARK: - Comparable.clamped

    func testClampedMidValue() {
        XCTAssertEqual(5.clampedTo(1...10), 5)
    }

    func testClampedLow() {
        XCTAssertEqual((-5).clampedTo(0...100), 0)
    }

    func testClampedHigh() {
        XCTAssertEqual(200.clampedTo(0...100), 100)
    }

    func testClampedAtLowerBound() {
        XCTAssertEqual(0.clampedTo(0...10), 0)
    }

    func testClampedAtUpperBound() {
        XCTAssertEqual(10.clampedTo(0...10), 10)
    }

    func testClampedFloat() {
        XCTAssertEqual(CGFloat(0.05).clamped(to: 0.1...3.0), 0.1)
        XCTAssertEqual(CGFloat(1.5).clamped(to: 0.1...3.0),  1.5)
        XCTAssertEqual(CGFloat(5.0).clamped(to: 0.1...3.0),  3.0)
    }

    func testClampedDouble() {
        XCTAssertEqual(Double(-1.0).clamped(to: 0.0...1.0), 0.0)
        XCTAssertEqual(Double(0.5).clamped(to:  0.0...1.0), 0.5)
        XCTAssertEqual(Double(2.0).clamped(to:  0.0...1.0), 1.0)
    }

    // MARK: - CGRect center init

    func testCGRectCenterInit() {
        let center = CGPoint(x: 100, y: 200)
        let size   = CGSize(width: 60, height: 40)
        let rect   = CGRect(center: center, size: size)
        XCTAssertEqual(rect.midX, 100)
        XCTAssertEqual(rect.midY, 200)
        XCTAssertEqual(rect.width,  60)
        XCTAssertEqual(rect.height, 40)
        XCTAssertEqual(rect.minX, 70)
        XCTAssertEqual(rect.minY, 180)
    }
}

// Convenience to avoid clunky Int.clamped(to:) call syntax in tests
private extension Int {
    func clampedTo(_ range: ClosedRange<Int>) -> Int { clamped(to: range) }
}
