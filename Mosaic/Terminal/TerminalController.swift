import AppKit

/// Owns all terminal windows on the canvas and drives terminal lifecycle.
/// Created and held by CanvasViewController; all methods run on the main actor.
@MainActor
final class TerminalController {

    static var defaultShell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    /// Cap on terminals restored from a snapshot. A tampered or corrupt
    /// workspace.json with thousands of WindowSnapshot entries would otherwise
    /// fork-bomb the app at launch.
    static let maxRestoredWindows = 64

    /// Map a requested shell path to the executable we'll actually spawn. Returns
    /// the canonicalised path if it appears in `allowedShells`; otherwise falls
    /// back to `defaultShell`. Pulled out as a static function so we can
    /// unit-test the allowlist without driving the spawn path.
    static func resolveShell(_ requested: String) -> String {
        let canonical = URL(fileURLWithPath: requested).resolvingSymlinksInPath().standardizedFileURL.path
        return allowedShells.contains(canonical) ? canonical : defaultShell
    }

    /// Return true when the binary at `path` is owned by root (uid 0) and not
    /// group- or world-writable. Defends against a tampered /etc/shells entry on a
    /// SIP-disabled system pointing to a user-writable payload.
    private static func isShellBinaryTrustworthy(atPath path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let ownerID = attrs[.ownerAccountID] as? Int,
              let perms   = attrs[.posixPermissions] as? Int
        else { return false }
        // Root-owned and not group-writable (0o020) or world-writable (0o002).
        return ownerID == 0 && (perms & 0o022) == 0
    }

