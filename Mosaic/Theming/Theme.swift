import AppKit

struct Theme {
    let id: String
    let name: String
    let canvasBackground: NSColor
    let terminalBackground: NSColor
    let terminalForeground: NSColor
    /// ANSI palette indices 0–15 (normal 0–7, bright 8–15).
    let ansi: [NSColor]
    /// Terminal font. Empty string = system monospaced.
    var fontName: String = ""
    var fontSize: CGFloat = 13
    /// Color used for text annotations, arrows, and freehand strokes.
    var annotationColor: NSColor = .white
    /// Font for text annotations.
    var annotationFontName: String = "HoeflerText-Regular"
    var annotationFontSize: CGFloat = 148
    /// Sticky note text color.
    var stickyForeground: NSColor = c(0x1a1a1a)
    /// Sticky note background color.
    var stickyBackground: NSColor = c(0xfff9a3)

    var terminalFont: NSFont {
        let size = fontSize
        if fontName.isEmpty { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var annotationFont: NSFont {
        let size = annotationFontSize
        return NSFont(name: annotationFontName, size: size)
            ?? NSFont(name: "HoeflerText-Regular", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .regular)
    }

    static let monospaceFonts: [(name: String, postScript: String)] = [
        ("System Mono (SF Mono)", ""),
        ("Menlo",         "Menlo-Regular"),
        ("Monaco",        "Monaco"),
        ("Courier New",   "CourierNewPSMT"),
        ("PT Mono",       "PTMono-Regular"),
    ]

    static let annotationFonts: [(name: String, postScript: String)] = [
        ("Hoefler Text",          "HoeflerText-Regular"),
        ("System (SF Pro)",       ""),
        ("Helvetica Neue",        "HelveticaNeue"),
        ("Helvetica Neue Bold",   "HelveticaNeue-Bold"),
        ("Arial",                 "ArialMT"),
        ("Arial Bold",            "Arial-BoldMT"),
        ("Georgia",               "Georgia"),
        ("Georgia Bold",          "Georgia-Bold"),
        ("Futura Medium",         "Futura-Medium"),
        ("Impact",                "Impact"),
        ("Menlo",                 "Menlo-Regular"),
    ]

    /// OSC escape sequences that apply this theme to a running terminal emulator.
    var oscSequences: String {
        var s = ""
        s += "\u{1B}]10;\(rgb(terminalForeground))\u{07}"   // default fg
        s += "\u{1B}]11;\(rgb(terminalBackground))\u{07}"   // default bg
        for (i, color) in ansi.enumerated() {
            s += "\u{1B}]4;\(i);\(rgb(color))\u{07}"
        }
        return s
    }

    private func rgb(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return String(format: "rgb:%02x/%02x/%02x",
                      Int(c.redComponent * 255),
                      Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}

// MARK: - Built-in themes + custom theme persistence

extension Theme {
    private static let builtIn: [Theme] = [.dark, .solarizedDark, .oneDark, .gruvboxDark, .light]

    /// All themes: built-ins first, then any user-saved custom themes.
    static var allThemes: [Theme] { builtIn + customThemes }

    static var customThemes: [Theme] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "customThemes"),
                  let stored = try? JSONDecoder().decode([StoredTheme].self, from: data)
            else { return [] }
            return stored.map(\.asTheme)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue.map(StoredTheme.init)) {
                UserDefaults.standard.set(data, forKey: "customThemes")
            }
        }
    }

    static func deleteCustomTheme(id: String) {
        customThemes.removeAll { $0.id == id }
    }

    /// VS Code Dark+
    static let dark = Theme(
        id: "dark",
        name: "Dark",
        canvasBackground: c(0x141414),
        terminalBackground: c(0x1e1e1e),
        terminalForeground: c(0xd4d4d4),
        ansi: [
            c(0x1e1e1e), c(0xcd3131), c(0x0dbc79), c(0xe5e510),
            c(0x2472c8), c(0xbc3fbc), c(0x11a8cd), c(0xe5e5e5),
            c(0x666666), c(0xf14c4c), c(0x23d18b), c(0xf5f543),
            c(0x3b8eea), c(0xd670d6), c(0x29b8db), c(0xffffff),
        ]
    )

    static let solarizedDark = Theme(
        id: "solarized-dark",
        name: "Solarized Dark",
        canvasBackground: c(0x001e27),
        terminalBackground: c(0x002b36),
        terminalForeground: c(0x839496),
        ansi: [
            c(0x073642), c(0xdc322f), c(0x859900), c(0xb58900),
            c(0x268bd2), c(0xd33682), c(0x2aa198), c(0xeee8d5),
            c(0x002b36), c(0xcb4b16), c(0x586e75), c(0x657b83),
            c(0x839496), c(0x6c71c4), c(0x93a1a1), c(0xfdf6e3),
        ]
    )

