import AppKit
import CoreVideo
import os

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

    // MARK: - Subviews

    private let canvasView = CanvasView()
    private let minimapView = MinimapView()
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
    // nonisolated(unsafe): CVDisplayLink must be stopped in deinit (nonisolated context).
    // Written once on the main thread during setup; only read in deinit after all
    // references are dropped, so there is no concurrent access.
    nonisolated(unsafe) private var fpsDisplayLink: CVDisplayLink?
    /// Guards cross-thread access between the main actor (writer) and the CVDisplayLink
    /// callback thread (reader/writer). Same pattern as MinimapView.renderFlags.
    private let pendingViewportUpdate = OSAllocatedUnfairLock(initialState: false)
    private var fpsFrameTimes: [CFTimeInterval] = []

    // MARK: - State

    private var saveDebounceTimer: Timer?
    private var workspaceRestored = false
    var currentTheme: Theme = {
        let id = UserDefaults.standard.string(forKey: "themeID") ?? Theme.dark.id
        return Theme.allThemes.first { $0.id == id } ?? .dark
    }()

    private var themeEditorWindow: NSWindow?
    private var deleteSelectionStart: CGPoint?

    // MARK: - Controllers

    private var terminalController: TerminalController!
    private var annotationController: AnnotationController!

    // MARK: - Multi-selection

    var selectedTerminalIDs: Set<UUID> = []
    var selectedAnnotationIDs: Set<UUID> = []

    /// Peer frames captured at the start of a group drag for undo registration.
    private var dragPeerTermSnapshots: [(TerminalWindowView, CGRect)] = []
    private var dragPeerAnnotSnapshots: [(AnnotationView, CGRect)] = []

    // MARK: - Lifecycle

    deinit {
        if let link = fpsDisplayLink { CVDisplayLinkStop(link) }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        terminalController = TerminalController(
            canvasView: canvasView,
            undoManager: { [weak self] in self?.undoManager },
            theme: { [weak self] in self?.currentTheme ?? .dark },
            snap: { [weak self] proposed, tw, edge in
                guard let self else { return proposed }
                return self.snapPosition(proposed, excludingTerminal: tw, edge: edge)
            },
            clearSnap: { [weak self] in self?.snapOverlay.guides = [] }
        )
        terminalController.onChange = { [weak self] in
            self?.updateMinimap()
            self?.updateSelectionRings()
            self?.scheduleSave()
        }
        terminalController.onTerminalRemoved = { [weak self] tw in
            self?.selectedTerminalIDs.remove(tw.id)
        }
        terminalController.onDragDelta = { [weak self] tw, dx, dy in
            self?.moveSelectionPeers(of: tw, dx: dx, dy: dy)
        }
        terminalController.onDragBegan = { [weak self] tw in
            guard let self else { return }
            dragPeerTermSnapshots = terminalController.windows
                .filter { selectedTerminalIDs.contains($0.id) && $0 !== tw }
                .map { ($0, $0.frame) }
            dragPeerAnnotSnapshots = annotationController.annotations
                .filter { selectedAnnotationIDs.contains($0.annotationID) }
                .map { ($0, $0.frame) }
        }
        terminalController.onMoveEnded = { [weak self] _ in
            self?.registerPeerUndos()
        }
        annotationController = AnnotationController(
            canvasView: canvasView,
            undoManager: { [weak self] in self?.undoManager },
            theme: { [weak self] in self?.currentTheme ?? .dark },
            snap: { [weak self] proposed, av, edge in
                guard let self else { return proposed }
                return self.snapPosition(proposed, excludingAnnotation: av, edge: edge)
            },
            clearSnap: { [weak self] in self?.snapOverlay.guides = [] }
        )
        annotationController.onChange = { [weak self] in
            self?.updateMinimap()
            self?.updateSelectionRings()
            self?.scheduleSave()
        }
        annotationController.onRemoved = { [weak self] av in
            self?.selectedAnnotationIDs.remove(av.annotationID)
        }
        annotationController.onDragDelta = { [weak self] av, dx, dy in
            self?.moveSelectionPeers(of: av, dx: dx, dy: dy)
        }
        annotationController.onDragBegan = { [weak self] av in
            guard let self else { return }
            dragPeerTermSnapshots = terminalController.windows
                .filter { selectedTerminalIDs.contains($0.id) }
                .map { ($0, $0.frame) }
            dragPeerAnnotSnapshots = annotationController.annotations
                .filter { selectedAnnotationIDs.contains($0.annotationID) && $0 !== av }
                .map { ($0, $0.frame) }
        }
        annotationController.onMoveEnded = { [weak self] _ in
            self?.registerPeerUndos()
        }
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
            self?.terminalController.spawn(at: worldPt)
        }

        canvasView.onBackgroundClick = { [weak self] _ in
            self?.clearSelection()
        }

        canvasView.onTerminalPressed = { [weak self] tw, isShift in
            guard let self else { return }
            if isShift {
                toggleSelection(tw)
            } else if !selectedTerminalIDs.contains(tw.id) {
                clearSelection()
            }
            updateMinimap()
        }

        canvasView.onAnnotationPressed = { [weak self] av, isShift in
            guard let self else { return }
            if isShift {
                toggleSelection(av)
            } else if !selectedAnnotationIDs.contains(av.annotationID) {
                clearSelection()
            }
        }

        canvasView.onViewportChanged = { [weak self] _ in
            guard let self else { return }
            updateMinimap()
            updateZoomLabel()
            scheduleSave()
            pendingViewportUpdate.withLock { $0 = true }
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
        canvasView.onRubberBandSelect = { [weak self] rect, additive in
            guard let self else { return }
            if !additive { clearSelection() }
            for tw in terminalController.windows where rect.intersects(tw.frame) { toggleSelection(tw) }
            for av in annotationController.annotations where rect.intersects(av.frame) { toggleSelection(av) }
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
            let didUpdate = vc.pendingViewportUpdate.withLock { state -> Bool in
                guard state else { return false }
                state = false
                return true
            }
            guard didUpdate else {
                // Nothing rendered — if the last recorded frame is > 1s old, show 0.
                DispatchQueue.main.async {
                    vc.fpsFrameTimes.removeAll { $0 < t - 1.0 }
                    if vc.fpsFrameTimes.isEmpty {
                        vc.fpsLabel.stringValue = " 0 fps "
                    }
                }
                return kCVReturnSuccess
            }
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

    // MARK: - Terminal spawning (delegated to TerminalController)

    @objc func spawnTerminalAtCenter() { terminalController.spawnAtCenter() }

    // MARK: - Tool handling

    private func handleToolBegan(_ tool: CanvasTool, at worldPt: CGPoint) {
        switch tool {
        case .pointer: break
        case .delete:
            deleteSelectionStart = worldPt
            canvasView.setSelectionRect(CGRect(origin: worldPt, size: .zero))
        case .terminal:
            terminalController.spawn(at: worldPt)
            setTool(.pointer)
        default:
            annotationController.toolBegan(tool, at: worldPt)
        }
    }

    private func handleToolMoved(_ tool: CanvasTool, at worldPt: CGPoint) {
        switch tool {
        case .delete:
            guard let start = deleteSelectionStart else { return }
            canvasView.setSelectionRect(selectionRect(from: start, to: worldPt))
        default:
            annotationController.toolMoved(tool, at: worldPt)
        }
    }

    private func handleToolEnded(_ tool: CanvasTool, at worldPt: CGPoint) {
        if tool == .delete {
            canvasView.setSelectionRect(nil)
            guard let start = deleteSelectionStart else { return }
            deleteSelectionStart = nil
            let rect = selectionRect(from: start, to: worldPt)
            if rect.width < 5 && rect.height < 5 {
                if let tw = terminalController.windows.first(where: { $0.frame.contains(worldPt) }) {
                    tw.onClose?()
                } else if let av = annotationController.annotationAtPoint(worldPt) {
                    annotationController.remove(av)
                }
            } else {
                for tw in terminalController.windows where rect.intersects(tw.frame) { tw.onClose?() }
                for av in annotationController.annotationsIntersecting(rect) { annotationController.remove(av) }
            }
        } else {
            annotationController.toolEnded(tool, at: worldPt)
        }
        scheduleSave()
    }

    private func selectionRect(from a: CGPoint, to b: CGPoint) -> CGRect { .between(a, b) }

    // MARK: - Multi-selection helpers

    func toggleSelection(_ tw: TerminalWindowView) {
        selectedTerminalIDs.formSymmetricDifference([tw.id])
        updateSelectionRings()
    }

    func toggleSelection(_ av: AnnotationView) {
        selectedAnnotationIDs.formSymmetricDifference([av.annotationID])
        updateSelectionRings()
    }

    func clearSelection() {
        guard !selectedTerminalIDs.isEmpty || !selectedAnnotationIDs.isEmpty else { return }
        selectedTerminalIDs.removeAll()
        selectedAnnotationIDs.removeAll()
        updateSelectionRings()
    }

    private func updateSelectionRings() {
        var frames: [CGRect] = []
        for tw in terminalController.windows where selectedTerminalIDs.contains(tw.id) {
            frames.append(tw.frame)
        }
        for av in annotationController.annotations where selectedAnnotationIDs.contains(av.annotationID) {
            frames.append(av.frame)
        }
        canvasView.updateSelectionRings(frames)
    }

    /// Registers undo for all peer items captured at drag start, then clears snapshots.
    /// Called in the same mouseUp event as the source's undo registration so groupsByEvent
    /// automatically bundles source + peers into one Cmd+Z action.
    private func registerPeerUndos() {
        defer {
            dragPeerTermSnapshots.removeAll()
            dragPeerAnnotSnapshots.removeAll()
        }
        guard !dragPeerTermSnapshots.isEmpty || !dragPeerAnnotSnapshots.isEmpty else { return }
        undoManager?.setActionName("Move")
        for (tw, startFrame) in dragPeerTermSnapshots {
            let sf = startFrame
            undoManager?.registerUndo(withTarget: terminalController) { [weak tw] tc in
                guard let tw else { return }
                tc.move(tw, to: sf)
            }
        }
        for (av, startFrame) in dragPeerAnnotSnapshots {
            let sf = startFrame
            undoManager?.registerUndo(withTarget: annotationController) { [weak av] ac in
                guard let av else { return }
                ac.move(av, to: sf)
            }
        }
    }

    /// Move all selected items that are not `source` by the given world-space delta.
    /// Callers handle the subsequent minimap + ring refresh via annotationController.onChange.
    func moveSelectionPeers(of source: AnyObject?, dx: CGFloat, dy: CGFloat) {
        guard !selectedTerminalIDs.isEmpty || !selectedAnnotationIDs.isEmpty else { return }
        for tw in terminalController.windows
            where selectedTerminalIDs.contains(tw.id) && tw !== source {
            tw.frame.origin.x += dx
            tw.frame.origin.y += dy
        }
        for av in annotationController.annotations
            where selectedAnnotationIDs.contains(av.annotationID) && av !== source {
            av.frame.origin.x += dx
            av.frame.origin.y += dy
        }
    }

    // MARK: - Annotation forwarders (keep call sites in tests and undo blocks stable)

    var annotations: [AnnotationView]                             { annotationController.annotations }
    func addAnnotation(_ av: AnnotationView)                      { annotationController.add(av) }
    func removeAnnotation(_ av: AnnotationView)                   { annotationController.remove(av) }
    func moveAnnotation(_ av: AnnotationView, to f: CGRect)       { annotationController.move(av, to: f) }

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
        let boxAnnotations = annotationController.annotations.filter {
            $0 !== excludingAnnotation
            && !selectedAnnotationIDs.contains($0.annotationID)
            && ($0 is StickyNoteView || $0 is TextAnnotationView || $0 is ImageAnnotationView)
        }
        return terminalController.windows
            .filter { $0 !== excludingTerminal && !selectedTerminalIDs.contains($0.id) }
            .map(\.frame)
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
        terminalController.applyTheme(theme)
        annotationController.applyTheme(theme)
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
        // NSColorPanel defaults to the lower-left corner of the screen if it has never been
        // positioned by the user. Center it so it appears near the theme editor.
        if !NSColorPanel.shared.isVisible { NSColorPanel.shared.center() }

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.themeEditorWindow = nil }
        }
        themeEditorWindow = panel
    }

    @objc func openTerminalSettings() { terminalController.openTerminalSettings() }

    // MARK: - Broadcast

    @objc func toggleBroadcast() { terminalController.toggleBroadcast() }

    // MARK: - Workspace persistence

    private func restoreWorkspace() {
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }

        guard let snapshot = WorkspaceStore.shared.load() else {
            // First launch: spawn one terminal in the center
            spawnTerminalAtCenter()
            return
        }

        terminalController.restore(snapshot.windows)

        for s in snapshot.annotations {
            restoreAnnotation(s)
        }

        zoomToFitAllElements()
        updateFocusFollowsCenter()
    }

    private func zoomToFitAllElements() {
        let frames = terminalController.windows.map(\.frame) + annotationController.annotations.map(\.frame)
        guard let first = frames.first else { return }
        let worldBounds = frames.dropFirst().reduce(first) { $0.union($1) }
        var vp = Viewport()
        vp.zoomToFit(worldBounds: worldBounds, screenSize: canvasView.bounds.size)
        canvasView.setViewport(vp)
    }

    func restoreAnnotation(_ s: AnnotationSnapshot) {
        annotationController.restore(s)
    }

    private func updateMinimap() {
        minimapView.update(viewport: canvasView.viewport, windows: canvasView.terminalsInZOrder,
                           annotations: annotationController.annotations,
                           focusedWindow: canvasView.activeTerminal)
    }

    private func updateFocusFollowsCenter() {
        guard toolPalette.focusFollowsCenter else { return }
        let screenCenter = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
        let worldCenter = canvasView.viewport.screenToWorld(screenCenter)
        guard let closest = terminalController.windows.min(by: {
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
        let vp = canvasView.viewport
        let snapshot = WorkspaceSnapshot(
            viewport: WorkspaceSnapshot.ViewportState(panX: vp.panX, panY: vp.panY, zoom: vp.zoom),
            windows: terminalController.makeSnapshots(),
            annotations: annotationController.annotations.compactMap { $0.toSnapshot() }
        )
        WorkspaceStore.shared.save(snapshot)
    }

    // MARK: - View menu actions

    // MARK: - Window menu actions

    @objc func clearActiveTerminalScrollback() { canvasView.activeTerminal?.clearScrollback() }
    @objc func closeActiveTerminal() { terminalController.closeActive() }
    @objc func focusTerminalLeft()   { terminalController.focusNearest(.left)  }
    @objc func focusTerminalRight()  { terminalController.focusNearest(.right) }
    @objc func focusTerminalUp()     { terminalController.focusNearest(.up)    }
    @objc func focusTerminalDown()   { terminalController.focusNearest(.down)  }

    @objc func resetZoom() {
        let center = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
        var vp = canvasView.viewport
        vp.zoomAround(screenAnchor: center, factor: 1.0 / vp.zoom)
        canvasView.setViewport(vp)
    }

    @objc func fitAll() {
        let windows = terminalController.windows
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

    /// Pan to and activate the first terminal whose working directory matches `path`.
    @discardableResult
    func focusTerminalInDirectory(_ path: String) -> Bool {
        guard terminalController.focusTerminalInDirectory(path) else { return false }
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func openTerminalViaScript(at path: String?) { terminalController.openViaScript(at: path) }
    var activeTerminalWorkingDirectory: String    { terminalController.activeWorkingDirectory }
    var terminalCount: Int                        { terminalController.count }
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
            menuItem.state = terminalController.broadcastMode ? .on : .off
        }
        if menuItem.action == #selector(toggleSnapping) {
            menuItem.state = toolPalette.snappingEnabled ? .on : .off
        }
        if menuItem.action == #selector(toggleFPSOverlay) {
            menuItem.state = fpsLabel.isHidden ? .off : .on
        }
        return true
    }
}
