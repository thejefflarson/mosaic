import XCTest
@testable import Mosaic

final class FocusDirectionTests: XCTestCase {

    typealias Dir = CanvasViewController.FocusDirection

    // MARK: - Containment

    func testLeftAcceptsPointToTheLeft() {
        XCTAssertTrue(Dir.left.contains(CGPoint(x: 0, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    func testLeftRejectsPointToTheRight() {
        XCTAssertFalse(Dir.left.contains(CGPoint(x: 200, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    func testRightAcceptsPointToTheRight() {
        XCTAssertTrue(Dir.right.contains(CGPoint(x: 200, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    func testRightRejectsPointToTheLeft() {
        XCTAssertFalse(Dir.right.contains(CGPoint(x: 0, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    func testUpAcceptsPointAbove() {
        XCTAssertTrue(Dir.up.contains(CGPoint(x: 50, y: 0), relativeTo: CGPoint(x: 50, y: 100)))
    }

    func testUpRejectsPointBelow() {
        XCTAssertFalse(Dir.up.contains(CGPoint(x: 50, y: 200), relativeTo: CGPoint(x: 50, y: 100)))
    }

    func testDownAcceptsPointBelow() {
        XCTAssertTrue(Dir.down.contains(CGPoint(x: 50, y: 200), relativeTo: CGPoint(x: 50, y: 100)))
    }

    func testDownRejectsPointAbove() {
        XCTAssertFalse(Dir.down.contains(CGPoint(x: 50, y: 0), relativeTo: CGPoint(x: 50, y: 100)))
    }

    // MARK: - Exact boundary (on the axis line) is excluded

    func testLeftExcludesExactSameX() {
        XCTAssertFalse(Dir.left.contains(CGPoint(x: 100, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    func testRightExcludesExactSameX() {
        XCTAssertFalse(Dir.right.contains(CGPoint(x: 100, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    func testUpExcludesExactSameY() {
        XCTAssertFalse(Dir.up.contains(CGPoint(x: 50, y: 100), relativeTo: CGPoint(x: 50, y: 100)))
    }

    func testDownExcludesExactSameY() {
        XCTAssertFalse(Dir.down.contains(CGPoint(x: 50, y: 100), relativeTo: CGPoint(x: 50, y: 100)))
    }

    // MARK: - Off-axis position doesn't affect result

    func testLeftAcceptsDiagonallyLeft() {
        // Candidate is to the left and far above — still qualifies for left
        XCTAssertTrue(Dir.left.contains(CGPoint(x: 10, y: 999), relativeTo: CGPoint(x: 100, y: 50)))
    }

    func testUpAcceptsDiagonallyAbove() {
        XCTAssertTrue(Dir.up.contains(CGPoint(x: 999, y: 10), relativeTo: CGPoint(x: 50, y: 100)))
    }
}
