import Testing
import AppKit
@testable import Mosaic

struct SnapTests {

    // Reference rect centred at (200, 200), 100×80
    let ref = CGRect(x: 150, y: 160, width: 100, height: 80)
    let threshold: CGFloat = 4.0

    // MARK: - No snap

    @Test func noSnapWhenNearestIsOutsideThreshold() {
        let moving = CGRect(x: 145 - 5, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(result.rect.origin.x == moving.origin.x)
    }

    @Test func noSnapWhenNoReferenceRects() {
        let moving = CGRect(x: 100, y: 100, width: 50, height: 50)
        let result = snapRect(moving, to: [], threshold: threshold)
        #expect(result.rect == moving)
        #expect(result.worldX == nil)
        #expect(result.worldY == nil)
    }

    // MARK: - Edge-to-edge snapping

    @Test func leftEdgeSnapsToReferenceLeftEdge() {
        let moving = CGRect(x: 148, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(abs(result.rect.minX - ref.minX) < 1e-10)
        #expect(result.worldX == ref.minX)
    }

    @Test func rightEdgeSnapsToReferenceRightEdge() {
        let moving = CGRect(x: 252 - 60, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(abs(result.rect.maxX - ref.maxX) < 1e-10)
        #expect(result.worldX == ref.maxX)
    }

    @Test func topEdgeSnapsToReferenceTopEdge() {
        let moving = CGRect(x: 0, y: ref.minY + 2, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(abs(result.rect.minY - ref.minY) < 1e-10)
        #expect(result.worldY == ref.minY)
    }

    @Test func bottomEdgeSnapsToReferenceBottomEdge() {
        let moving = CGRect(x: 0, y: ref.maxY - 3 - 40, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(abs(result.rect.maxY - ref.maxY) < 1e-10)
        #expect(result.worldY == ref.maxY)
    }

    // MARK: - Centerline snapping

    @Test func leftEdgeSnapsToCenterline() {
        let moving = CGRect(x: ref.midX + 1, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(abs(result.rect.minX - ref.midX) < 1e-10)
        #expect(result.worldX == ref.midX)
    }

    @Test func centerlineSnapsToReferenceLeftEdge() {
        let moving = CGRect(x: ref.minX - 2 - 30, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(abs(result.rect.midX - ref.minX) < 1e-10)
    }

    @Test func centerlineSnapsToReferenceCenterline() {
        let moving = CGRect(x: ref.midX - 3 - 30, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(abs(result.rect.midX - ref.midX) < 1e-10)
    }

    @Test func verticalCenterlineSnaps() {
        let moving = CGRect(x: 0, y: ref.midY + 2 - 20, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(abs(result.rect.midY - ref.midY) < 1e-10)
        #expect(result.worldY == ref.midY)
    }

    // MARK: - At-threshold boundary

    @Test func snapsAtJustInsideThreshold() {
        let delta = threshold - 0.01
        let moving = CGRect(x: ref.minX - delta, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(abs(result.rect.minX - ref.minX) < 1e-6)
    }

    @Test func noSnapAtExactThreshold() {
        let moving = CGRect(x: ref.minX - threshold, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(result.rect.minX != ref.minX)
    }

    // MARK: - Multiple references — picks nearest

    @Test func picksNearestOfTwoReferences() {
        let ref2 = CGRect(x: 400, y: 160, width: 100, height: 80)
        let moving = CGRect(x: ref.minX + 1, y: 0, width: 60, height: 40)
        let result = snapRect(moving, to: [ref, ref2], threshold: threshold)
        #expect(abs(result.rect.minX - ref.minX) < 1e-10)
    }

    @Test func picksCloserOfTwoNearbyReferences() {
        let refA = CGRect(x: 100, y: 0, width: 50, height: 50)
        let refB = CGRect(x: 103, y: 0, width: 50, height: 50)
        let moving = CGRect(x: 101, y: 500, width: 60, height: 40)
        let result = snapRect(moving, to: [refA, refB], threshold: threshold)
        #expect(abs(result.rect.minX - refA.minX) < 1e-10)
    }

    // MARK: - Independent axes

    @Test func xAndYSnapIndependently() {
        let refX = CGRect(x: 300, y: 900, width: 100, height: 80)
        let refY = CGRect(x: 900, y: 200, width: 100, height: 80)
        let moving = CGRect(x: refX.minX + 2, y: refY.minY - 3, width: 60, height: 40)
        let result = snapRect(moving, to: [refX, refY], threshold: threshold)
        #expect(abs(result.rect.minX - refX.minX) < 1e-10)
        #expect(abs(result.rect.minY - refY.minY) < 1e-10)
    }

    @Test func noXSnapDoesNotAffectY() {
        let moving = CGRect(x: 1000, y: ref.minY + 2, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(result.rect.origin.x == moving.origin.x)
        #expect(abs(result.rect.minY - ref.minY) < 1e-10)
    }

    // MARK: - Guide world positions

    @Test func worldXIsSetOnHorizontalSnap() {
        let moving = CGRect(x: ref.maxX - 2, y: 0, width: 60, height: 40)
        #expect(snapRect(moving, to: [ref], threshold: threshold).worldX != nil)
    }

    @Test func worldYIsSetOnVerticalSnap() {
        let moving = CGRect(x: 0, y: ref.maxY - 2, width: 60, height: 40)
        #expect(snapRect(moving, to: [ref], threshold: threshold).worldY != nil)
    }

    @Test func noGuidesWhenNoSnap() {
        let moving = CGRect(x: 1000, y: 1000, width: 60, height: 40)
        let result = snapRect(moving, to: [ref], threshold: threshold)
        #expect(result.worldX == nil)
        #expect(result.worldY == nil)
    }
}
