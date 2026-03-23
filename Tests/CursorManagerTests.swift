import Testing
import AppKit
@testable import Mosaic

@MainActor
struct CursorManagerTests {

    let window: NSWindow

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    @Test func cursorRectsDisabledDuringDrag() {
        #expect(window.areCursorRectsEnabled)
        CanvasCursorManager.beginDrag(.closedHand, in: window)
        #expect(!window.areCursorRectsEnabled)
        // Restore so the shared cursor state doesn't leak between tests
        CanvasCursorManager.endDrag(in: window)
    }

    @Test func cursorRectsRestoredAfterDrag() {
        CanvasCursorManager.beginDrag(.closedHand, in: window)
        CanvasCursorManager.endDrag(in: window)
        #expect(window.areCursorRectsEnabled)
    }

    @Test func dragCursorIsSet() {
        CanvasCursorManager.beginDrag(.closedHand, in: window)
        defer { CanvasCursorManager.endDrag(in: window) }
        #expect(NSCursor.current == .closedHand)
    }

    @Test func dragWithNilWindowDoesNotCrash() {
        CanvasCursorManager.beginDrag(.closedHand, in: nil)
        CanvasCursorManager.endDrag(in: nil)
    }
}