    /// Shell paths allowed when restoring from a snapshot. Built from /etc/shells
    /// plus the current $SHELL and the built-in default; cached at first read.
    static let allowedShells: Set<String> = {
        var set: Set<String> = []
        if let data = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
            for raw in data.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty && !line.hasPrefix("#")
                   && Self.isShellBinaryTrustworthy(atPath: line) {
                    set.insert(
                        URL(fileURLWithPath: line).resolvingSymlinksInPath().standardizedFileURL.path)
                }
            }
        }
        if let sh = ProcessInfo.processInfo.environment["SHELL"] {
            set.insert(URL(fileURLWithPath: sh).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        set.insert("/bin/zsh"); set.insert("/bin/bash"); set.insert("/bin/sh")
        return set
    }()

    // MARK: - Injected dependencies

    private(set) weak var canvasView: CanvasView?
    private var undoManager: UndoManager? { undoProvider() }
    private let undoProvider: () -> UndoManager?
    private let theme: () -> Theme
    private let snap: (CGRect, TerminalWindowView?, ResizeHandleView.Edge?) -> CGRect
    private let clearSnap: () -> Void

    // MARK: - Callbacks out

    /// Called after any mutation (spawn / move / remove). Wire to minimap + rings + save.
    var onChange: (() -> Void)?
    /// Called when a terminal is removed so the caller can drop it from selection state.
    var onTerminalRemoved: ((TerminalWindowView) -> Void)?
    /// Called each drag tick with (view, worldDX, worldDY) for group-move coordination.
    var onDragDelta: ((TerminalWindowView, CGFloat, CGFloat) -> Void)?
    /// Called when a terminal's title-bar drag begins; used to capture peer frames.
    var onDragBegan: ((TerminalWindowView) -> Void)?
    /// Called after a terminal's undo action is registered; used to register group-move peer undos.
    var onMoveEnded: ((TerminalWindowView) -> Void)?
    /// Called when a terminal emits BEL (e.g. Claude Code task completion).
    var onBell: ((TerminalWindowView) -> Void)?
    /// Called on OSC 9/777 notification with (terminal, title, body).
    var onNotification: ((TerminalWindowView, String, String) -> Void)?

    // MARK: - State

    private let manager = TerminalManager()
    private(set) var broadcastMode = false
    private var terminalSettingsWindow: NSWindow?

    var windows: [TerminalWindowView] { manager.windows }

    // MARK: - Init

    init(canvasView: CanvasView,
         undoManager: @escaping () -> UndoManager?,
         theme: @escaping () -> Theme,
         snap: @escaping (CGRect, TerminalWindowView?, ResizeHandleView.Edge?) -> CGRect,
         clearSnap: @escaping () -> Void) {
        self.canvasView   = canvasView
        self.undoProvider = undoManager
        self.theme        = theme
        self.snap         = snap
        self.clearSnap    = clearSnap
    }

    // MARK: - Spawn

    func spawnAtCenter() {
        guard let cv = canvasView else { return }
        let center = cv.viewport.screenToWorld(CGPoint(x: cv.bounds.midX, y: cv.bounds.midY))
        spawn(at: center)
    }

    func spawn(at worldPt: CGPoint,
               shell: String = TerminalController.defaultShell,
               cwd: String? = nil) {
        let size = CGSize(width: 600, height: 400)
        let origin = CGPoint(x: worldPt.x - size.width / 2, y: worldPt.y - size.height / 2)
        spawnWithFrame(CGRect(origin: origin, size: size), shell: shell, cwd: cwd)
    }

    func spawnWithFrame(_ frame: CGRect,
                        shell: String = TerminalController.defaultShell,
                        cwd: String? = nil,
                        scrollback: String? = nil) {
        guard let cv = canvasView else { return }

        // Restrict shell paths to an allowlist derived from /etc/shells (+ $SHELL +
        // built-in defaults). isExecutableFile alone accepted any +x file on disk,
        // so a tampered workspace.json specifying /tmp/payload would have spawned
        // attacker code on every launch.
        let resolvedShell = Self.resolveShell(shell)

        // Reject cwds containing NUL (would truncate at the syscall boundary) and
        // those that don't exist as directories.
        let resolvedCwd: String? = {
            guard let c = cwd, !c.contains("\0") else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: c, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return c
        }()

        let tw = manager.spawn(frame: frame, shell: resolvedShell, cwd: resolvedCwd)
        tw.restoredScrollback = scrollback
        tw.canvasView = cv
        tw.theme = theme()

        tw.onClose = { [weak self, weak tw] in
            guard let self, let tw else { return }
            remove(tw)
        }

        tw.onMoved = { [weak self] in
            self?.onChange?()
        }

        tw.onDragDelta = { [weak self, weak tw] dx, dy in
            guard let self, let tw else { return }
            onDragDelta?(tw, dx, dy)
        }

        tw.onDragBegan = { [weak self, weak tw] in
            guard let self, let tw else { return }
            onDragBegan?(tw)
        }

        tw.onMoveEnded = { [weak self, weak tw] fromFrame, _ in
            guard let self, let tw else { return }
            undoManager?.setActionName("Move Terminal")
            undoManager?.registerUndo(withTarget: self) { @MainActor [weak tw] tc in
                guard let tw else { return }
                tc.move(tw, to: fromFrame)
            }
            onMoveEnded?(tw)
        }

        tw.snapFrame = { [weak self, weak tw] proposed, edge in
            guard let self else { return proposed }
            return snap(proposed, tw, edge)
        }

        tw.clearSnapGuides = { [weak self] in self?.clearSnap() }

        tw.onBroadcastKey = { [weak self] data in
            self?.broadcastKey(data, excluding: tw)
        }

        tw.onBell = { [weak self, weak tw] in
            guard let self, let tw else { return }
            onBell?(tw)
        }

        tw.onNotification = { [weak self, weak tw] title, body in
            guard let self, let tw else { return }
            onNotification?(tw, title, body)
        }


        cv.addTerminal(tw)
        cv.activateTerminal(tw)
        tw.focusTerminal()

        undoManager?.setActionName("New Terminal")
        undoManager?.registerUndo(withTarget: self) { @MainActor [weak tw] tc in
            guard let tw else { return }
            tc.remove(tw)
        }

        onChange?()
    }

    // MARK: - Remove / Move

    func remove(_ tw: TerminalWindowView) {
        let savedFrame = tw.frame
        let savedShell = tw.shell
        let savedCwd   = tw.currentCwd
        undoManager?.setActionName("Close Terminal")
        undoManager?.registerUndo(withTarget: self) { @MainActor tc in
            tc.spawnWithFrame(savedFrame, shell: savedShell, cwd: savedCwd)
        }
        // Nil out onClose before kill: terminate() sends EOF causing the shell to exit,
        // which fires processTerminated → onClose → remove a second time,
        // registering a duplicate undo entry and producing two terminals on undo.
        tw.onClose = nil
        manager.kill(tw)
        onTerminalRemoved?(tw)
        onChange?()
    }

    func move(_ tw: TerminalWindowView, to newFrame: CGRect) {
        let oldFrame = tw.frame
        undoManager?.setActionName("Move Terminal")
        undoManager?.registerUndo(withTarget: self) { @MainActor [weak tw] tc in
            guard let tw else { return }
            tc.move(tw, to: oldFrame)
        }
        tw.frame = newFrame
        onChange?()
    }

    // MARK: - Theme / Settings

    func applyTheme(_ theme: Theme) {
        manager.windows.forEach { $0.applyTheme(theme) }
    }

    func applyTerminalSettings(_ settings: TerminalSettings) {
        manager.windows.forEach { $0.applyTerminalSettings(settings) }
    }

    @objc func openTerminalSettings() {
        if let existing = terminalSettingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let vc = TerminalSettingsViewController()
        vc.onApply = { [weak self] settings in
            self?.applyTerminalSettings(settings)
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

    func toggleBroadcast() {
        if !broadcastMode {
            // Require explicit confirmation before enabling broadcast mode.
            // Once active, every keystroke is silently mirrored to all open terminals
            // with no further prompt — a mistaken activation can have wide impact.
            let alert = NSAlert()
            alert.messageText = "Enable Broadcast Mode?"
            alert.informativeText = "All keystrokes will be mirrored to every open terminal until you disable broadcast mode."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Enable Broadcast")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        broadcastMode.toggle()
        canvasView?.broadcastModeActive = broadcastMode
        manager.windows.forEach { $0.setBroadcastHighlight(broadcastMode) }
        if broadcastMode, let first = manager.windows.first {
            first.focusTerminal()
        }
    }

    private func broadcastKey(_ data: Data, excluding source: TerminalWindowView) {
        guard broadcastMode else { return }
        // Cap per-broadcast payload — a pasted megabyte or runaway script in the
        // source terminal would otherwise fan out to every peer at once.
        guard data.count <= 64 * 1024 else { return }
        manager.windows.filter { $0 !== source && $0.shellReady }.forEach { $0.sendInput(data) }
    }

    // MARK: - Navigation

    enum FocusDirection {
        case left, right, up, down

        func contains(_ candidate: CGPoint, relativeTo origin: CGPoint) -> Bool {
            let dx = candidate.x - origin.x
            let dy = candidate.y - origin.y
            switch self {
            case .left:  return dx < 0 && abs(dy) <= abs(dx)
            case .right: return dx > 0 && abs(dy) <= abs(dx)
            case .up:    return dy < 0 && abs(dx) < abs(dy)
            case .down:  return dy > 0 && abs(dx) < abs(dy)
            }
        }
    }

    func closeActive() {
        guard let tw = canvasView?.activeTerminal else { return }
        remove(tw)
    }

    func focusNearest(_ direction: FocusDirection) {
        guard let cv = canvasView, !manager.windows.isEmpty else { return }
        let current = cv.activeTerminal
        let origin = current?.frame.center ?? cv.viewport.screenToWorld(
            CGPoint(x: cv.bounds.midX, y: cv.bounds.midY))
        let candidates = manager.windows.filter {
            $0 !== current && direction.contains($0.frame.center, relativeTo: origin)
        }
        guard let nearest = candidates.min(by: {
            hypot($0.frame.center.x - origin.x, $0.frame.center.y - origin.y) <
            hypot($1.frame.center.x - origin.x, $1.frame.center.y - origin.y)
        }) else { return }
        snapViewportToTerminal(nearest)
    }

    func snapViewportToTerminal(_ tw: TerminalWindowView) {
        guard let cv = canvasView else { return }
        cv.activateTerminal(tw)
        tw.focusTerminal()
        let center = CGPoint(x: tw.frame.midX, y: tw.frame.midY)
        var vp = cv.viewport
        vp.panX = -center.x * vp.zoom + cv.bounds.width / 2
        vp.panY = -center.y * vp.zoom + cv.bounds.height / 2
        cv.setViewport(vp)
    }

    // MARK: - Snapshot / Restore

    func makeSnapshots() -> [WorkspaceSnapshot.WindowSnapshot] {
        manager.windows.map { w in
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
    }

    func restore(_ snapshots: [WorkspaceSnapshot.WindowSnapshot]) {
        if snapshots.count > Self.maxRestoredWindows {
            NSLog("[TerminalController] snapshot has %d windows; capping at %d",
                  snapshots.count, Self.maxRestoredWindows)
        }
        for w in snapshots.prefix(Self.maxRestoredWindows) {
            spawnWithFrame(
                CGRect(x: w.x, y: w.y, width: w.width, height: w.height),
                cwd: w.cwd,
                scrollback: w.scrollback
            )
        }
    }

    // MARK: - AppleScript helpers

    /// Pan to and activate the first terminal whose working directory matches `path`.
    @discardableResult
    func focusTerminalInDirectory(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path, isDirectory: true).standardized
        guard let match = manager.windows.first(where: {
            URL(fileURLWithPath: $0.currentCwd, isDirectory: true).standardized == target
        }) else { return false }
        snapViewportToTerminal(match)
        return true
    }

    /// Spawn a new terminal at `path` (or canvas center), for AppleScript use.
    func openViaScript(at path: String?) {
        guard let cv = canvasView else { return }
        let center = cv.viewport.screenToWorld(CGPoint(x: cv.bounds.midX, y: cv.bounds.midY))
        spawn(at: center, cwd: path)
    }

    var activeWorkingDirectory: String { canvasView?.activeTerminal?.currentCwd ?? "" }
    var count: Int { manager.windows.count }
}
