import XCTest
@testable import Mosaic

final class SnapTests: XCTestCase {

    // Reference rect centred at (200, 200), 100×80
    let ref = CGRect(x: 150, y: 160, width: 100, height: 80)
    // threshold used in all tests
    let threshold: CGFloat = 4.0

    // MARK: - No snap

    func testNoSnapWhenNearestIsOutsideThreshold() {
        // Moving rect's left edge is 5 pts away from ref.minX (150) — just beyond threshold
        let moving = CGRect(x: 145 - 5, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.origin.x, moving.origin.x)
    }

    func testNoSnapWhenNoReferenceRects() {
        let moving = CGRect(x: 100, y: 100, width: 50, height: 50)
        let result = snapRect(moving, to: [], threshold: threshold)
        XCTAssertEqual(result.rect, moving)
        XCTAssertNil(result.worldX)
        XCTAssertNil(result.worldY)
    }

    // MARK: - Edge-to-edge snapping

    func testLeftEdgeSnapsToReferenceLeftEdge() {
        // Moving left edge at 148 → 2 pts from ref.minX (150) — within threshold
        let moving = CGRect(x: 148, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.minX, ref.minX, accuracy: 1e-10)
        XCTAssertEqual(result.worldX, ref.minX)
    }

    func testRightEdgeSnapsToReferenceRightEdge() {
        // Moving right edge at 252, ref.maxX = 250 → delta = -2
        let moving = CGRect(x: 252 - 60, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.maxX, ref.maxX, accuracy: 1e-10)
        XCTAssertEqual(result.worldX, ref.maxX)
    }

    func testTopEdgeSnapsToReferenceTopEdge() {
        let moving = CGRect(x: 0, y: ref.minY + 2, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.minY, ref.minY, accuracy: 1e-10)
        XCTAssertEqual(result.worldY, ref.minY)
    }

    func testBottomEdgeSnapsToReferenceBottomEdge() {
        // Moving bottom edge at ref.maxY - 3
        let moving = CGRect(x: 0, y: ref.maxY - 3 - 40, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.maxY, ref.maxY, accuracy: 1e-10)
        XCTAssertEqual(result.worldY, ref.maxY)
    }

    // MARK: - Centerline snapping

    func testLeftEdgeSnapsToCenterline() {
        // Moving left edge at ref.midX + 1 = 201
        let moving = CGRect(x: ref.midX + 1, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.minX, ref.midX, accuracy: 1e-10)
        XCTAssertEqual(result.worldX, ref.midX)
    }

    func testCenterlineSnapsToReferenceLeftEdge() {
        // Moving midX at ref.minX - 2 = 148
        let moving = CGRect(x: ref.minX - 2 - 30, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.midX, ref.minX, accuracy: 1e-10)
    }

    func testCenterlineSnapsToReferenceCenterline() {
        // Moving midX at ref.midX - 3
        let moving = CGRect(x: ref.midX - 3 - 30, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.midX, ref.midX, accuracy: 1e-10)
    }

    func testVerticalCenterlineSnaps() {
        // Moving midY at ref.midY + 2
        let moving = CGRect(x: 0, y: ref.midY + 2 - 20, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.midY, ref.midY, accuracy: 1e-10)
        XCTAssertEqual(result.worldY, ref.midY)
    }

    // MARK: - At-threshold boundary

    func testSnapsAtJustInsideThreshold() {
        let delta = threshold - 0.01
        let moving = CGRect(x: ref.minX - delta, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.minX, ref.minX, accuracy: 1e-6)
    }

    func testNoSnapAtExactThreshold() {
        // abs(d) must be STRICTLY less than threshold to snap
        let moving = CGRect(x: ref.minX - threshold, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertNotEqual(result.rect.minX, ref.minX)
    }

    // MARK: - Multiple references — picks nearest

    func testPicksNearestOfTwoReferences() {
        let ref2 = CGRect(x: 400, y: 160, width: 100, height: 80)  // far away
        // Moving left edge at ref.minX + 1 (closer to ref than ref2)
        let moving = CGRect(x: ref.minX + 1, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref, ref2], threshold: threshold)
        XCTAssertEqual(result.rect.minX, ref.minX, accuracy: 1e-10)
    }

    func testPicksCloserOfTwoNearbyReferences() {
        let refA = CGRect(x: 100, y: 0, width: 50, height: 50)  // minX=100
        let refB = CGRect(x: 103, y: 0, width: 50, height: 50)  // minX=103
        // Moving minX at 101 → delta to refA.minX = -1, delta to refB.minX = 2 → picks refA
        let moving = CGRect(x: 101, y: 500, width: 60, height: 40)
        let result = snapRect(moving, to: [refA, refB], threshold: threshold)
        XCTAssertEqual(result.rect.minX, refA.minX, accuracy: 1e-10)
    }

    // MARK: - Independent axes

    func testXandYSnapIndependently() {
        // X and Y each snap to different reference rects
        let refX = CGRect(x: 300, y: 900, width: 100, height: 80)
        let refY = CGRect(x: 900, y: 200, width: 100, height: 80)
        // Moving: minX near refX.minX, minY near refY.minY
        let moving = CGRect(x: refX.minX + 2, y: refY.minY - 3, width: 60, height: 40)
        let result = snapRect(moving, to: [refX, refY], threshold: threshold)
        XCTAssertEqual(result.rect.minX, refX.minX, accuracy: 1e-10)
        XCTAssertEqual(result.rect.minY, refY.minY, accuracy: 1e-10)
    }

    func testNoXSnapDoesNotAffectY() {
        // X is out of range, Y snaps
        let moving = CGRect(x: 1000, y: ref.minY + 2, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertEqual(result.rect.origin.x, moving.origin.x)  // X unchanged
        XCTAssertEqual(result.rect.minY, ref.minY, accuracy: 1e-10)
    }

    // MARK: - Guide world positions

    func testWorldXIsSetOnHorizontalSnap() {
        let moving = CGRect(x: ref.maxX - 2, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertNotNil(result.worldX)
    }

    func testWorldYIsSetOnVerticalSnap() {
        let moving = CGRect(x: 0, y: ref.maxY - 2, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertNotNil(result.worldY)
    }

    func testNoGuidesWhenNoSnap() {
        let moving = CGRect(x: 1000, y: 1000, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        XCTAssertNil(result.worldX)
        XCTAssertNil(result.worldY)
    }
}
