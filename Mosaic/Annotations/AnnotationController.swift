import AppKit

/// Owns all annotation views in world space and drives annotation tool behaviour.
/// Created and held by CanvasViewController; all methods run on the main actor.
@MainActor
final class AnnotationController {

    // MARK: - Injected dependencies

    private(set) weak var canvasView: CanvasView?
    /// Indirected so the VC's responder-chain undo manager is always used, never cached.
    private var undoManager: UndoManager? { undoProvider() }
    private let undoProvider: () -> UndoManager?
    private let theme: () -> Theme
    /// Snap a proposed frame against all other elements, excluding one annotation.
    private let snap: (CGRect, AnnotationView?, ResizeHandleView.Edge?) -> CGRect
    private let clearSnap: () -> Void

    // MARK: - Callbacks out

    /// Called after any mutation (add / change / remove). Wire to minimap + rings + save.
    var onChange: (() -> Void)?
    /// Called when an annotation is removed so the caller can drop it from selection state.
    var onRemoved: ((AnnotationView) -> Void)?
    /// Called each drag tick with (view, worldDX, worldDY) for group-move coordination.
    var onDragDelta: ((AnnotationView, CGFloat, CGFloat) -> Void)?
    /// Called when an annotation's drag begins; used to capture peer frames.
    var onDragBegan: ((AnnotationView) -> Void)?
    /// Called after an annotation's undo action is registered; used to register group-move peer undos.
    var onMoveEnded: ((AnnotationView) -> Void)?

    // MARK: - State

    private(set) var annotations: [AnnotationView] = []
    private var activeAnnotation: AnnotationView?

    // MARK: - Init

    init(canvasView: CanvasView,
         undoManager: @escaping () -> UndoManager?,
         theme: @escaping () -> Theme,
         snap: @escaping (CGRect, AnnotationView?, ResizeHandleView.Edge?) -> CGRect,
         clearSnap: @escaping () -> Void) {
        self.canvasView   = canvasView
        self.undoProvider = undoManager
        self.theme        = theme
        self.snap         = snap
        self.clearSnap    = clearSnap
    }

    // MARK: - Tool events

    func toolBegan(_ tool: CanvasTool, at worldPt: CGPoint) {
        switch tool {
        case .text:
            let av = TextAnnotationView(at: worldPt)
            av.applyTheme(theme())
            add(av)
            av.beginEditing()

        case .stickyNote:
            let av = StickyNoteView(at: worldPt)
            av.applyTheme(theme())
            add(av)
            av.beginEditing()

        case .arrow:
            let av = ArrowAnnotationView(start: worldPt, end: worldPt)
            av.applyTheme(theme())
            activeAnnotation = av
            add(av)

        case .pen:
            let av = FreehandAnnotationView(at: worldPt)
            av.applyTheme(theme())
            activeAnnotation = av
            add(av)

        case .image:
            pickImage(at: worldPt)

        default: break
        }
    }

    func toolMoved(_ tool: CanvasTool, at worldPt: CGPoint) {
        switch tool {
        case .arrow:
            (activeAnnotation as? ArrowAnnotationView)?.updateEnd(worldPt)
            onChange?()
        case .pen:
            (activeAnnotation as? FreehandAnnotationView)?.addWorldPoint(worldPt)
            onChange?()
        default: break
        }
    }

    func toolEnded(_ tool: CanvasTool, at worldPt: CGPoint) {
        if tool == .arrow {
            (activeAnnotation as? ArrowAnnotationView)?.updateEnd(worldPt)
        }
        activeAnnotation = nil
    }

    // MARK: - CRUD

    func add(_ av: AnnotationView) {
        wire(av)
        undoManager?.setActionName("Add Annotation")
        undoManager?.registerUndo(withTarget: self) { @MainActor [weak av] ac in
            guard let av else { return }
            ac.remove(av)
        }
        annotations.append(av)
        canvasView?.addAnnotation(av)
        onChange?()
    }

    func remove(_ av: AnnotationView) {
        undoManager?.setActionName("Delete Annotation")
        // Strong capture: av is removed from the view hierarchy below, so nothing else
        // retains it. The undo manager must hold it alive until the history is cleared.
        undoManager?.registerUndo(withTarget: self) { @MainActor ac in
            ac.add(av)
        }
        annotations.removeAll { $0 === av }
        canvasView?.removeAnnotation(av)
        onRemoved?(av)
        onChange?()
    }

