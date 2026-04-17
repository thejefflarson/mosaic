import Testing
import AppKit
@testable import Mosaic

@MainActor
struct ToolPaletteTests {

    @Test func defaultsToPointer() {
        let palette = ToolPaletteView(frame: .zero)
        #expect(palette.activeTool == .pointer)
    }

    @Test func selectToolRoundTrips() {
        let palette = ToolPaletteView(frame: .zero)
        for tool in [CanvasTool.delete, .terminal, .text, .stickyNote, .arrow, .pen, .image, .pointer] {
            palette.selectTool(tool)
            #expect(palette.activeTool == tool)
        }
    }

    @Test func selectingDeleteThenPointerRestoresPointer() {
        // Mirrors the post-delete flow in CanvasViewController: delete is a
        // one-shot action, and the controller reverts to pointer afterwards.
        let palette = ToolPaletteView(frame: .zero)
        palette.selectTool(.delete)
        #expect(palette.activeTool == .delete)
        palette.selectTool(.pointer)
        #expect(palette.activeTool == .pointer)
    }
}
