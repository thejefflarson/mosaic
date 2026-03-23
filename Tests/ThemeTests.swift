import Testing
import AppKit
@testable import Mosaic

struct ThemeTests {

    // MARK: - Export / Import round-trip

    @Test func exportImportRoundTrip() throws {
        let original = Theme.dark
        let decoded  = try Theme.from(exportData: original.exportData())
        #expect(decoded.id   == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.canvasBackground.hex   == original.canvasBackground.hex)
        #expect(decoded.terminalBackground.hex == original.terminalBackground.hex)
        #expect(decoded.terminalForeground.hex == original.terminalForeground.hex)
        #expect(decoded.ansi.map(\.hex)        == original.ansi.map(\.hex))
        #expect(decoded.fontName               == original.fontName)
        #expect(decoded.fontSize               == original.fontSize)
        #expect(decoded.annotationColor.hex    == original.annotationColor.hex)
        #expect(decoded.annotationFontName     == original.annotationFontName)
        #expect(decoded.annotationFontSize     == original.annotationFontSize)
    }

    @Test func customThemeExportImportRoundTrip() throws {
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

        let decoded = try Theme.from(exportData: theme.exportData())
        #expect(decoded.fontName           == "Menlo-Regular")
        #expect(decoded.fontSize           == 15)
        #expect(decoded.annotationFontName == "Georgia-Bold")
        #expect(decoded.annotationFontSize == 100)
        #expect(decoded.annotationColor.hex == NSColor.red.hex)
    }

    // MARK: - Font fallbacks

    @Test func terminalFontFallbackToSystemMono() {
        var theme = Theme.dark; theme.fontName = ""
        let font = theme.terminalFont
        #expect(font.pointSize == theme.fontSize)
    }

    @Test func terminalFontFallbackForInvalidName() {
        var theme = Theme.dark; theme.fontName = "NonExistentFontXYZ"; theme.fontSize = 14
        #expect(theme.terminalFont.pointSize == 14)
    }

    @Test func annotationFontFallbackToHoeflerThenSystem() {
        // Empty name falls back to Hoefler Text; unresolvable name falls back to system.
        var theme = Theme.dark; theme.annotationFontName = ""; theme.annotationFontSize = 72
        #expect(theme.annotationFont.pointSize == 72)
        theme.annotationFontName = "NonExistentFont-XYZ"
        #expect(theme.annotationFont.pointSize == 72)
    }

    // MARK: - OSC sequences

    @Test(arguments: 0..<16)
    func oscSequenceContainsAnsiIndex(_ i: Int) {
        #expect(Theme.dark.oscSequences.contains("4;\(i);"),
                "Missing ANSI index \(i) in OSC sequences")
    }

    @Test func oscSequencesContainFgAndBg() {
        let osc = Theme.dark.oscSequences
        #expect(osc.contains("]10;"))
        #expect(osc.contains("]11;"))
    }

    // MARK: - Built-in theme ID stability (regression guard)

    @Test func builtInThemeIdsAreStable() {
        #expect(Theme.dark.id          == "dark")
        #expect(Theme.solarizedDark.id == "solarized-dark")
        #expect(Theme.oneDark.id       == "one-dark")
        #expect(Theme.gruvboxDark.id   == "gruvbox-dark")
        #expect(Theme.light.id         == "light")
    }

    @Test(arguments: [Theme.dark, .solarizedDark, .oneDark, .gruvboxDark, .light])
    func builtInThemeHas16AnsiColors(_ theme: Theme) {
        #expect(theme.ansi.count == 16, "\(theme.name) should have 16 ANSI colors")
    }

    // MARK: - Hex color conversion

    @Test func hexRoundTrip() {
        let color = NSColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        let hex = color.hex
        let r = CGFloat((hex >> 16) & 0xff) / 255
        let g = CGFloat((hex >>  8) & 0xff) / 255
        let b = CGFloat( hex        & 0xff) / 255
        #expect(abs(r - color.redComponent)   < 1.0/255)
        #expect(abs(g - color.greenComponent) < 1.0/255)
        #expect(abs(b - color.blueComponent)  < 1.0/255)
    }
}
