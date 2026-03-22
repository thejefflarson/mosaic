import XCTest
import AppKit
@testable import Mosaic

/// Integration tests for undo/redo on annotations.
/// Terminal spawning is intentionally avoided — PTY lifecycle is too heavy for unit tests
/// and is covered by manual integration testing.
@MainActor
final class UndoTests: XCTestCase {

    var vc: CanvasViewController!
    var window: NSWindow!

    override func setUp() {
        super.setUp()
        vc = CanvasViewController()
        // Creating the window (without showing it) puts the view in the responder chain
        // so undoManager is non-nil, but does NOT trigger viewDidAppear / restoreWorkspace.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        vc.loadViewIfNeeded()
        // Clear any undo actions accumulated during view setup.
        vc.undoManager?.removeAllActions()
        // Tests have no run loop, so groupsByEvent collapses all registrations into one
        // group. Disable it; production code uses explicit begin/end grouping instead.
        vc.undoManager?.groupsByEvent = false
    }

    override func tearDown() {
        vc.undoManager?.removeAllActions()
        window.contentViewController = nil
        window = nil
        vc = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTextAnnotation(at origin: CGPoint = .zero) -> TextAnnotationView {
        TextAnnotationView(at: origin)
    }

    private func makeStickyNote(at origin: CGPoint = .zero) -> StickyNoteView {
        StickyNoteView(at: origin)
    }

    // MARK: - Add annotation

    func testAddAnnotationRegistersUndo() {
        let av = makeTextAnnotation()
        vc.addAnnotation(av)
        XCTAssertTrue(vc.undoManager?.canUndo == true)
    }

    func testAddAnnotationUndoRemovesIt() {
        let av = makeTextAnnotation()
        vc.addAnnotation(av)
        XCTAssertEqual(vc.annotationCount, 1)

        vc.undoManager?.undo()
        XCTAssertEqual(vc.annotationCount, 0)
    }

    func testAddAnnotationUndoThenRedoRestoresIt() {
        let av = makeTextAnnotation()
        vc.addAnnotation(av)

        vc.undoManager?.undo()
        XCTAssertEqual(vc.annotationCount, 0)
        XCTAssertTrue(vc.undoManager?.canRedo == true)

        vc.undoManager?.redo()
        XCTAssertEqual(vc.annotationCount, 1)
    }

    // MARK: - Remove annotation

    func testRemoveAnnotationRegistersUndo() {
        let av = makeTextAnnotation()
        vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()

        vc.removeAnnotation(av)
        XCTAssertTrue(vc.undoManager?.canUndo == true)
    }

    func testRemoveAnnotationUndoRestoresIt() {
        let av = makeTextAnnotation()
        vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()

        vc.removeAnnotation(av)
        XCTAssertEqual(vc.annotationCount, 0)

        vc.undoManager?.undo()
        XCTAssertEqual(vc.annotationCount, 1)
    }

    func testRemoveAnnotationRedoRemovesItAgain() {
        let av = makeTextAnnotation()
        vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()

        vc.removeAnnotation(av)
        vc.undoManager?.undo()
        XCTAssertEqual(vc.annotationCount, 1)

        vc.undoManager?.redo()
        XCTAssertEqual(vc.annotationCount, 0)
    }

    // MARK: - Move annotation

    func testMoveAnnotationRegistersUndo() {
        let av = makeTextAnnotation(at: CGPoint(x: 100, y: 100))
        av.frame = CGRect(x: 100, y: 100, width: 200, height: 80)
        vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()

        vc.moveAnnotation(av, to: CGRect(x: 300, y: 300, width: 200, height: 80))
        XCTAssertTrue(vc.undoManager?.canUndo == true)
    }

    func testMoveAnnotationUndoRestoresOriginalFrame() {
        let original = CGRect(x: 100, y: 100, width: 200, height: 80)
        let av = makeTextAnnotation()
        av.frame = original
        vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()

        let moved = CGRect(x: 300, y: 300, width: 200, height: 80)
        vc.moveAnnotation(av, to: moved)
        XCTAssertEqual(av.frame, moved)

        vc.undoManager?.undo()
        XCTAssertEqual(av.frame, original)
    }

    func testMoveAnnotationRedoReappliesMove() {
        let original = CGRect(x: 50, y: 50, width: 100, height: 60)
        let av = makeTextAnnotation()
        av.frame = original
        vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()

        let moved = CGRect(x: 400, y: 400, width: 100, height: 60)
        vc.moveAnnotation(av, to: moved)
        vc.undoManager?.undo()
        XCTAssertEqual(av.frame, original)

        vc.undoManager?.redo()
        XCTAssertEqual(av.frame, moved)
    }

    // MARK: - Multiple moves undo/redo chain

    func testMultipleMovesUndoInOrder() {
        let frameA = CGRect(x: 0,   y: 0,   width: 100, height: 60)
        let frameB = CGRect(x: 100, y: 100, width: 100, height: 60)
        let frameC = CGRect(x: 200, y: 200, width: 100, height: 60)

        let av = makeTextAnnotation()
        av.frame = frameA
        vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()

        vc.moveAnnotation(av, to: frameB)

        vc.moveAnnotation(av, to: frameC)
        XCTAssertEqual(av.frame, frameC)

        vc.undoManager?.undo()
        XCTAssertEqual(av.frame, frameB)

        vc.undoManager?.undo()
        XCTAssertEqual(av.frame, frameA)
    }

    func testMultipleMovesRedoChain() {
        let frameA = CGRect(x: 0,   y: 0,   width: 100, height: 60)
        let frameB = CGRect(x: 100, y: 100, width: 100, height: 60)
        let frameC = CGRect(x: 200, y: 200, width: 100, height: 60)

        let av = makeTextAnnotation()
        av.frame = frameA
        vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()

        vc.moveAnnotation(av, to: frameB)

        vc.moveAnnotation(av, to: frameC)
        vc.undoManager?.undo()
        vc.undoManager?.undo()
        XCTAssertEqual(av.frame, frameA)

        vc.undoManager?.redo()
        XCTAssertEqual(av.frame, frameB)

        vc.undoManager?.redo()
        XCTAssertEqual(av.frame, frameC)
    }

    // MARK: - Multiple annotation types

    func testStickyNoteAddUndoRemovesIt() {
        let av = makeStickyNote()
        vc.addAnnotation(av)
        XCTAssertEqual(vc.annotationCount, 1)

        vc.undoManager?.undo()
        XCTAssertEqual(vc.annotationCount, 0)
    }

    func testMixedAnnotationUndoIsOrdered() {
        let a1 = makeTextAnnotation()
        let a2 = makeStickyNote()
        vc.addAnnotation(a1)

        vc.addAnnotation(a2)
        XCTAssertEqual(vc.annotationCount, 2)

        vc.undoManager?.undo()  // undo add a2
        XCTAssertEqual(vc.annotationCount, 1)

        vc.undoManager?.undo()  // undo add a1
        XCTAssertEqual(vc.annotationCount, 0)
    }

    // MARK: - Empty stack state

    func testCanUndoIsFalseInitially() {
        XCTAssertFalse(vc.undoManager?.canUndo == true)
    }

    func testCanRedoIsFalseBeforeAnyUndo() {
        let av = makeTextAnnotation()
        vc.addAnnotation(av)
        XCTAssertFalse(vc.undoManager?.canRedo == true)
    }

    func testCanRedoIsFalseAfterNewAction() {
        let av = makeTextAnnotation()
        vc.addAnnotation(av)

        vc.undoManager?.undo()
        XCTAssertTrue(vc.undoManager?.canRedo == true)

        // New action clears redo stack
        let av2 = makeTextAnnotation()
        vc.addAnnotation(av2)
        XCTAssertFalse(vc.undoManager?.canRedo == true)
    }
}

// MARK: - Test accessor

extension CanvasViewController {
    /// Number of live annotations — used only in tests.
    var annotationCount: Int { annotations.count }
}
