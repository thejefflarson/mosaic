import XCTest
@testable import Mosaic

final class ViewportTests: XCTestCase {

    // MARK: - Coordinate round-trips

    func testScreenToWorldRoundTrip() {
        var vp = Viewport()
        vp.panX = 100; vp.panY = 200; vp.zoom = 1.5
        let screen = CGPoint(x: 350, y: 480)
        let world  = vp.screenToWorld(screen)
        let back   = vp.worldToScreen(world)
        XCTAssertEqual(back.x, screen.x, accuracy: 1e-10)
        XCTAssertEqual(back.y, screen.y, accuracy: 1e-10)
    }

    func testWorldToScreenRoundTrip() {
        var vp = Viewport()
        vp.panX = -50; vp.panY = 30; vp.zoom = 0.75
        let world  = CGPoint(x: 1000, y: 2000)
        let screen = vp.worldToScreen(world)
        let back   = vp.screenToWorld(screen)
        XCTAssertEqual(back.x, world.x, accuracy: 1e-10)
        XCTAssertEqual(back.y, world.y, accuracy: 1e-10)
    }

    // MARK: - Zoom-around invariant

    func testZoomAroundKeepsAnchorFixed() {
        var vp = Viewport()
        vp.panX = 0; vp.panY = 0; vp.zoom = 1.0
        let anchor = CGPoint(x: 400, y: 300)
        let worldBefore = vp.screenToWorld(anchor)
        vp.zoomAround(screenAnchor: anchor, factor: 2.0)
        let worldAfter = vp.screenToWorld(anchor)
        XCTAssertEqual(worldAfter.x, worldBefore.x, accuracy: 1e-10)
        XCTAssertEqual(worldAfter.y, worldBefore.y, accuracy: 1e-10)
    }

    func testZoomAroundAtNonTrivialViewport() {
        var vp = Viewport()
        vp.panX = 120; vp.panY = -80; vp.zoom = 1.4
        let anchor = CGPoint(x: 200, y: 150)
        let worldBefore = vp.screenToWorld(anchor)
        vp.zoomAround(screenAnchor: anchor, factor: 0.6)
        let worldAfter = vp.screenToWorld(anchor)
        XCTAssertEqual(worldAfter.x, worldBefore.x, accuracy: 1e-10)
        XCTAssertEqual(worldAfter.y, worldBefore.y, accuracy: 1e-10)
    }

    // MARK: - Zoom clamping

    func testZoomDoesNotExceedMax() {
        var vp = Viewport()
        vp.zoom = Viewport.zoomMax
        vp.zoomAround(screenAnchor: .zero, factor: 10)
        XCTAssertLessThanOrEqual(vp.zoom, Viewport.zoomMax)
    }

    func testZoomDoesNotGoBelowMin() {
        var vp = Viewport()
        vp.zoom = Viewport.zoomMin
        vp.zoomAround(screenAnchor: .zero, factor: 0.001)
        XCTAssertGreaterThanOrEqual(vp.zoom, Viewport.zoomMin)
    }

    func testZoomMinIsLessThanMax() {
        XCTAssertLessThan(Viewport.zoomMin, Viewport.zoomMax)
    }

    // MARK: - Pan

    func testPanShiftsOrigin() {
        var vp = Viewport()
        vp.panX = 0; vp.panY = 0; vp.zoom = 1.0
        vp.pan(dx: 50, dy: -30)
        XCTAssertEqual(vp.panX, 50)
        XCTAssertEqual(vp.panY, -30)
    }

    func testPanAccumulates() {
        var vp = Viewport()
        vp.pan(dx: 10, dy: 20)
        vp.pan(dx: -5, dy: 15)
        XCTAssertEqual(vp.panX, 5)
        XCTAssertEqual(vp.panY, 35)
    }

    // MARK: - Visible world rect

