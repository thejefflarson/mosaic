import XCTest
@testable import Mosaic

final class ThemeTests: XCTestCase {

    // MARK: - Export / Import round-trip

    func testExportImportRoundTrip() throws {
        let original = Theme.dark
        let data = try original.exportData()
        let decoded = try Theme.from(exportData: data)

        XCTAssertEqual(decoded.id,   original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.canvasBackground.hex,    original.canvasBackground.hex)
        XCTAssertEqual(decoded.terminalBackground.hex,  original.terminalBackground.hex)
        XCTAssertEqual(decoded.terminalForeground.hex,  original.terminalForeground.hex)
        XCTAssertEqual(decoded.ansi.map(\.hex),         original.ansi.map(\.hex))
        XCTAssertEqual(decoded.fontName,                original.fontName)
        XCTAssertEqual(decoded.fontSize,                original.fontSize)
        XCTAssertEqual(decoded.annotationColor.hex,     original.annotationColor.hex)
        XCTAssertEqual(decoded.annotationFontName,      original.annotationFontName)
        XCTAssertEqual(decoded.annotationFontSize,      original.annotationFontSize)
    }

    func testCustomThemeExportImportRoundTrip() throws {
        var theme = Theme.oneDark
        theme = Theme(id: "custom-test", name: "Custom Test",
                      canvasBackground: theme.canvasBackground,
                      terminalBackground: theme.terminalBackground,
                      terminalForeground: theme.terminalForeground,
                      ansi: theme.ansi)
        theme.fontName = "Menlo-Regular"
        theme.fontSize = 15
        theme.annotationColor = .red
        theme.annotationFontName = "Georgia-Bold"
        theme.annotationFontSize = 100

        let data = try theme.exportData()
        let decoded = try Theme.from(exportData: data)

        XCTAssertEqual(decoded.fontName,        "Menlo-Regular")
        XCTAssertEqual(decoded.fontSize,        15)
        XCTAssertEqual(decoded.annotationFontName, "Georgia-Bold")
        XCTAssertEqual(decoded.annotationFontSize, 100)
        XCTAssertEqual(decoded.annotationColor.hex, NSColor.red.hex)
    }

    // MARK: - Font fallbacks

    func testTerminalFontFallbackToSystemMono() {
        var theme = Theme.dark
        theme.fontName = ""
        let font = theme.terminalFont
        XCTAssertNotNil(font)
        // System monospaced font is always available
        XCTAssertEqual(font.pointSize, theme.fontSize)
    }

    func testTerminalFontFallbackForInvalidName() {
        var theme = Theme.dark
        theme.fontName = "NonExistentFontXYZ"
        theme.fontSize = 14
        let font = theme.terminalFont
        XCTAssertEqual(font.pointSize, 14)  // fallback still uses requested size
    }

    func testAnnotationFontFallbackToSystem() {
        var theme = Theme.dark
        theme.annotationFontName = ""
        theme.annotationFontSize = 72
        let font = theme.annotationFont
        XCTAssertEqual(font.pointSize, 72)
    }

    // MARK: - OSC sequences

    func testOscSequencesContainAllAnsiIndices() {
        let osc = Theme.dark.oscSequences
        for i in 0..<16 {
            XCTAssertTrue(osc.contains("4;\(i);"), "Missing ANSI index \(i) in OSC sequences")
        }
    }

    func testOscSequencesContainFgAndBg() {
        let osc = Theme.dark.oscSequences
        XCTAssertTrue(osc.contains("]10;"), "Missing foreground OSC sequence")
        XCTAssertTrue(osc.contains("]11;"), "Missing background OSC sequence")
    }

    // MARK: - Built-in theme ID stability (regression guard)

    func testBuiltInThemeIdsAreStable() {
        XCTAssertEqual(Theme.dark.id,         "dark")
        XCTAssertEqual(Theme.solarizedDark.id, "solarized-dark")
        XCTAssertEqual(Theme.oneDark.id,       "one-dark")
        XCTAssertEqual(Theme.gruvboxDark.id,   "gruvbox-dark")
        XCTAssertEqual(Theme.light.id,         "light")
    }

    func testBuiltInThemesHave16AnsiColors() {
        for theme in [Theme.dark, .solarizedDark, .oneDark, .gruvboxDark, .light] {
            XCTAssertEqual(theme.ansi.count, 16, "\(theme.name) should have 16 ANSI colors")
        }
    }

    // MARK: - Hex color conversion

    func testHexRoundTrip() {
        let color = NSColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        let hex = color.hex
        let r = CGFloat((hex >> 16) & 0xff) / 255
        let g = CGFloat((hex >>  8) & 0xff) / 255
        let b = CGFloat( hex        & 0xff) / 255
        XCTAssertEqual(r, color.redComponent,   accuracy: 1.0/255)
        XCTAssertEqual(g, color.greenComponent, accuracy: 1.0/255)
        XCTAssertEqual(b, color.blueComponent,  accuracy: 1.0/255)
    }
}
