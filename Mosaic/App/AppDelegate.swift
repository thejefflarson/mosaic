import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var mainWindowController: NSWindowController?
    private var themeMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        openMainWindow()
        NotificationCenter.default.addObserver(
            forName: .themesDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildThemeMenuItems() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkspaceStore.shared.flushSynchronously()
    }

    private func openMainWindow() {
        let vc = CanvasViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mosaic"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = vc
        window.center()
        window.isRestorable = false
        window.makeKeyAndOrderFront(nil)

        let wc = NSWindowController(window: window)
        mainWindowController = wc
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Mosaic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Terminal", action: #selector(CanvasViewController.spawnTerminalAtCenter), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Save Workspace", action: #selector(CanvasViewController.saveWorkspace), keyEquivalent: "s")

        // Edit menu — standard actions travel the responder chain automatically
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut",   action: #selector(NSText.cut(_:)),   keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",  action: #selector(NSText.copy(_:)),  keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View menu
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Reset Zoom", action: #selector(CanvasViewController.resetZoom), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Fit All Windows", action: #selector(CanvasViewController.fitAll), keyEquivalent: "f")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Snap to Alignment", action: #selector(CanvasViewController.toggleSnapping), keyEquivalent: "")
        let broadcastItem = NSMenuItem(title: "Broadcast Mode", action: #selector(CanvasViewController.toggleBroadcast), keyEquivalent: "b")
        broadcastItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(broadcastItem)
        viewMenu.addItem(withTitle: "Show FPS", action: #selector(CanvasViewController.toggleFPSOverlay), keyEquivalent: "")

        viewMenu.addItem(NSMenuItem.separator())

        viewMenu.addItem(withTitle: "Terminal Settings…",
                         action: #selector(CanvasViewController.openTerminalSettings),
                         keyEquivalent: ",")

        let editThemeItem = NSMenuItem(title: "Edit Theme…",
                                       action: #selector(CanvasViewController.openThemeEditor),
                                       keyEquivalent: "")
        viewMenu.addItem(editThemeItem)

        viewMenu.addItem(NSMenuItem.separator())
        let themeMenuItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Theme")
        menu.delegate = self
        themeMenuItem.submenu = menu
        viewMenu.addItem(themeMenuItem)
        themeMenu = menu
        rebuildThemeMenuItems()
    }

    private func rebuildThemeMenuItems() {
        guard let menu = themeMenu else { return }
        menu.removeAllItems()
        for (i, theme) in Theme.allThemes.enumerated() {
            let item = NSMenuItem(title: theme.name,
                                  action: #selector(CanvasViewController.selectTheme(_:)),
                                  keyEquivalent: "")
            item.tag = i
            menu.addItem(item)
        }
    }

    // NSMenuDelegate — rebuild items every time the menu opens so tags stay correct.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in rebuildThemeMenuItems() }
    }
}
