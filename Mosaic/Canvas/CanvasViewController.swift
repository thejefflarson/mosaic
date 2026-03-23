import AppKit
import CoreVideo

// MARK: - Snap guide overlay

/// Transparent view that draws alignment guide lines during drag operations.
private final class SnapGuideOverlay: NSView {
    var guides: [(isVertical: Bool, pos: CGFloat)] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !guides.isEmpty else { return }
        let path = NSBezierPath()
        path.lineWidth = 1
        path.setLineDash([5, 3], count: 2, phase: 0)
        for guide in guides {
            if guide.isVertical {
                path.move(to: NSPoint(x: guide.pos, y: 0))
                path.line(to: NSPoint(x: guide.pos, y: bounds.height))
            } else {
                path.move(to: NSPoint(x: 0, y: guide.pos))
                path.line(to: NSPoint(x: bounds.width, y: guide.pos))
            }
        }
        NSColor.systemBlue.withAlphaComponent(0.75).setStroke()
        path.stroke()
    }
}

private extension CVTimeStamp {
    var timeInterval: CFTimeInterval { CFTimeInterval(videoTime) / CFTimeInterval(videoTimeScale) }
}

final class CanvasViewController: NSViewController {

    private static let defaultShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    // MARK: - Subviews

    private let canvasView = CanvasView()
    private let minimapView = MinimapView()
    private let terminalManager = TerminalManager()
    private let toolPalette = ToolPaletteView()
    private let fpsLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        f.textColor = NSColor(white: 1, alpha: 0.6)
        f.backgroundColor = NSColor(white: 0, alpha: 0.45)
        f.drawsBackground = true
        f.isBezeled = false
        f.isHidden = true
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()
    private let zoomLabel: NSTextField = {
        let f = NSTextField(labelWithString: "100%")
        f.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        f.textColor = NSColor(white: 1, alpha: 0.5)
        f.backgroundColor = NSColor(white: 0, alpha: 0.35)
        f.drawsBackground = true
        f.isBezeled = false
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()
    nonisolated(unsafe) private var fpsDisplayLink: CVDisplayLink?
    nonisolated(unsafe) private var pendingViewportUpdate = false
    private var fpsFrameTimes: [CFTimeInterval] = []

    // MARK: - State

    private var broadcastMode = false
    private var saveDebounceTimer: Timer?
    private var workspaceRestored = false
    var currentTheme: Theme = {
        let id = UserDefaults.standard.string(forKey: "themeID") ?? Theme.dark.id
        return Theme.allThemes.first { $0.id == id } ?? .dark
    }()

    private var themeEditorWindow: NSWindow?
    private var terminalSettingsWindow: NSWindow?
    private var deleteSelectionStart: CGPoint?

    /// All live annotation views (in world space).
    var annotations: [AnnotationView] = []
    /// In-progress annotation during freehand/arrow draw.
    private var activeAnnotation: AnnotationView?

    // MARK: - Lifecycle

    deinit {
        if let link = fpsDisplayLink { CVDisplayLinkStop(link) }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCanvas()
        setupMinimap()
        setupToolPalette()
        setupFPSOverlay()
        setupZoomLabel()
        setupSnapOverlay()
        setupAccessibility()
    }

    private func setupAccessibility() {
        canvasView.setAccessibilityLabel("Canvas")
        canvasView.setAccessibilityRole(.scrollArea)
        minimapView.setAccessibilityLabel("Minimap")
        minimapView.setAccessibilityRole(.image)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !workspaceRestored else { return }
        workspaceRestored = true
        restoreWorkspace()
    }

    // MARK: - Setup

    private func setupCanvas() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        canvasView.setCanvasBackground(currentTheme.canvasBackground)

        canvasView.onBackgroundDoubleClick = { [weak self] worldPt in
            self?.spawnTerminal(at: worldPt)
        }

        canvasView.onViewportChanged = { [weak self] _ in
            guard let self else { return }
            updateMinimap()
            updateZoomLabel()
            scheduleSave()
            pendingViewportUpdate = true
            if toolPalette.focusFollowsCenter { updateFocusFollowsCenter() }
        }
    }

    private func setupToolPalette() {
        toolPalette.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolPalette)
        NSLayoutConstraint.activate([
            toolPalette.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolPalette.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])

        toolPalette.onToolSelected = { [weak self] tool in
            self?.canvasView.activeTool = tool
        }