    static let oneDark = Theme(
        id: "one-dark",
        name: "One Dark",
        canvasBackground: c(0x1a1d21),
        terminalBackground: c(0x282c34),
        terminalForeground: c(0xabb2bf),
        ansi: [
            c(0x282c34), c(0xe06c75), c(0x98c379), c(0xe5c07b),
            c(0x61afef), c(0xc678dd), c(0x56b6c2), c(0xabb2bf),
            c(0x5c6370), c(0xe06c75), c(0x98c379), c(0xe5c07b),
            c(0x61afef), c(0xc678dd), c(0x56b6c2), c(0xffffff),
        ]
    )

    static let gruvboxDark = Theme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        canvasBackground: c(0x1b1b1b),
        terminalBackground: c(0x282828),
        terminalForeground: c(0xebdbb2),
        ansi: [
            c(0x282828), c(0xcc241d), c(0x98971a), c(0xd79921),
            c(0x458588), c(0xb16286), c(0x689d6a), c(0xa89984),
            c(0x928374), c(0xfb4934), c(0xb8bb26), c(0xfabd2f),
            c(0x83a598), c(0xd3869b), c(0x8ec07c), c(0xebdbb2),
        ]
    )

    /// Solarized Light
    static let light = Theme(
        id: "light",
        name: "Light",
        canvasBackground: c(0xd0cfc9),
        terminalBackground: c(0xfdf6e3),
        terminalForeground: c(0x657b83),
        ansi: [
            c(0x073642), c(0xdc322f), c(0x859900), c(0xb58900),
            c(0x268bd2), c(0xd33682), c(0x2aa198), c(0xfdf6e3),
            c(0x002b36), c(0xcb4b16), c(0x586e75), c(0x657b83),
            c(0x839496), c(0x6c71c4), c(0x93a1a1), c(0xeee8d5),
        ]
    )
}

private func c(_ rgb: UInt32) -> NSColor {
    NSColor(
        red:   CGFloat((rgb >> 16) & 0xff) / 255,
        green: CGFloat((rgb >>  8) & 0xff) / 255,
        blue:  CGFloat( rgb        & 0xff) / 255,
        alpha: 1
    )
}

// MARK: - Serialization helpers

struct StoredTheme: Codable {
    let id: String
    let name: String
    let canvasBg: String
    let termBg: String
    let termFg: String
    let ansi: [String]
    var fontName: String?
    var fontSize: CGFloat?
    var annotationColor: String?
    var annotationFontName: String?
    var annotationFontSize: CGFloat?
    var stickyForeground: String?
    var stickyBackground: String?

    init(_ theme: Theme) {
        id = theme.id; name = theme.name
        canvasBg            = theme.canvasBackground.hexString
        termBg              = theme.terminalBackground.hexString
        termFg              = theme.terminalForeground.hexString
        ansi                = theme.ansi.map(\.hexString)
        fontName            = theme.fontName
        fontSize            = theme.fontSize
        annotationColor     = theme.annotationColor.hexString
        annotationFontName  = theme.annotationFontName
        annotationFontSize  = theme.annotationFontSize
        stickyForeground    = theme.stickyForeground.hexString
        stickyBackground    = theme.stickyBackground.hexString
    }

    var asTheme: Theme {
        var t = Theme(id: id, name: name,
                      canvasBackground: .fromHex(canvasBg),
                      terminalBackground: .fromHex(termBg),
                      terminalForeground: .fromHex(termFg),
                      ansi: ansi.map(NSColor.fromHex))
        t.fontName            = fontName ?? ""
        t.fontSize            = fontSize ?? 13
        t.annotationColor     = annotationColor.map(NSColor.fromHex) ?? .white
        t.annotationFontName  = annotationFontName ?? ""
        t.annotationFontSize  = annotationFontSize ?? 148
        t.stickyForeground    = stickyForeground.map(NSColor.fromHex) ?? c(0x1a1a1a)
        t.stickyBackground    = stickyBackground.map(NSColor.fromHex) ?? c(0xfff9a3)
        return t
    }
}

extension Theme {
    /// Encode this theme as portable JSON data (for sharing / export).
    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(StoredTheme(self))
    }

    /// Decode a theme from previously exported JSON data.
    static func from(exportData data: Data) throws -> Theme {
        try JSONDecoder().decode(StoredTheme.self, from: data).asTheme
    }
}

extension NSColor {
    /// Packed 24-bit RGB integer (0xRRGGBB) in sRGB space.
    var hex: Int {
        let cc = usingColorSpace(.sRGB) ?? self
        let r = Int(max(0, min(1, cc.redComponent))   * 255)
        let g = Int(max(0, min(1, cc.greenComponent)) * 255)
        let b = Int(max(0, min(1, cc.blueComponent))  * 255)
        return (r << 16) | (g << 8) | b
    }

    var hexString: String { String(format: "#%06x", hex) }

    static func fromHex(_ hex: String) -> NSColor {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let rgb = UInt32(s, radix: 16) else { return .white }
        return c(rgb)
    }
}

extension Notification.Name {
    static let themesDidChange = Notification.Name("MosaicThemesDidChange")
}
