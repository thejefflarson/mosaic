import Testing
import AppKit
@testable import Mosaic

/// Tests that restoreAnnotation applies the active theme's colors and fonts
/// to each annotation kind correctly.
@MainActor
struct AnnotationRestorationTests {

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

    // Snapshot helpers

    private func textSnap(content: String = "hello") -> AnnotationSnapshot {
        AnnotationSnapshot(id: UUID(), kind: .text, x: 10, y: 10, width: 400, height: 150,
                           content: content)
    }

    private func stickySnap(color: String = "yellow") -> AnnotationSnapshot {
        AnnotationSnapshot(id: UUID(), kind: .stickyNote, x: 0, y: 0, width: 200, height: 160,
                           content: "sticky", colorName: color)
    }

    private func arrowSnap() -> AnnotationSnapshot {
        AnnotationSnapshot(id: UUID(), kind: .arrow, x: 0, y: 0, width: 200, height: 100,
                           points: [PointSnapshot(x: 0, y: 0), PointSnapshot(x: 200, y: 100)])
    }

    private func freehandSnap() -> AnnotationSnapshot {
        let pts = (0..<3).map { PointSnapshot(x: CGFloat($0) * 10, y: CGFloat($0) * 5) }
        return AnnotationSnapshot(id: UUID(), kind: .freehand, x: 0, y: 0, width: 40, height: 20,
                                  points: pts, lineWidth: 3)
    }

    // MARK: - Text annotation

    @Test func textAnnotationGetsThemeAnnotationColor() {
        vc.restoreAnnotation(textSnap())
        let av = vc.annotations.last as? TextAnnotationView
        #expect(av?.textColor == vc.currentTheme.annotationColor)
    }

    @Test func textAnnotationGetsThemeAnnotationFont() {
        vc.restoreAnnotation(textSnap())
        let av = vc.annotations.last as? TextAnnotationView
        #expect(av?.annotationFont == vc.currentTheme.annotationFont)
    }

    @Test func textAnnotationContentPreserved() {
        vc.restoreAnnotation(textSnap(content: "canvas note"))
        let av = vc.annotations.last as? TextAnnotationView
        #expect(av != nil)
    }

    // MARK: - Sticky note

    @Test func stickyNoteGetsThemeForeground() {
        vc.restoreAnnotation(stickySnap())
        let av = vc.annotations.last as? StickyNoteView
        #expect(av?.themeForeground == vc.currentTheme.stickyForeground)
    }

    @Test func stickyNoteGetsThemeBackground() {
        vc.restoreAnnotation(stickySnap())
        let av = vc.annotations.last as? StickyNoteView
        #expect(av?.themeBackground == vc.currentTheme.stickyBackground)
    }

    @Test func stickyNoteColorNamePreserved() {
        vc.restoreAnnotation(stickySnap(color: "blue"))
        #expect(vc.annotations.last is StickyNoteView)
    }

    @Test func stickyNoteUnknownColorDefaultsToYellow() {
        // An unrecognized colorName must not crash — falls back to .yellow.
        vc.restoreAnnotation(stickySnap(color: "ultraviolet"))
        #expect(vc.annotations.last is StickyNoteView)
    }

    // MARK: - Arrow

    @Test func arrowAnnotationGetsThemeStrokeColor() {
        vc.restoreAnnotation(arrowSnap())
        let av = vc.annotations.last as? ArrowAnnotationView
        #expect(av?.strokeColor == vc.currentTheme.annotationColor)
    }

    @Test func arrowWithTooFewPointsIsDropped() {
        let bad = AnnotationSnapshot(id: UUID(), kind: .arrow, x: 0, y: 0, width: 100, height: 50,
                                     points: [PointSnapshot(x: 0, y: 0)])
        let before = vc.annotations.count
        vc.restoreAnnotation(bad)
        #expect(vc.annotations.count == before)
    }

    @Test func arrowWithNoPointsIsDropped() {
        let bad = AnnotationSnapshot(id: UUID(), kind: .arrow, x: 0, y: 0, width: 100, height: 50)
        let before = vc.annotations.count
        vc.restoreAnnotation(bad)
        #expect(vc.annotations.count == before)
    }

    // MARK: - Freehand

    @Test func freehandAnnotationGetsThemeStrokeColor() {
        vc.restoreAnnotation(freehandSnap())
        let av = vc.annotations.last as? FreehandAnnotationView
        #expect(av?.strokeColor == vc.currentTheme.annotationColor)
    }

    @Test func freehandAnnotationStrokeWidthPreserved() {
        vc.restoreAnnotation(freehandSnap())
        let av = vc.annotations.last as? FreehandAnnotationView
        #expect(av?.strokeWidth == 3)
    }

    @Test func freehandWithNoPointsIsDropped() {
        let bad = AnnotationSnapshot(id: UUID(), kind: .freehand, x: 0, y: 0, width: 50, height: 50)
        let before = vc.annotations.count
        vc.restoreAnnotation(bad)
        #expect(vc.annotations.count == before)
    }

    // MARK: - Annotation count

    @Test func eachRestoreAddsExactlyOneAnnotation() {
        let before = vc.annotations.count
        vc.restoreAnnotation(textSnap())
        vc.restoreAnnotation(stickySnap())
        vc.restoreAnnotation(arrowSnap())
        vc.restoreAnnotation(freehandSnap())
        #expect(vc.annotations.count == before + 4)
    }
}