        canvasView.onToolBegan = { [weak self] tool, worldPt in
            self?.handleToolBegan(tool, at: worldPt)
        }
        canvasView.onToolMoved = { [weak self] tool, worldPt in
            self?.handleToolMoved(tool, at: worldPt)
        }
        canvasView.onToolEnded = { [weak self] tool, worldPt in
            self?.handleToolEnded(tool, at: worldPt)
        }
    }

    private func setupMinimap() {
        minimapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(minimapView)
        NSLayoutConstraint.activate([
            minimapView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            minimapView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            minimapView.widthAnchor.constraint(equalToConstant: 180),
            minimapView.heightAnchor.constraint(equalToConstant: 120),
        ])

        minimapView.canvasView = canvasView

        minimapView.onPanToWorld = { [weak self] worldPt in
            guard let self else { return }
            var vp = canvasView.viewport
            vp.panX = -worldPt.x * vp.zoom + canvasView.bounds.width / 2
            vp.panY = -worldPt.y * vp.zoom + canvasView.bounds.height / 2
            canvasView.setViewport(vp)
        }
    }

    // MARK: - Zoom label

    private func setupZoomLabel() {
        view.addSubview(zoomLabel)
        NSLayoutConstraint.activate([
            zoomLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            zoomLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        let pct = Int((canvasView.viewport.zoom * 100).rounded())
        zoomLabel.stringValue = " \(pct)% "
    }

    // MARK: - FPS overlay

    private func setupFPSOverlay() {
        view.addSubview(fpsLabel)
        NSLayoutConstraint.activate([
            fpsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            fpsLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
        ])

        CVDisplayLinkCreateWithActiveCGDisplays(&fpsDisplayLink)
        guard let link = fpsDisplayLink else { return }
        CVDisplayLinkSetOutputCallback(link, { _, _, now, _, _, ctx -> CVReturn in
            guard let ctx else { return kCVReturnSuccess }
            let vc = Unmanaged<CanvasViewController>.fromOpaque(ctx).takeUnretainedValue()
            let t = now.pointee.timeInterval
            // Only count ticks where the canvas actually rendered a new frame.
            // This shows real canvas FPS rather than the display's hardware refresh rate.
            guard vc.pendingViewportUpdate else {
                // Nothing rendered — if the last recorded frame is > 1s old, show 0.
                DispatchQueue.main.async {
                    vc.fpsFrameTimes.removeAll { $0 < t - 1.0 }
                    if vc.fpsFrameTimes.isEmpty {
                        vc.fpsLabel.stringValue = " 0 fps "
                    }
                }
                return kCVReturnSuccess
            }
            vc.pendingViewportUpdate = false
            DispatchQueue.main.async {
                vc.fpsFrameTimes.append(t)
                vc.fpsFrameTimes.removeAll { $0 < t - 1.0 }
                vc.fpsLabel.stringValue = " \(vc.fpsFrameTimes.count) fps "
            }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    @objc func toggleFPSOverlay() {
        guard let link = fpsDisplayLink else { return }
        let showing = !fpsLabel.isHidden
        fpsLabel.isHidden = showing
        if showing {
            CVDisplayLinkStop(link)
        } else {
            CVDisplayLinkStart(link)
        }
    }

    // MARK: - Terminal spawning

    @objc func spawnTerminalAtCenter() {
        let center = canvasView.viewport.screenToWorld(
            CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
        )
        spawnTerminal(at: center)
    }

    private func spawnTerminal(at worldPt: CGPoint, shell: String = CanvasViewController.defaultShell, cwd: String? = nil) {
        let size = CGSize(width: 600, height: 400)
        let origin = CGPoint(x: worldPt.x - size.width / 2, y: worldPt.y - size.height / 2)
        let frame = CGRect(origin: origin, size: size)
        spawnTerminalWithFrame(frame, shell: shell, cwd: cwd)
    }

    private func spawnTerminalWithFrame(_ frame: CGRect, shell: String = CanvasViewController.defaultShell, cwd: String? = nil, scrollback: String? = nil) {
        // Validate that the shell path is an executable file before spawning.
        // Guards against a tampered workspace.json specifying an arbitrary path.
        let resolvedShell: String
        if FileManager.default.isExecutableFile(atPath: shell) {
            resolvedShell = shell
        } else {
            resolvedShell = CanvasViewController.defaultShell
        }

        let tw = terminalManager.spawn(frame: frame, shell: resolvedShell, cwd: cwd)
        tw.restoredScrollback = scrollback
        tw.canvasView = canvasView
        tw.theme = currentTheme

        tw.onClose = { [weak self, weak tw] in
            guard let self, let tw else { return }
            self.removeTerminal(tw)
        }

        tw.onMoved = { [weak self] in
            self?.updateMinimap()
            self?.scheduleSave()
        }

        tw.onMoveEnded = { [weak self, weak tw] fromFrame, toFrame in
            guard let self, let tw else { return }
            undoManager?.setActionName("Move Terminal")
            undoManager?.registerUndo(withTarget: self) { @MainActor vc in
                vc.moveTerminal(tw, to: fromFrame)
            }
        }
        tw.snapFrame = { [weak self, weak tw] proposed, edge in
            guard let self else { return proposed }
            return self.snapPosition(proposed, excludingTerminal: tw, edge: edge)
        }
        tw.clearSnapGuides = { [weak self] in self?.snapOverlay.guides = [] }

        tw.onBroadcastKey = { [weak self] data in
            self?.broadcastKeyData(data, excluding: tw)
        }

        canvasView.addTerminal(tw)
        canvasView.activateTerminal(tw)
        tw.focusTerminal()

        undoManager?.setActionName("New Terminal")
        undoManager?.registerUndo(withTarget: self) { @MainActor [weak tw] vc in
            guard let tw else { return }
            vc.removeTerminal(tw)
        }

        updateMinimap()
        scheduleSave()
    }

    private func removeTerminal(_ tw: TerminalWindowView) {
        let savedFrame = tw.frame
        let savedShell = tw.shell
        let savedCwd   = tw.currentCwd
        undoManager?.setActionName("Close Terminal")
        undoManager?.registerUndo(withTarget: self) { @MainActor vc in
            vc.spawnTerminalWithFrame(savedFrame, shell: savedShell, cwd: savedCwd)
        }
        // Nil out onClose before kill: terminate() sends EOF which causes the shell to
        // exit, firing processTerminated -> onClose -> removeTerminal a second time,
        // which would register a duplicate undo entry and produce two terminals on undo.
        tw.onClose = nil
        terminalManager.kill(tw)
        updateMinimap()
        scheduleSave()
    }

    private func moveTerminal(_ tw: TerminalWindowView, to newFrame: CGRect) {
        let oldFrame = tw.frame
        undoManager?.setActionName("Move Terminal")
        undoManager?.registerUndo(withTarget: self) { @MainActor [weak tw] vc in
            guard let tw else { return }
            vc.moveTerminal(tw, to: oldFrame)
        }
        tw.frame = newFrame
        updateMinimap()
        scheduleSave()
    }

    // MARK: - Annotation tool handling

    private func handleToolBegan(_ tool: CanvasTool, at worldPt: CGPoint) {
        switch tool {
        case .pointer: break

        case .delete:
            deleteSelectionStart = worldPt
            canvasView.setSelectionRect(CGRect(origin: worldPt, size: .zero))

        case .terminal:
            spawnTerminal(at: worldPt)
            setTool(.pointer)

        case .text:
            let av = TextAnnotationView(at: worldPt)
            av.textColor = currentTheme.annotationColor
            av.annotationFont = currentTheme.annotationFont
            addAnnotation(av)
            av.beginEditing()

        case .stickyNote:
            let av = StickyNoteView(at: worldPt)
            av.themeForeground = currentTheme.stickyForeground
            av.themeBackground = currentTheme.stickyBackground
            addAnnotation(av)
            av.beginEditing()

        case .arrow:
            let av = ArrowAnnotationView(start: worldPt, end: worldPt)
            av.strokeColor = currentTheme.annotationColor
            activeAnnotation = av
            addAnnotation(av)

        case .pen:
            let av = FreehandAnnotationView(at: worldPt)
            av.strokeColor = currentTheme.annotationColor
            activeAnnotation = av
            addAnnotation(av)

        case .image:
            pickImage(at: worldPt)
        }
    }

    private func handleToolMoved(_ tool: CanvasTool, at worldPt: CGPoint) {
        switch tool {
        case .delete:
            guard let start = deleteSelectionStart else { return }
            canvasView.setSelectionRect(selectionRect(from: start, to: worldPt))
        case .arrow:
            (activeAnnotation as? ArrowAnnotationView)?.updateEnd(worldPt)
            updateMinimap()
        case .pen:
            (activeAnnotation as? FreehandAnnotationView)?.addWorldPoint(worldPt)
            updateMinimap()
        default: break
        }
    }

    private func handleToolEnded(_ tool: CanvasTool, at worldPt: CGPoint) {
        switch tool {
        case .delete:
            canvasView.setSelectionRect(nil)
            guard let start = deleteSelectionStart else { break }
            deleteSelectionStart = nil
            let rect = selectionRect(from: start, to: worldPt)
            if rect.width < 5 && rect.height < 5 {
                // Single click — point hit test
                if let tw = terminalManager.windows.first(where: { $0.frame.contains(worldPt) }) {
                    tw.onClose?()
                } else if let av = annotations.first(where: { $0.frame.contains(worldPt) }) {
                    removeAnnotation(av)
                }
            } else {
                // Drag — delete everything intersecting the selection rect
                for tw in terminalManager.windows.filter({ rect.intersects($0.frame) }) { tw.onClose?() }
                for av in annotations.filter({ rect.intersects($0.frame) }) { removeAnnotation(av) }
            }
        case .arrow:
            (activeAnnotation as? ArrowAnnotationView)?.updateEnd(worldPt)
        default: break
        }
        activeAnnotation = nil
        scheduleSave()
    }

    private func selectionRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func addAnnotation(_ av: AnnotationView) {
        av.onDelete = { [weak self, weak av] in
            guard let av else { return }
            self?.removeAnnotation(av)
        }
        av.onChanged = { [weak self] in
            self?.updateMinimap()
            self?.scheduleSave()
        }
        av.onDragEnded = { [weak self, weak av] fromFrame, _ in
            guard let self, let av else { return }
            undoManager?.beginUndoGrouping()
            undoManager?.setActionName("Move")
            undoManager?.registerUndo(withTarget: self) { @MainActor [weak av] vc in
                guard let av else { return }
                vc.moveAnnotation(av, to: fromFrame)
            }
            undoManager?.endUndoGrouping()
        }
        av.snapFrame = { [weak self, weak av] proposed, edge in
            guard let self else { return proposed }
            return self.snapPosition(proposed, excludingAnnotation: av, edge: edge)
        }
        av.clearSnapGuides = { [weak self] in self?.snapOverlay.guides = [] }
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Add Annotation")
        undoManager?.registerUndo(withTarget: self) { @MainActor [weak av] vc in
            guard let av else { return }
            vc.removeAnnotation(av)
        }
        undoManager?.endUndoGrouping()
        annotations.append(av)
        canvasView.addAnnotation(av)
        updateMinimap()
    }

    func removeAnnotation(_ av: AnnotationView) {
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Delete Annotation")
        // Strong capture: av is removed from the view hierarchy below, so nothing
        // else retains it. The undo manager must hold it alive until undo is cleared.
        undoManager?.registerUndo(withTarget: self) { @MainActor vc in
            vc.addAnnotation(av)
        }
        undoManager?.endUndoGrouping()
        annotations.removeAll { $0 === av }
        canvasView.removeAnnotation(av)
        updateMinimap()
        scheduleSave()
    }

    func moveAnnotation(_ av: AnnotationView, to newFrame: CGRect) {
        let oldFrame = av.frame
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move")
        undoManager?.registerUndo(withTarget: self) { @MainActor [weak av] vc in
            guard let av else { return }
            vc.moveAnnotation(av, to: oldFrame)
        }
        undoManager?.endUndoGrouping()
        av.frame = newFrame
        updateMinimap()
        scheduleSave()
    }

    private func pickImage(at worldPt: CGPoint) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            let av = ImageAnnotationView(at: worldPt, image: image)
            addAnnotation(av)
        }
    }

    // MARK: - Snap overlay

    private let snapOverlay = SnapGuideOverlay()

    private func setupSnapOverlay() {
        snapOverlay.translatesAutoresizingMaskIntoConstraints = false
        snapOverlay.isHidden = false
        view.addSubview(snapOverlay, positioned: .above, relativeTo: canvasView)
        NSLayoutConstraint.activate([
            snapOverlay.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor),
            snapOverlay.trailingAnchor.constraint(equalTo: canvasView.trailingAnchor),
            snapOverlay.topAnchor.constraint(equalTo: canvasView.topAnchor),
            snapOverlay.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor),
        ])
    }

    private func allElementFrames(excludingAnnotation: AnnotationView? = nil,
                                   excludingTerminal: TerminalWindowView? = nil) -> [CGRect] {
        // Only use bounding-box annotations (sticky notes, text) as snap references.
        // Drawing annotations (arrows, freehand, images) have padded or irregular frames
        // that don't correspond to visible rectangular boundaries, so they create
        // confusing phantom snap points near real elements.
        let boxAnnotations = annotations.filter {
            $0 !== excludingAnnotation && ($0 is StickyNoteView || $0 is TextAnnotationView || $0 is ImageAnnotationView)
        }
        return terminalManager.windows.filter { $0 !== excludingTerminal }.map(\.frame)
            + boxAnnotations.map(\.frame)
    }

    private func snapPosition(_ proposed: CGRect,
                               excludingAnnotation: AnnotationView? = nil,
                               excludingTerminal: TerminalWindowView? = nil,
                               edge: ResizeHandleView.Edge? = nil) -> CGRect {
        guard toolPalette.snappingEnabled else { return proposed }
        let threshold = 4.0 / canvasView.viewport.zoom
        let others = allElementFrames(excludingAnnotation: excludingAnnotation,
                                      excludingTerminal: excludingTerminal)
        let (movingX, movingY): ([CGFloat]?, [CGFloat]?)
        if let edge {
            switch edge {
            case .left:       movingX = [proposed.minX]; movingY = []
            case .right:      movingX = [proposed.maxX]; movingY = []
            case .top:        movingX = [];              movingY = [proposed.minY]
            case .bottom:     movingX = [];              movingY = [proposed.maxY]
            case .topLeft:    movingX = [proposed.minX]; movingY = [proposed.minY]
            case .topRight:   movingX = [proposed.maxX]; movingY = [proposed.minY]
            case .bottomLeft: movingX = [proposed.minX]; movingY = [proposed.maxY]
            case .bottomRight:movingX = [proposed.maxX]; movingY = [proposed.maxY]
            }
        } else {
            movingX = nil; movingY = nil
        }
        let snap = snapRect(proposed, to: others, threshold: threshold,
                            movingX: movingX, movingY: movingY)

        var guides: [(isVertical: Bool, pos: CGFloat)] = []
        if let wx = snap.worldX {
            guides.append((true, canvasView.viewport.worldToScreen(CGPoint(x: wx, y: 0)).x))
        }
        if let wy = snap.worldY {
            guides.append((false, canvasView.viewport.worldToScreen(CGPoint(x: 0, y: wy)).y))
        }
        snapOverlay.guides = guides
        return snap.rect
    }

    @objc func toggleSnapping() {
        toolPalette.snappingEnabled.toggle()
    }

    // MARK: - Tool keyboard shortcuts

    override func keyDown(with event: NSEvent) {
        // Only handle shortcuts when the canvas itself has focus (not a text field or terminal).
        guard view.window?.firstResponder === canvasView ||
              view.window?.firstResponder === view else {
            super.keyDown(with: event)
            return
        }
        // Don't intercept when a modifier is held — lets Cmd+V, Cmd+C, etc. pass through.
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": setTool(.pointer)
        case "t": setTool(.terminal)
        case "l": setTool(.text)
        case "n": setTool(.stickyNote)
        case "a": setTool(.arrow)
        case "p": setTool(.pen)
        case "i": setTool(.image)
        case "x": setTool(.delete)
        default:  super.keyDown(with: event)
        }
    }

    private func setTool(_ tool: CanvasTool) {
        canvasView.activeTool = tool
        toolPalette.selectTool(tool)
    }

    // MARK: - Themes

    @objc func selectTheme(_ sender: NSMenuItem) {
        let theme = Theme.allThemes[sender.tag]
        applyTheme(theme)
    }

    private func applyTheme(_ theme: Theme) {
        currentTheme = theme
        UserDefaults.standard.set(theme.id, forKey: "themeID")
        canvasView.setCanvasBackground(theme.canvasBackground)
        for w in terminalManager.windows { w.applyTheme(theme) }
        for av in annotations {
            switch av {
            case let sv as StickyNoteView:
                sv.themeForeground = theme.stickyForeground
                sv.themeBackground = theme.stickyBackground
            case let tv as TextAnnotationView:
                tv.textColor = theme.annotationColor
                tv.annotationFont = theme.annotationFont
            case let ar as ArrowAnnotationView:
                ar.strokeColor = theme.annotationColor
            case let fh as FreehandAnnotationView:
                fh.strokeColor = theme.annotationColor
            default:
                break
            }
        }
        updateMinimap()
    }

    @objc func openThemeEditor() {
        if let existing = themeEditorWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let vc = ThemeEditorViewController(theme: currentTheme)

        vc.onApply = { [weak self] theme in
            guard let self else { return }
            // Auto-save: if this is an existing custom theme, update it in-place.
            var custom = Theme.customThemes
            if custom.contains(where: { $0.id == theme.id }) {
                custom.removeAll { $0.id == theme.id }
                custom.append(theme)
                Theme.customThemes = custom
                NotificationCenter.default.post(name: .themesDidChange, object: nil)
            }
            applyTheme(theme)
        }

        vc.onSave = { [weak self] theme in
            guard let self else { return }
            var custom = Theme.customThemes
            custom.removeAll { $0.name == theme.name }
            custom.append(theme)
            Theme.customThemes = custom
            applyTheme(theme)
            NotificationCenter.default.post(name: .themesDidChange, object: nil)
        }

        vc.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(
            contentRect: .zero,
            styleMask:   [.titled, .closable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        panel.title = "Theme Editor"
        panel.contentViewController = vc
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.themeEditorWindow = nil }
        }
        themeEditorWindow = panel
    }

    @objc func openTerminalSettings() {
        if let existing = terminalSettingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let vc = TerminalSettingsViewController()
        vc.onApply = { [weak self] settings in
            self?.terminalManager.windows.forEach { $0.applyTerminalSettings(settings) }
        }
        vc.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Terminal Settings"
        panel.contentViewController = vc
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.terminalSettingsWindow = nil }
        }
        terminalSettingsWindow = panel
    }

    // MARK: - Broadcast

    @objc func toggleBroadcast() {
        broadcastMode.toggle()
        canvasView.broadcastModeActive = broadcastMode
        for w in terminalManager.windows {
            w.setBroadcastHighlight(broadcastMode)
        }
        // Ensure a terminal has focus so typing broadcasts immediately
        if broadcastMode, let first = terminalManager.windows.first {
            first.focusTerminal()
        }
    }

    private func broadcastKeyData(_ data: Data, excluding source: TerminalWindowView) {
        guard broadcastMode else { return }
        for w in terminalManager.windows where w !== source {
            w.sendInput(data)
        }
    }

    // MARK: - Workspace persistence

    private func restoreWorkspace() {
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }

        guard let snapshot = WorkspaceStore.shared.load() else {
            // First launch: spawn one terminal in the center
            spawnTerminalAtCenter()
            return
        }

        for w in snapshot.windows {
            spawnTerminalWithFrame(
                CGRect(x: w.x, y: w.y, width: w.width, height: w.height),
                cwd: w.cwd,
                scrollback: w.scrollback
            )
        }

        for s in snapshot.annotations {
            restoreAnnotation(s)
        }

        zoomToFitAllElements()
        updateFocusFollowsCenter()
    }

    private func zoomToFitAllElements() {
        let frames = terminalManager.windows.map(\.frame) + annotations.map(\.frame)
        guard let first = frames.first else { return }
        let worldBounds = frames.dropFirst().reduce(first) { $0.union($1) }
        var vp = Viewport()
        vp.zoomToFit(worldBounds: worldBounds, screenSize: canvasView.bounds.size)
        canvasView.setViewport(vp)
    }

    func restoreAnnotation(_ s: AnnotationSnapshot) {
        let frame = CGRect(x: s.x, y: s.y, width: s.width, height: s.height)
        switch s.kind {
        case .text:
            let av = TextAnnotationView(at: frame.origin, text: s.content ?? "")
            av.frame = frame
            av.textColor = currentTheme.annotationColor
            av.annotationFont = currentTheme.annotationFont
            addAnnotation(av)

        case .stickyNote:
            let color = StickyNoteView.NoteColor(rawValue: s.colorName ?? "yellow") ?? .yellow
            let av = StickyNoteView(at: frame.origin, color: color, text: s.content ?? "")
            av.frame = frame
            av.themeForeground = currentTheme.stickyForeground
            av.themeBackground = currentTheme.stickyBackground
            addAnnotation(av)

        case .arrow:
            guard let pts = s.points, pts.count >= 2 else { return }
            let av = ArrowAnnotationView(start: CGPoint(x: pts[0].x, y: pts[0].y),
                                         end:   CGPoint(x: pts[1].x, y: pts[1].y))
            av.strokeColor = currentTheme.annotationColor
            addAnnotation(av)

        case .freehand:
            guard let pts = s.points else { return }
            let av = FreehandAnnotationView(at: CGPoint(x: s.x, y: s.y))
            av.loadWorldPoints(pts.map { CGPoint(x: $0.x, y: $0.y) })
            av.strokeWidth = s.lineWidth ?? 2
            av.strokeColor = currentTheme.annotationColor
            addAnnotation(av)

        case .image:
            guard let path = s.imagePath else { return }
            // Restrict image loads to the app's own Images directory to prevent
            // a tampered workspace.json from reading arbitrary files via path traversal.
            let allowedPrefix = WorkspaceStore.shared.imagesDirectory.path
            guard path.hasPrefix(allowedPrefix + "/") || path == allowedPrefix else { return }
            guard let image = NSImage(contentsOfFile: path) else { return }
            let av = ImageAnnotationView(at: frame.origin, image: image)
            av.frame = frame
            addAnnotation(av)
        }
    }

    private func updateMinimap() {
        minimapView.update(viewport: canvasView.viewport, windows: terminalManager.windows,
                           annotations: annotations, focusedWindow: canvasView.activeTerminal)
    }

    private func updateFocusFollowsCenter() {
        guard toolPalette.focusFollowsCenter else { return }
        let screenCenter = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
        let worldCenter = canvasView.viewport.screenToWorld(screenCenter)
        guard let closest = terminalManager.windows.min(by: {
            let da = hypot($0.frame.midX - worldCenter.x, $0.frame.midY - worldCenter.y)
            let db = hypot($1.frame.midX - worldCenter.x, $1.frame.midY - worldCenter.y)
            return da < db
        }) else { return }
        guard closest !== canvasView.activeTerminal else { return }
        canvasView.activateTerminal(closest)
        closest.focusTerminal()
    }

    private func scheduleSave() {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.saveWorkspace() }
        }
    }

    @objc func saveWorkspace() {
        let windowSnapshots = terminalManager.windows.map { w -> WorkspaceSnapshot.WindowSnapshot in
            WorkspaceSnapshot.WindowSnapshot(
                id: w.id,
                x: w.frame.origin.x,
                y: w.frame.origin.y,
                width: w.frame.width,
                height: w.frame.height,
                shell: w.shell,
                cwd: w.currentCwd,
                title: w.currentTitle,
                scrollback: w.extractScrollbackText()
            )
        }
        let annotationSnapshots = annotations.compactMap { $0.toSnapshot() }
        let vp = canvasView.viewport
        let snapshot = WorkspaceSnapshot(
            viewport: WorkspaceSnapshot.ViewportState(panX: vp.panX, panY: vp.panY, zoom: vp.zoom),
            windows: windowSnapshots,
            annotations: annotationSnapshots
        )
        WorkspaceStore.shared.save(snapshot)
    }

    // MARK: - View menu actions

    // MARK: - Window menu actions

    /// Close the currently active terminal. No-op if none is focused.
    @objc func closeActiveTerminal() {
        guard let tw = canvasView.activeTerminal else { return }
        removeTerminal(tw)
    }

    @objc func focusTerminalLeft()  { focusNearest(.left)  }
    @objc func focusTerminalRight() { focusNearest(.right) }
    @objc func focusTerminalUp()    { focusNearest(.up)    }
    @objc func focusTerminalDown()  { focusNearest(.down)  }

    enum FocusDirection {
        case left, right, up, down

        func contains(_ candidate: CGPoint, relativeTo origin: CGPoint) -> Bool {
            let dx = candidate.x - origin.x
            let dy = candidate.y - origin.y
            switch self {
            case .left:  return dx < 0 && abs(dy) < abs(dx)
            case .right: return dx > 0 && abs(dy) < abs(dx)
            case .up:    return dy < 0 && abs(dx) < abs(dy)
            case .down:  return dy > 0 && abs(dx) < abs(dy)
            }
        }

    }

    private func focusNearest(_ direction: FocusDirection) {
        guard !terminalManager.windows.isEmpty else { return }
        let current = canvasView.activeTerminal
        let origin = current?.frame.center ?? canvasView.viewport.screenToWorld(
            CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY))
        let candidates = terminalManager.windows.filter {
            $0 !== current && direction.contains($0.frame.center, relativeTo: origin)
        }
        guard let nearest = candidates.min(by: {
            let da = hypot($0.frame.center.x - origin.x, $0.frame.center.y - origin.y)
            let db = hypot($1.frame.center.x - origin.x, $1.frame.center.y - origin.y)
            return da < db
        }) else { return }
        snapViewportToTerminal(nearest)
    }

    private func snapViewportToTerminal(_ tw: TerminalWindowView) {
        canvasView.activateTerminal(tw)
        tw.focusTerminal()
        let center = CGPoint(x: tw.frame.midX, y: tw.frame.midY)
        var vp = canvasView.viewport
        vp.panX = -center.x * vp.zoom + canvasView.bounds.width / 2
        vp.panY = -center.y * vp.zoom + canvasView.bounds.height / 2
        canvasView.setViewport(vp)
    }

    @objc func resetZoom() {
        let center = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
        var vp = canvasView.viewport
        vp.zoomAround(screenAnchor: center, factor: 1.0 / vp.zoom)
        canvasView.setViewport(vp)
    }

    @objc func fitAll() {
        let windows = terminalManager.windows
        guard !windows.isEmpty else { return }

        let union = windows.map(\.frame).reduce(windows[0].frame) { $0.union($1) }
        let padding: CGFloat = 80
        let paddedUnion = union.insetBy(dx: -padding, dy: -padding)

        let scaleX = canvasView.bounds.width / paddedUnion.width
        let scaleY = canvasView.bounds.height / paddedUnion.height
        let zoom = min(scaleX, scaleY).clamped(to: Viewport.zoomMin...Viewport.zoomMax)

        var vp = Viewport()
        vp.zoom = zoom
        vp.panX = -paddedUnion.minX * zoom + (canvasView.bounds.width - paddedUnion.width * zoom) / 2
        vp.panY = -paddedUnion.minY * zoom + (canvasView.bounds.height - paddedUnion.height * zoom) / 2
        canvasView.setViewport(vp)
    }
}

