import AppKit

/// Centralises drag-cursor locking for the canvas.
///
/// During a drag, AppKit's cursor-rect machinery must be disabled so that
/// other views' cursor rects cannot override the in-progress cursor.
/// Call `beginDrag(_:in:)` on mouseDown and `endDrag(in:)` on mouseUp.
enum CanvasCursorManager {

    /// Lock the cursor to `cursor` for the duration of a drag.
    static func beginDrag(_ cursor: NSCursor, in window: NSWindow?) {
        window?.disableCursorRects()
        cursor.set()
    }

    /// Restore normal cursor-rect processing after a drag ends.
    static func endDrag(in window: NSWindow?) {
        window?.enableCursorRects()
        window?.resetCursorRects()
    }
}
