import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var mainWindowController: NSWindowController?
    private var themeMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        openMainWindow()
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
        window.isRestorable = true
        // center() only on first launch; setFrameAutosaveName restores saved position otherwise
        if !window.setFrameAutosaveName("MainWindow") {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)

        let wc = NSWindowController(window: window)
        mainWindowController = wc
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // ── App menu ──────────────────────────────────────────────────────────
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Mosaic",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Terminal Settings…",
                        action: #selector(CanvasViewController.openTerminalSettings),
                        keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Mosaic",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others",
                                        action: #selector(NSApplication.hideOtherApplications(_:)),
                                        keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Mosaic",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // ── File menu ─────────────────────────────────────────────────────────
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Terminal",
                         action: #selector(CanvasViewController.spawnTerminalAtCenter),
                         keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Save Workspace",
                         action: #selector(CanvasViewController.saveWorkspace),
                         keyEquivalent: "s")

        // ── Edit menu — standard actions travel the responder chain automatically
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: #selector(CanvasViewController.undo(_:)), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(CanvasViewController.redo(_:)), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // ── View menu ─────────────────────────────────────────────────────────
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Reset Zoom",
                         action: #selector(CanvasViewController.resetZoom),
                         keyEquivalent: "0")
        // "Fit All Windows" intentionally has no shortcut — Cmd+F is reserved for Find
        viewMenu.addItem(withTitle: "Fit All Windows",
                         action: #selector(CanvasViewController.fitAll),
                         keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Snap to Alignment",
                         action: #selector(CanvasViewController.toggleSnapping),
                         keyEquivalent: "")
        let broadcastItem = NSMenuItem(title: "Broadcast Mode",
                                       action: #selector(CanvasViewController.toggleBroadcast),
                                       keyEquivalent: "b")
        broadcastItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(broadcastItem)
        viewMenu.addItem(withTitle: "Show FPS",
                         action: #selector(CanvasViewController.toggleFPSOverlay),
                         keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Edit Theme…",
                         action: #selector(CanvasViewController.openThemeEditor),
                         keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())
        let themeMenuItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeSubmenu = NSMenu(title: "Theme")
        themeSubmenu.delegate = self
        themeMenuItem.submenu = themeSubmenu
        viewMenu.addItem(themeMenuItem)
        themeMenu = themeSubmenu
        rebuildThemeMenuItems()

        // ── Window menu ───────────────────────────────────────────────────────
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        windowMenu.addItem(withTitle: "Close Terminal",
                           action: #selector(CanvasViewController.closeActiveTerminal),
                           keyEquivalent: "w")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.miniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.zoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())

        for (title, sel, key) in [
            ("Focus Terminal Left",  #selector(CanvasViewController.focusTerminalLeft),  "\u{F702}"),
            ("Focus Terminal Right", #selector(CanvasViewController.focusTerminalRight), "\u{F703}"),
            ("Focus Terminal Above", #selector(CanvasViewController.focusTerminalUp),    "\u{F700}"),
            ("Focus Terminal Below", #selector(CanvasViewController.focusTerminalDown),  "\u{F701}"),
        ] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command]
            windowMenu.addItem(item)
        }

        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")

        // ── Help menu ─────────────────────────────────────────────────────────
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu
        helpMenu.addItem(withTitle: "Mosaic Help", action: nil, keyEquivalent: "?")
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