// MARK: - AppleScript / Scripting API

extension CanvasViewController {

    /// Pan and activate the first terminal whose working directory matches `path`.
    /// - Returns: `true` if a terminal was found and focused.
    @discardableResult
    func focusTerminalInDirectory(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path, isDirectory: true).standardized
        guard let match = terminalManager.windows.first(where: {
            URL(fileURLWithPath: $0.currentCwd, isDirectory: true).standardized == target
        }) else { return false }
        snapViewportToTerminal(match)
        return true
    }

    /// Spawn a new terminal, optionally at `path`, centered in the current viewport.
    func openTerminalViaScript(at path: String?) {
        let center = canvasView.viewport.screenToWorld(
            CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY))
        spawnTerminal(at: center, cwd: path)
    }

    /// Working directory of the active terminal, or empty string if none is focused.
    var activeTerminalWorkingDirectory: String {
        canvasView.activeTerminal?.currentCwd ?? ""
    }

    /// Number of open terminals on the canvas.
    var terminalCount: Int { terminalManager.windows.count }
}

// MARK: - Undo / Redo

extension CanvasViewController {
    // Explicit overrides ensure the canvas undo manager is a guaranteed stop in the
    // responder chain — without these, Cmd+Z can get lost if a terminal is focused.
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }
}

// MARK: - Menu validation

extension CanvasViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            return undoManager?.canUndo ?? false
        }
        if menuItem.action == #selector(redo(_:)) {
            return undoManager?.canRedo ?? false
        }
        if menuItem.action == #selector(selectTheme(_:)) {
            let themes = Theme.allThemes
            guard menuItem.tag < themes.count else { return true }
            menuItem.state = (themes[menuItem.tag].id == currentTheme.id) ? .on : .off
        }
        if menuItem.action == #selector(toggleBroadcast) {
            menuItem.state = broadcastMode ? .on : .off
        }
        if menuItem.action == #selector(toggleSnapping) {
            menuItem.state = toolPalette.snappingEnabled ? .on : .off
        }
        return true
    }
}
