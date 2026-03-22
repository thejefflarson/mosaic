import XCTest
import AppKit
@testable import Mosaic

@MainActor
final class CursorManagerTests: XCTestCase {

    var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    override func tearDown() async throws {
        // Always restore cursor rects so other tests aren't affected.
        if !window.areCursorRectsEnabled { window.enableCursorRects() }
        window = nil
        try await super.tearDown()
    }

    func testCursorRectsDisabledDuringDrag() {
        XCTAssertTrue(window.areCursorRectsEnabled)
        CanvasCursorManager.beginDrag(.closedHand, in: window)
        XCTAssertFalse(window.areCursorRectsEnabled)
    }

    func testCursorRectsRestoredAfterDrag() {
        CanvasCursorManager.beginDrag(.closedHand, in: window)
        CanvasCursorManager.endDrag(in: window)
        XCTAssertTrue(window.areCursorRectsEnabled)
    }

    func testDragCursorIsSet() {
        CanvasCursorManager.beginDrag(.closedHand, in: window)
        XCTAssertEqual(NSCursor.current, .closedHand)
        CanvasCursorManager.endDrag(in: window)
    }

    func testDragWithNilWindowDoesNotCrash() {
        // Passing nil is safe — views call this before they have a window.
        CanvasCursorManager.beginDrag(.closedHand, in: nil)
        CanvasCursorManager.endDrag(in: nil)
    }
}
