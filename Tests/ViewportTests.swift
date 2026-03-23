import Testing
import AppKit
@testable import Mosaic

struct ViewportTests {

    // MARK: - Coordinate round-trips

    @Test func screenToWorldRoundTrip() {
        var vp = Viewport()
        vp.panX = 100; vp.panY = 200; vp.zoom = 1.5
        let screen = CGPoint(x: 350, y: 480)
        let back   = vp.worldToScreen(vp.screenToWorld(screen))
        #expect(abs(back.x - screen.x) < 1e-10)
        #expect(abs(back.y - screen.y) < 1e-10)
    }

    @Test func worldToScreenRoundTrip() {
        var vp = Viewport()
        vp.panX = -50; vp.panY = 30; vp.zoom = 0.75
        let world = CGPoint(x: 1000, y: 2000)
        let back  = vp.screenToWorld(vp.worldToScreen(world))
        #expect(abs(back.x - world.x) < 1e-10)
        #expect(abs(back.y - world.y) < 1e-10)
    }

    // MARK: - Zoom-around invariant

    @Test func zoomAroundKeepsAnchorFixed() {
        var vp = Viewport()
        vp.panX = 0; vp.panY = 0; vp.zoom = 1.0
        let anchor      = CGPoint(x: 400, y: 300)
        let worldBefore = vp.screenToWorld(anchor)
        vp.zoomAround(screenAnchor: anchor, factor: 2.0)
        let worldAfter  = vp.screenToWorld(anchor)
        #expect(abs(worldAfter.x - worldBefore.x) < 1e-10)
        #expect(abs(worldAfter.y - worldBefore.y) < 1e-10)
    }

    @Test func zoomAroundAtNonTrivialViewport() {
        var vp = Viewport()
        vp.panX = 120; vp.panY = -80; vp.zoom = 1.4
        let anchor      = CGPoint(x: 200, y: 150)
        let worldBefore = vp.screenToWorld(anchor)
        vp.zoomAround(screenAnchor: anchor, factor: 0.6)
        let worldAfter  = vp.screenToWorld(anchor)
        #expect(abs(worldAfter.x - worldBefore.x) < 1e-10)
        #expect(abs(worldAfter.y - worldBefore.y) < 1e-10)
    }

    // MARK: - Zoom clamping

    @Test func zoomDoesNotExceedMax() {
        var vp = Viewport(); vp.zoom = Viewport.zoomMax
        vp.zoomAround(screenAnchor: .zero, factor: 10)
        #expect(vp.zoom <= Viewport.zoomMax)
    }

    @Test func zoomDoesNotGoBelowMin() {
        var vp = Viewport(); vp.zoom = Viewport.zoomMin
        vp.zoomAround(screenAnchor: .zero, factor: 0.001)
        #expect(vp.zoom >= Viewport.zoomMin)
    }

    @Test func zoomMinIsLessThanMax() {
        #expect(Viewport.zoomMin < Viewport.zoomMax)
    }

    // MARK: - Pan

    @Test func panShiftsOrigin() {
        var vp = Viewport(); vp.panX = 0; vp.panY = 0; vp.zoom = 1.0
        vp.pan(dx: 50, dy: -30)
        #expect(vp.panX == 50)
        #expect(vp.panY == -30)
    }

    @Test func panAccumulates() {
        var vp = Viewport()
        vp.pan(dx: 10, dy: 20)
        vp.pan(dx: -5, dy: 15)
        #expect(vp.panX == 5)
        #expect(vp.panY == 35)
    }

    // MARK: - Visible world rect

    @Test func visibleWorldRectAtIdentity() {
        let vp     = Viewport()
        let screen = CGSize(width: 1440, height: 900)
        let rect   = vp.visibleWorldRect(screenSize: screen)
        #expect(abs(rect.origin.x - 0)    < 1e-10)
        #expect(abs(rect.origin.y - 0)    < 1e-10)
        #expect(abs(rect.width    - 1440) < 1e-10)
        #expect(abs(rect.height   - 900)  < 1e-10)
    }

    @Test func visibleWorldRectZoomedIn() {
        var vp = Viewport(); vp.zoom = 2.0
        let rect = vp.visibleWorldRect(screenSize: CGSize(width: 800, height: 600))
        #expect(abs(rect.width  - 400) < 1e-10)
        #expect(abs(rect.height - 300) < 1e-10)
    }

    @Test func visibleWorldRectWithPan() {
        var vp = Viewport(); vp.panX = -100; vp.panY = -200; vp.zoom = 1.0
        let rect = vp.visibleWorldRect(screenSize: CGSize(width: 1000, height: 800))
        #expect(abs(rect.origin.x - 100) < 1e-10)
        #expect(abs(rect.origin.y - 200) < 1e-10)
    }

    // MARK: - zoomToFit

    @Test func zoomToFitCentersContent() {
        var vp = Viewport()
        let world  = CGRect(x: 0, y: 0, width: 400, height: 300)
        let screen = CGSize(width: 1200, height: 900)
        vp.zoomToFit(worldBounds: world, screenSize: screen, padding: 0)
        let mid = vp.worldToScreen(CGPoint(x: world.midX, y: world.midY))
        #expect(abs(mid.x - screen.width  / 2) < 1e-6)
        #expect(abs(mid.y - screen.height / 2) < 1e-6)
    }

    @Test func zoomToFitFillsConstrainedDimension() {
        var vp = Viewport()
        vp.zoomToFit(worldBounds: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                     screenSize: CGSize(width: 800, height: 600), padding: 0)
        #expect(abs(vp.zoom - 0.40) < 1e-6)
    }

    @Test func zoomToFitRespectsPadding() {
        var vp = Viewport()
        vp.zoomToFit(worldBounds: CGRect(x: 0, y: 0, width: 600, height: 400),
                     screenSize: CGSize(width: 720, height: 520), padding: 60)
        #expect(abs(vp.zoom - 1.0) < 1e-6)
    }

    @Test func zoomToFitClampsToMinZoom() {
        var vp = Viewport()
        vp.zoomToFit(worldBounds: CGRect(x: 0, y: 0, width: 100_000, height: 100_000),
                     screenSize: CGSize(width: 800, height: 600), padding: 0)
        #expect(vp.zoom >= Viewport.zoomMin)
    }

    @Test func zoomToFitIsNoOpForZeroSizeBounds() {
        var vp = Viewport(); vp.panX = 99; vp.panY = 77; vp.zoom = 1.5
        vp.zoomToFit(worldBounds: .zero, screenSize: CGSize(width: 800, height: 600))
        #expect(vp.panX == 99)
        #expect(vp.panY == 77)
        #expect(vp.zoom == 1.5)
    }

    @Test func zoomToFitIsNoOpForZeroScreenSize() {
        var vp = Viewport(); vp.panX = 10; vp.panY = 20; vp.zoom = 2.0
        vp.zoomToFit(worldBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                     screenSize: .zero)
        #expect(vp.panX == 10)
        #expect(vp.panY == 20)
        #expect(vp.zoom == 2.0)
    }
}
