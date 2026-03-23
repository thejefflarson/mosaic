import Testing
import AppKit
@testable import Mosaic

@MainActor
struct UndoTests {

    let vc: CanvasViewController
    let window: NSWindow

    init() {
        let vc = CanvasViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        vc.loadViewIfNeeded()
        vc.undoManager?.removeAllActions()
        // Tests have no run loop, so disable groupsByEvent — production code
        // uses explicit begin/end grouping instead.
        vc.undoManager?.groupsByEvent = false
        self.vc = vc
        self.window = window
    }

    // MARK: - Helpers

    private func makeText(at origin: CGPoint = .zero)   -> TextAnnotationView  { TextAnnotationView(at: origin) }
    private func makeSticky(at origin: CGPoint = .zero) -> StickyNoteView      { StickyNoteView(at: origin) }

    // MARK: - Add annotation

    @Test func addAnnotationRegistersUndo() {
        vc.addAnnotation(makeText())
        #expect(vc.undoManager?.canUndo == true)
    }

    @Test func addAnnotationUndoRemovesIt() {
        vc.addAnnotation(makeText())
        #expect(vc.annotationCount == 1)
        vc.undoManager?.undo()
        #expect(vc.annotationCount == 0)
    }

    @Test func addAnnotationUndoThenRedoRestoresIt() {
        vc.addAnnotation(makeText())
        vc.undoManager?.undo()
        #expect(vc.annotationCount == 0)
        #expect(vc.undoManager?.canRedo == true)
        vc.undoManager?.redo()
        #expect(vc.annotationCount == 1)
    }

    // MARK: - Remove annotation

    @Test func removeAnnotationRegistersUndo() {
        let av = makeText(); vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()
        vc.removeAnnotation(av)
        #expect(vc.undoManager?.canUndo == true)
    }

    @Test func removeAnnotationUndoRestoresIt() {
        let av = makeText(); vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()
        vc.removeAnnotation(av)
        #expect(vc.annotationCount == 0)
        vc.undoManager?.undo()
        #expect(vc.annotationCount == 1)
    }

    @Test func removeAnnotationRedoRemovesItAgain() {
        let av = makeText(); vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()
        vc.removeAnnotation(av)
        vc.undoManager?.undo()
        #expect(vc.annotationCount == 1)
        vc.undoManager?.redo()
        #expect(vc.annotationCount == 0)
    }

    // MARK: - Move annotation

    @Test func moveAnnotationRegistersUndo() {
        let av = makeText(at: CGPoint(x: 100, y: 100))
        av.frame = CGRect(x: 100, y: 100, width: 200, height: 80)
        vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()
        vc.moveAnnotation(av, to: CGRect(x: 300, y: 300, width: 200, height: 80))
        #expect(vc.undoManager?.canUndo == true)
    }

    @Test func moveAnnotationUndoRestoresOriginalFrame() {
        let original = CGRect(x: 100, y: 100, width: 200, height: 80)
        let av = makeText(); av.frame = original; vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()
        let moved = CGRect(x: 300, y: 300, width: 200, height: 80)
        vc.moveAnnotation(av, to: moved)
        #expect(av.frame == moved)
        vc.undoManager?.undo()
        #expect(av.frame == original)
    }

    @Test func moveAnnotationRedoReappliesMove() {
        let original = CGRect(x: 50, y: 50, width: 100, height: 60)
        let av = makeText(); av.frame = original; vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()
        let moved = CGRect(x: 400, y: 400, width: 100, height: 60)
        vc.moveAnnotation(av, to: moved)
        vc.undoManager?.undo()
        #expect(av.frame == original)
        vc.undoManager?.redo()
        #expect(av.frame == moved)
    }

    // MARK: - Multiple moves undo/redo chain

    @Test func multipleMovesUndoInOrder() {
        let frameA = CGRect(x: 0,   y: 0,   width: 100, height: 60)
        let frameB = CGRect(x: 100, y: 100, width: 100, height: 60)
        let frameC = CGRect(x: 200, y: 200, width: 100, height: 60)
        let av = makeText(); av.frame = frameA; vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()
        vc.moveAnnotation(av, to: frameB)
        vc.moveAnnotation(av, to: frameC)
        vc.undoManager?.undo(); #expect(av.frame == frameB)
        vc.undoManager?.undo(); #expect(av.frame == frameA)
    }

    @Test func multipleMovesRedoChain() {
        let frameA = CGRect(x: 0,   y: 0,   width: 100, height: 60)
        let frameB = CGRect(x: 100, y: 100, width: 100, height: 60)
        let frameC = CGRect(x: 200, y: 200, width: 100, height: 60)
        let av = makeText(); av.frame = frameA; vc.addAnnotation(av)
        vc.undoManager?.removeAllActions()
        vc.moveAnnotation(av, to: frameB)
        vc.moveAnnotation(av, to: frameC)
        vc.undoManager?.undo(); vc.undoManager?.undo()
        vc.undoManager?.redo(); #expect(av.frame == frameB)
        vc.undoManager?.redo(); #expect(av.frame == frameC)
    }

    // MARK: - Multiple annotation types

    @Test func stickyNoteAddUndoRemovesIt() {
        vc.addAnnotation(makeSticky())
        #expect(vc.annotationCount == 1)
        vc.undoManager?.undo()
        #expect(vc.annotationCount == 0)
    }

    @Test func mixedAnnotationUndoIsOrdered() {
        vc.addAnnotation(makeText())
        vc.addAnnotation(makeSticky())
        #expect(vc.annotationCount == 2)
        vc.undoManager?.undo()
        #expect(vc.annotationCount == 1)
        vc.undoManager?.undo()
        #expect(vc.annotationCount == 0)
    }

    // MARK: - Empty stack state

    @Test func canUndoIsFalseInitially() {
        #expect(vc.undoManager?.canUndo != true)
    }

    @Test func canRedoIsFalseBeforeAnyUndo() {
        vc.addAnnotation(makeText())
        #expect(vc.undoManager?.canRedo != true)
    }

    @Test func canRedoIsFalseAfterNewAction() {
        vc.addAnnotation(makeText())
        vc.undoManager?.undo()
        #expect(vc.undoManager?.canRedo == true)
        vc.addAnnotation(makeText())
        #expect(vc.undoManager?.canRedo != true)
    }
}

// MARK: - Test accessor

extension CanvasViewController {
    var annotationCount: Int { annotations.count }
}