    func move(_ av: AnnotationView, to newFrame: CGRect) {
        let oldFrame = av.frame
        undoManager?.setActionName("Move Annotation")
        undoManager?.registerUndo(withTarget: self) { @MainActor [weak av] ac in
            guard let av else { return }
            ac.move(av, to: oldFrame)
        }
        av.frame = newFrame
        onChange?()
    }

    func applyTheme(_ theme: Theme) {
        annotations.forEach { $0.applyTheme(theme) }
    }

    // MARK: - Restore from snapshot

    func restore(_ s: AnnotationSnapshot) {
        let frame = CGRect(x: s.x, y: s.y, width: s.width, height: s.height)
        switch s.kind {
        case .text:
            let av = TextAnnotationView(at: frame.origin, text: s.content ?? "")
            av.frame = frame
            av.applyTheme(theme())
            add(av)

        case .stickyNote:
            let color = StickyNoteView.NoteColor(rawValue: s.colorName ?? "yellow") ?? .yellow
            let av = StickyNoteView(at: frame.origin, color: color, text: s.content ?? "")
            av.frame = frame
            av.applyTheme(theme())
            add(av)

        case .arrow:
            guard let pts = s.points, pts.count >= 2 else { return }
            let av = ArrowAnnotationView(start: CGPoint(x: pts[0].x, y: pts[0].y),
                                         end:   CGPoint(x: pts[1].x, y: pts[1].y))
            av.applyTheme(theme())
            add(av)

        case .freehand:
            guard let pts = s.points else { return }
            let av = FreehandAnnotationView(at: CGPoint(x: s.x, y: s.y))
            av.loadWorldPoints(pts.map { CGPoint(x: $0.x, y: $0.y) })
            av.strokeWidth = s.lineWidth ?? 2
            av.applyTheme(theme())
            add(av)

        case .image:
            guard let path = s.imagePath,
                  let safePath = Self.containedImagePath(path,
                                                         imagesDirectory: WorkspaceStore.shared.imagesDirectory)
            else { return }
            guard let image = NSImage(contentsOfFile: safePath) else { return }
            let av = ImageAnnotationView(at: frame.origin, image: image)
            av.frame = frame
            av.applyTheme(theme())
            add(av)
        }
    }

    /// Validate that `path` resolves to a file under `imagesDirectory` after
    /// canonicalisation (folds `..` segments and symlinks). Returns the canonical
    /// path on success; nil if the path escapes the directory.
    /// Pulled out as a static function so we can unit-test the containment.
    static func containedImagePath(_ path: String, imagesDirectory: URL) -> String? {
        let allowedRoot = URL(fileURLWithPath: imagesDirectory.path)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath().standardizedFileURL
        let rootPath = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
        guard candidate.path == allowedRoot.path || candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate.path
    }

    // MARK: - Delete-tool helpers

    func annotationAtPoint(_ pt: CGPoint) -> AnnotationView? {
        annotations.first { $0.frame.contains(pt) }
    }

    func annotationsIntersecting(_ rect: CGRect) -> [AnnotationView] {
        annotations.filter { rect.intersects($0.frame) }
    }

    // MARK: - Private

    private func wire(_ av: AnnotationView) {
        av.onDelete = { [weak self, weak av] in
            guard let self, let av else { return }
            remove(av)
        }
        av.onChanged = { [weak self] in
            self?.onChange?()
        }
        av.onDragDelta = { [weak self, weak av] dx, dy in
            guard let self, let av else { return }
            onDragDelta?(av, dx, dy)
        }
        av.onDragBegan = { [weak self, weak av] in
            guard let self, let av else { return }
            onDragBegan?(av)
        }
        av.onDragEnded = { [weak self, weak av] fromFrame, _ in
            guard let self, let av else { return }
            undoManager?.setActionName("Move Annotation")
            undoManager?.registerUndo(withTarget: self) { @MainActor [weak av] ac in
                guard let av else { return }
                ac.move(av, to: fromFrame)
            }
            onMoveEnded?(av)
        }
        av.snapFrame = { [weak self, weak av] proposed, edge in
            guard let self else { return proposed }
            return snap(proposed, av, edge)
        }
        av.clearSnapGuides = { [weak self] in
            self?.clearSnap()
        }
    }

    private func pickImage(at worldPt: CGPoint) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let av = ImageAnnotationView(at: worldPt, url: url) else {
                let alert = NSAlert()
                alert.messageText = "Couldn't open image"
                alert.informativeText = "\(url.lastPathComponent) could not be read as an image."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            add(av)
        }
    }
}
