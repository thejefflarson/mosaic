import Testing
import CoreGraphics
@testable import Mosaic

struct FocusDirectionTests {

    typealias Dir = TerminalController.FocusDirection

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

    // MARK: - 90° cone: within ±45° of axis is accepted; outside is rejected

    @Test func leftAcceptsWithin45Degrees() {
        // 30° above horizontal-left — inside the 90° left cone
        #expect(Dir.left.contains(CGPoint(x: 50, y: 80), relativeTo: CGPoint(x: 100, y: 50)))
    }

    @Test func leftRejectsMoreThan45DegreesOff() {
        // Candidate is mostly above and slightly left — outside left cone
        #expect(!Dir.left.contains(CGPoint(x: 90, y: 0), relativeTo: CGPoint(x: 100, y: 50)))
    }

    @Test func rightRejectsMoreThan45DegreesOff() {
        // Candidate is mostly below and slightly right — outside right cone
        #expect(!Dir.right.contains(CGPoint(x: 110, y: 200), relativeTo: CGPoint(x: 100, y: 50)))
    }

    @Test func upAcceptsWithin45Degrees() {
        // Candidate is mostly above with small horizontal offset — inside up cone
        #expect(Dir.up.contains(CGPoint(x: 60, y: 10), relativeTo: CGPoint(x: 50, y: 100)))
    }

    @Test func upRejectsMostlyHorizontal() {
        // Candidate is far to the right and slightly above — outside up cone
        #expect(!Dir.up.contains(CGPoint(x: 999, y: 90), relativeTo: CGPoint(x: 50, y: 100)))
    }

    @Test func downRejectsMostlyHorizontal() {
        #expect(!Dir.down.contains(CGPoint(x: 999, y: 110), relativeTo: CGPoint(x: 50, y: 100)))
    }

    // A terminal at exactly 45° belongs to a horizontal quadrant (left/right claim the diagonals).
    @Test func exactlyAt45DegreesIsInRightQuadrant() {
        let origin = CGPoint(x: 0, y: 0)
        let diagonal = CGPoint(x: 10, y: -10) // exactly 45° up-right
        #expect(Dir.right.contains(diagonal, relativeTo: origin))
        #expect(!Dir.up.contains(diagonal, relativeTo: origin))
    }

    @Test func exactlyAt45DegreesIsInLeftQuadrantUpperLeft() {
        let origin = CGPoint(x: 0, y: 0)
        let diagonal = CGPoint(x: -10, y: -10) // exactly 45° up-left
        #expect(Dir.left.contains(diagonal, relativeTo: origin))
        #expect(!Dir.up.contains(diagonal, relativeTo: origin))
    }

    @Test func exactlyAt45DegreesIsInLeftQuadrantLowerLeft() {
        let origin = CGPoint(x: 0, y: 0)
        let diagonal = CGPoint(x: -10, y: 10) // exactly 45° down-left
        #expect(Dir.left.contains(diagonal, relativeTo: origin))
        #expect(!Dir.down.contains(diagonal, relativeTo: origin))
    }

    @Test func exactlyAt45DegreesIsInRightQuadrantLowerRight() {
        let origin = CGPoint(x: 0, y: 0)
        let diagonal = CGPoint(x: 10, y: 10) // exactly 45° down-right
        #expect(Dir.right.contains(diagonal, relativeTo: origin))
        #expect(!Dir.down.contains(diagonal, relativeTo: origin))
    }

    // MARK: - Euclidean selection
    //
    // After directional filtering, focusNearest picks the Euclidean-nearest
    // candidate. Tests verify expected winners for both the original spec
    // example and the user-reported regression.

    private func dist(_ pt: CGPoint, from origin: CGPoint) -> CGFloat {
        hypot(pt.x - origin.x, pt.y - origin.y)
    }

    // Original spec example (Cmd+Left):
    //   A = (-1, 1000) — barely left, far off-axis  (dist ≈ 1000)
    //   B = (-100, 1)  — far left, nearly on-axis   (dist ≈ 100)
    // B is Euclidean-closer, so B wins.
    @Test func leftCloserTerminalWinsOverDistantAlignedTerminal() {
        let origin = CGPoint(x: 0, y: 0)
        let distA = dist(CGPoint(x: -1,   y: 1000), from: origin)
        let distB = dist(CGPoint(x: -100, y: 1),    from: origin)
        #expect(distB < distA)
    }

    // User-reported regression (Cmd+Right):
    //   A = (10, 5)  — close, slightly off-axis   (dist ≈ 11)
    //   B = (40, 0)  — far, perfectly aligned      (dist = 40)
    // A is Euclidean-closer, so A wins.
    @Test func rightCloserTerminalWinsEvenIfMoreOffAxis() {
        let origin = CGPoint(x: 0, y: 0)
        let distA = dist(CGPoint(x: 10, y: 5), from: origin)
        let distB = dist(CGPoint(x: 40, y: 0), from: origin)
        #expect(distA < distB)
    }

    @Test func upCloserTerminalWins() {
        let origin = CGPoint(x: 0, y: 0)
        let distNear = dist(CGPoint(x: 5,  y: -10),  from: origin)
        let distFar  = dist(CGPoint(x: 0,  y: -100), from: origin)
        #expect(distNear < distFar)
    }

    @Test func downCloserTerminalWins() {
        let origin = CGPoint(x: 0, y: 0)
        let distNear = dist(CGPoint(x: 3,  y: 10),  from: origin)
        let distFar  = dist(CGPoint(x: 0,  y: 200), from: origin)
        #expect(distNear < distFar)
    }

    // A terminal directly on-axis at moderate distance beats a nearer off-axis one
    // only when the Euclidean distance makes it so — not by alignment alone.
    @Test func alignedTerminalWinsOnlyWhenActuallyCloser() {
        let origin = CGPoint(x: 0, y: 0)
        let aligned = dist(CGPoint(x: 100, y: 0),  from: origin) // 100 — aligned but far
        let nearby  = dist(CGPoint(x: 10,  y: 8),  from: origin) // ≈ 12.8 — closer
        #expect(nearby < aligned)
    }
}
