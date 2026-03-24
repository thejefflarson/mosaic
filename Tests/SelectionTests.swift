import Testing
import AppKit
@testable import Mosaic

@MainActor
struct SelectionTests {

    let vc: CanvasViewController

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
        self.vc = vc
    }

    private func makeText(at origin: CGPoint = .zero) -> TextAnnotationView {
        TextAnnotationView(at: origin)
    }

    // MARK: - toggleSelection (annotation)

    @Test func toggleAddsAnnotationToSelection() {
        let av = makeText(); vc.addAnnotation(av)
        vc.toggleSelection(av)
        #expect(vc.selectedAnnotationCount == 1)
    }

    @Test func toggleTwiceRemovesAnnotationFromSelection() {
        let av = makeText(); vc.addAnnotation(av)
        vc.toggleSelection(av)
        vc.toggleSelection(av)
        #expect(vc.selectedAnnotationCount == 0)
    }

    @Test func toggleSelectsMultipleAnnotations() {
        let a = makeText(); vc.addAnnotation(a)
        let b = makeText(); vc.addAnnotation(b)
        vc.toggleSelection(a)
        vc.toggleSelection(b)
        #expect(vc.selectedAnnotationCount == 2)
    }

    // MARK: - clearSelection

    @Test func clearEmptiesAnnotationSelection() {
        let av = makeText(); vc.addAnnotation(av)
        vc.toggleSelection(av)
        vc.clearSelection()
        #expect(vc.selectedAnnotationCount == 0)
    }

    @Test func clearIsNoopWhenAlreadyEmpty() {
        // Should not crash or change anything
        vc.clearSelection()
        #expect(vc.selectedAnnotationCount == 0)
    }

    // MARK: - Stale ID cleanup on removal

    @Test func removingAnnotationDeselects() {
        let av = makeText(); vc.addAnnotation(av)
        vc.toggleSelection(av)
        #expect(vc.selectedAnnotationCount == 1)
        vc.removeAnnotation(av)
        #expect(vc.selectedAnnotationCount == 0)
    }

    @Test func removingOneAnnotationLeavesOtherSelected() {
        let a = makeText(); vc.addAnnotation(a)
        let b = makeText(); vc.addAnnotation(b)
        vc.toggleSelection(a)
        vc.toggleSelection(b)
        vc.removeAnnotation(a)
        #expect(vc.selectedAnnotationCount == 1)
    }

    // MARK: - moveSelectionPeers

    @Test func moveSelectionPeersMovesOtherAnnotation() {
        let a = makeText(); a.frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        let b = makeText(); b.frame = CGRect(x: 200, y: 200, width: 100, height: 50)
        vc.addAnnotation(a); vc.addAnnotation(b)
        vc.toggleSelection(a)
        vc.toggleSelection(b)

        vc.moveSelectionPeers(of: a, dx: 10, dy: 5)

        // a is the source — must not move
        #expect(a.frame.origin == CGPoint(x: 0, y: 0))
        // b is a peer — must move by the delta
        #expect(b.frame.origin == CGPoint(x: 210, y: 205))
    }

    @Test func moveSelectionPeersIsNoopWhenSelectionEmpty() {
        let a = makeText(); a.frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        vc.addAnnotation(a)
        // Nothing selected — calling moveSelectionPeers should not move a
        vc.moveSelectionPeers(of: nil, dx: 10, dy: 5)
        #expect(a.frame.origin == CGPoint(x: 0, y: 0))
    }

    @Test func moveSelectionPeersDoesNotMoveUnselectedAnnotation() {
        let a = makeText(); a.frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        let b = makeText(); b.frame = CGRect(x: 200, y: 200, width: 100, height: 50)
        vc.addAnnotation(a); vc.addAnnotation(b)
        // Only select a; b is not selected
        vc.toggleSelection(a)

        vc.moveSelectionPeers(of: nil, dx: 10, dy: 5)

        // a moves (selected, not source)
        #expect(a.frame.origin == CGPoint(x: 10, y: 5))
        // b does not move (not selected)
        #expect(b.frame.origin == CGPoint(x: 200, y: 200))
    }
}

// MARK: - Test accessors

extension CanvasViewController {
    var selectedAnnotationCount: Int { selectedAnnotationIDs.count }
    var selectedTerminalCount: Int   { selectedTerminalIDs.count }
}
