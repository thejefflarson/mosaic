import Testing
import CoreGraphics
@testable import Mosaic

struct FocusDirectionTests {

    typealias Dir = CanvasViewController.FocusDirection

    // MARK: - Containment

    @Test func leftAcceptsPointToTheLeft() {
        #expect(Dir.left.contains(CGPoint(x: 0, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    @Test func leftRejectsPointToTheRight() {
        #expect(!Dir.left.contains(CGPoint(x: 200, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    @Test func rightAcceptsPointToTheRight() {
        #expect(Dir.right.contains(CGPoint(x: 200, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    @Test func rightRejectsPointToTheLeft() {
        #expect(!Dir.right.contains(CGPoint(x: 0, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    @Test func upAcceptsPointAbove() {
        #expect(Dir.up.contains(CGPoint(x: 50, y: 0), relativeTo: CGPoint(x: 50, y: 100)))
    }

    @Test func upRejectsPointBelow() {
        #expect(!Dir.up.contains(CGPoint(x: 50, y: 200), relativeTo: CGPoint(x: 50, y: 100)))
    }

    @Test func downAcceptsPointBelow() {
        #expect(Dir.down.contains(CGPoint(x: 50, y: 200), relativeTo: CGPoint(x: 50, y: 100)))
    }

    @Test func downRejectsPointAbove() {
        #expect(!Dir.down.contains(CGPoint(x: 50, y: 0), relativeTo: CGPoint(x: 50, y: 100)))
    }

    // MARK: - Exact boundary (on the axis line) is excluded

    @Test func leftExcludesExactSameX() {
        #expect(!Dir.left.contains(CGPoint(x: 100, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    @Test func rightExcludesExactSameX() {
        #expect(!Dir.right.contains(CGPoint(x: 100, y: 50), relativeTo: CGPoint(x: 100, y: 50)))
    }

    @Test func upExcludesExactSameY() {
        #expect(!Dir.up.contains(CGPoint(x: 50, y: 100), relativeTo: CGPoint(x: 50, y: 100)))
    }

    @Test func downExcludesExactSameY() {
        #expect(!Dir.down.contains(CGPoint(x: 50, y: 100), relativeTo: CGPoint(x: 50, y: 100)))
    }

    // MARK: - Off-axis position doesn't affect containment

    @Test func leftAcceptsDiagonallyLeft() {
        // Candidate is to the left and far above — still qualifies for left
        #expect(Dir.left.contains(CGPoint(x: 10, y: 999), relativeTo: CGPoint(x: 100, y: 50)))
    }

    @Test func upAcceptsDiagonallyAbove() {
        #expect(Dir.up.contains(CGPoint(x: 999, y: 10), relativeTo: CGPoint(x: 50, y: 100)))
    }

    // MARK: - nearestKey: perpendicular deviation is the primary sort key
    //
    // Spec example (Cmd+Left):
    //   A = (-1, 1000) — barely left, far off-axis
    //   B = (-100, 1)  — far left, nearly on-axis
    // B should rank ahead of A because its |Δy| is smaller.

    @Test func leftPrefersSmallYDeviationOverSmallXDistance() {
        let origin = CGPoint(x: 0, y: 0)
        let ka = Dir.left.nearestKey(for: CGPoint(x: -1,   y: 1000), relativeTo: origin)
        let kb = Dir.left.nearestKey(for: CGPoint(x: -100, y: 1),    relativeTo: origin)
        #expect(kb.0 < ka.0) // B has smaller perpendicular (y) deviation
    }

    @Test func rightPrefersSmallYDeviation() {
        let origin = CGPoint(x: 0, y: 0)
        let kAligned = Dir.right.nearestKey(for: CGPoint(x: 100, y: 5),   relativeTo: origin)
        let kClose   = Dir.right.nearestKey(for: CGPoint(x: 10,  y: 200), relativeTo: origin)
        #expect(kAligned.0 < kClose.0)
    }

    @Test func upPrefersSmallXDeviation() {
        let origin = CGPoint(x: 0, y: 0)
        let kAligned = Dir.up.nearestKey(for: CGPoint(x: 5,   y: -100), relativeTo: origin)
        let kClose   = Dir.up.nearestKey(for: CGPoint(x: 200, y: -10),  relativeTo: origin)
        #expect(kAligned.0 < kClose.0)
    }

    @Test func downPrefersSmallXDeviation() {
        let origin = CGPoint(x: 0, y: 0)
        let kAligned = Dir.down.nearestKey(for: CGPoint(x: 3,   y: 200), relativeTo: origin)
        let kClose   = Dir.down.nearestKey(for: CGPoint(x: 150, y: 10),  relativeTo: origin)
        #expect(kAligned.0 < kClose.0)
    }

    // Tiebreaker: when perpendicular deviations are equal, prefer smaller axial distance.

    @Test func leftTiebreakerUsesAxialDistance() {
        let origin = CGPoint(x: 0, y: 0)
        let kNear = Dir.left.nearestKey(for: CGPoint(x: -10,  y: 5), relativeTo: origin)
        let kFar  = Dir.left.nearestKey(for: CGPoint(x: -100, y: 5), relativeTo: origin)
        #expect(kNear.0 == kFar.0) // same |Δy|
        #expect(kNear.1 < kFar.1)  // smaller |Δx| wins
    }

    @Test func upTiebreakerUsesAxialDistance() {
        let origin = CGPoint(x: 0, y: 0)
        let kNear = Dir.up.nearestKey(for: CGPoint(x: 5, y: -10),  relativeTo: origin)
        let kFar  = Dir.up.nearestKey(for: CGPoint(x: 5, y: -100), relativeTo: origin)
        #expect(kNear.0 == kFar.0)
        #expect(kNear.1 < kFar.1)
    }
}