    func testVisibleWorldRectAtIdentity() {
        let vp = Viewport()  // panX=0, panY=0, zoom=1
        let screen = CGSize(width: 1440, height: 900)
        let rect = vp.visibleWorldRect(screenSize: screen)
        XCTAssertEqual(rect.origin.x, 0, accuracy: 1e-10)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 1e-10)
        XCTAssertEqual(rect.width,  1440, accuracy: 1e-10)
        XCTAssertEqual(rect.height,  900, accuracy: 1e-10)
    }

    func testVisibleWorldRectZoomedIn() {
        var vp = Viewport()
        vp.zoom = 2.0
        let screen = CGSize(width: 800, height: 600)
        let rect = vp.visibleWorldRect(screenSize: screen)
        // At 2x zoom the world rect is half the screen dimensions
        XCTAssertEqual(rect.width,  400, accuracy: 1e-10)
        XCTAssertEqual(rect.height, 300, accuracy: 1e-10)
    }

    func testVisibleWorldRectWithPan() {
        var vp = Viewport()
        vp.panX = -100; vp.panY = -200; vp.zoom = 1.0
        let rect = vp.visibleWorldRect(screenSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(rect.origin.x, 100, accuracy: 1e-10)
        XCTAssertEqual(rect.origin.y, 200, accuracy: 1e-10)
    }

    // MARK: - zoomToFit

    func testZoomToFitCentersContent() {
        var vp = Viewport()
        let world  = CGRect(x: 0, y: 0, width: 400, height: 300)
        let screen = CGSize(width: 1200, height: 900)
        vp.zoomToFit(worldBounds: world, screenSize: screen, padding: 0)
        // After fit, midpoint of world should map to center of screen
        let screenMid = vp.worldToScreen(CGPoint(x: world.midX, y: world.midY))
        XCTAssertEqual(screenMid.x, screen.width  / 2, accuracy: 1e-6)
        XCTAssertEqual(screenMid.y, screen.height / 2, accuracy: 1e-6)
    }

    func testZoomToFitFillsConstrainedDimension() {
        // World is wider than it is tall relative to screen — height axis limits zoom
        var vp = Viewport()
        let world  = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let screen = CGSize(width: 800, height: 600)
        vp.zoomToFit(worldBounds: world, screenSize: screen, padding: 0)
        // Width scale: 800/2000 = 0.40, Height scale: 600/1000 = 0.60 → min is 0.40
        XCTAssertEqual(vp.zoom, 0.40, accuracy: 1e-6)
    }

    func testZoomToFitRespectsPadding() {
        var vp = Viewport()
        let world  = CGRect(x: 0, y: 0, width: 600, height: 400)
        let screen = CGSize(width: 720, height: 520)
        let padding: CGFloat = 60
        vp.zoomToFit(worldBounds: world, screenSize: screen, padding: padding)
        // Available: (720-120) x (520-120) = 600 x 400 → exact 1:1 fit
        // Width scale: 600/600 = 1.0, Height scale: 400/400 = 1.0
        XCTAssertEqual(vp.zoom, 1.0, accuracy: 1e-6)
    }

    func testZoomToFitClampsToMinZoom() {
        var vp = Viewport()
        // World so large that the natural zoom would be far below zoomMin
        let world  = CGRect(x: 0, y: 0, width: 100_000, height: 100_000)
        let screen = CGSize(width: 800, height: 600)
        vp.zoomToFit(worldBounds: world, screenSize: screen, padding: 0)
        XCTAssertGreaterThanOrEqual(vp.zoom, Viewport.zoomMin)
    }

    func testZoomToFitIsNoOpForZeroSizeBounds() {
        var vp = Viewport()
        vp.panX = 99; vp.panY = 77; vp.zoom = 1.5
        vp.zoomToFit(worldBounds: .zero, screenSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(vp.panX, 99)
        XCTAssertEqual(vp.panY, 77)
        XCTAssertEqual(vp.zoom, 1.5)
    }

    func testZoomToFitIsNoOpForZeroScreenSize() {
        var vp = Viewport()
        vp.panX = 10; vp.panY = 20; vp.zoom = 2.0
        vp.zoomToFit(worldBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                     screenSize: .zero)
        XCTAssertEqual(vp.panX, 10)
        XCTAssertEqual(vp.panY, 20)
        XCTAssertEqual(vp.zoom, 2.0)
    }
}
