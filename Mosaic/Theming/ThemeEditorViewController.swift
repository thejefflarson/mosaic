import AppKit
import SwiftUI

// MARK: - View model

final class ThemeEditorModel: ObservableObject {
    @Published var name: String
    @Published var canvasBg: Color
    @Published var termBg: Color
    @Published var termFg: Color
    @Published var annotColor: Color
    @Published var stickyFg: Color
    @Published var stickyBg: Color
    @Published var termFontFamily: String   // "" = system monospaced
    @Published var termFontSize: String
    @Published var annotFontFamily: String  // "" = system font
    @Published var annotFontSize: String
    @Published var ansi: [Color]

    /// ID preserved from the source theme so auto-apply keeps the menu checkmark.
    private(set) var sourceID: String

    var onApply: ((Theme) -> Void)?
    var onSave:  ((Theme) -> Void)?

    // MARK: Font family lists (computed once)

    /// All monospaced font families available on the system, "" entry first for system default.
    static let monospaceFamilies: [String] = {
        let mgr = NSFontManager.shared
        let mono = mgr.availableFontFamilies.filter { family in
            let ps = (mgr.availableMembers(ofFontFamily: family)?.first?[0] as? String) ?? ""
            return NSFont(name: ps, size: 12)?.isFixedPitch == true
        }.sorted()
        return [""] + mono
    }()

    /// All font families available on the system, "" entry first for system default.
    static let allFontFamilies: [String] = [""] + NSFontManager.shared.availableFontFamilies.sorted()

    static func displayName(forFamily family: String, isMonospace: Bool) -> String {
        family.isEmpty ? (isMonospace ? "System Monospaced" : "System Font") : family
    }

    // MARK: Init / populate

    init(theme: Theme) {
        sourceID        = theme.id
        name            = theme.name
        canvasBg        = Color(nsColor: theme.canvasBackground)
        termBg          = Color(nsColor: theme.terminalBackground)
        termFg          = Color(nsColor: theme.terminalForeground)
        annotColor      = Color(nsColor: theme.annotationColor)
        stickyFg        = Color(nsColor: theme.stickyForeground)
        stickyBg        = Color(nsColor: theme.stickyBackground)
        termFontFamily  = NSFont(name: theme.fontName, size: 12)?.familyName ?? ""
        termFontSize    = "\(Int(theme.fontSize))"
        annotFontFamily = NSFont(name: theme.annotationFontName, size: 12)?.familyName ?? ""
        annotFontSize   = "\(Int(theme.annotationFontSize))"
        ansi            = theme.ansi.map { Color(nsColor: $0) }
    }

    func populate(from theme: Theme) {
        sourceID        = theme.id
        name            = theme.name
        canvasBg        = Color(nsColor: theme.canvasBackground)
        termBg          = Color(nsColor: theme.terminalBackground)
        termFg          = Color(nsColor: theme.terminalForeground)
        annotColor      = Color(nsColor: theme.annotationColor)
        stickyFg        = Color(nsColor: theme.stickyForeground)
        stickyBg        = Color(nsColor: theme.stickyBackground)
        termFontFamily  = NSFont(name: theme.fontName, size: 12)?.familyName ?? ""
        termFontSize    = "\(Int(theme.fontSize))"
        annotFontFamily = NSFont(name: theme.annotationFontName, size: 12)?.familyName ?? ""
        annotFontSize   = "\(Int(theme.annotationFontSize))"
        ansi            = theme.ansi.map { Color(nsColor: $0) }
    }

    // MARK: Theme building

    /// Builds a theme preserving `sourceID` — used for live preview so the menu checkmark stays.
    func buildPreviewTheme() -> Theme { buildTheme(id: sourceID) }

    /// Builds a new theme with a fresh UUID — used for "Save as New Theme".
    func buildNewTheme() -> Theme { buildTheme(id: UUID().uuidString) }

    private func buildTheme(id: String) -> Theme {
        let raw = name.trimmingCharacters(in: .whitespaces)
        var t = Theme(
            id: id,
            name: raw.isEmpty ? "Custom" : raw,
            canvasBackground: NSColor(canvasBg),
            terminalBackground: NSColor(termBg),
            terminalForeground: NSColor(termFg),
            ansi: ansi.map { NSColor($0) }
        )
        t.fontName           = postScript(for: termFontFamily)
        t.fontSize           = CGFloat(Double(termFontSize) ?? 13)
        t.annotationColor    = NSColor(annotColor)
        t.annotationFontName = postScript(for: annotFontFamily)
        t.annotationFontSize = CGFloat(Double(annotFontSize) ?? 148)
        t.stickyForeground   = NSColor(stickyFg)
        t.stickyBackground   = NSColor(stickyBg)
        return t
    }

    private func postScript(for family: String) -> String {
        guard !family.isEmpty else { return "" }
        return (NSFontManager.shared.availableMembers(ofFontFamily: family)?.first?[0] as? String) ?? ""
    }
}

// MARK: - SwiftUI view

struct ThemeEditorView: View {
    @ObservedObject var model: ThemeEditorModel

    private let ansiNames = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        "Bright Black", "Bright Red", "Bright Green", "Bright Yellow",
        "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

                // Name
                section("Name") {
                    TextField("Theme name", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                // Terminal font
                section("Terminal Font") {
                    HStack(spacing: 8) {
                        Picker("", selection: $model.termFontFamily) {
                            ForEach(ThemeEditorModel.monospaceFamilies, id: \.self) { family in
                                fontLabel(family: family, isMonospace: true).tag(family)
                            }
                        }
                        .frame(width: 200)
                        TextField("13", text: $model.termFontSize)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                        Text("pt").foregroundStyle(.secondary)
                    }
                }

                // Annotation font
                section("Annotation Font") {
                    HStack(spacing: 8) {
                        Picker("", selection: $model.annotFontFamily) {
                            ForEach(ThemeEditorModel.allFontFamilies, id: \.self) { family in
                                fontLabel(family: family, isMonospace: false).tag(family)
                            }
                        }
                        .frame(width: 200)
                        TextField("148", text: $model.annotFontSize)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                        Text("pt").foregroundStyle(.secondary)
                    }
                }

                // Canvas & terminal colors
                section("Canvas & Terminal") {
                    colorRow("Canvas Background",   color: $model.canvasBg)
                    colorRow("Terminal Background", color: $model.termBg)
                    colorRow("Terminal Foreground", color: $model.termFg)
                    colorRow("Drawing Color",       color: $model.annotColor)
                }

                // Sticky note colors
                section("Sticky Notes") {
                    colorRow("Foreground (Text)",   color: $model.stickyFg)
                    colorRow("Background",          color: $model.stickyBg)
                }

                // ANSI palette
                section("ANSI Colors") {
                    ansiGrid()
                }

                Divider()

                // Action buttons
                HStack(spacing: 8) {
                    Button("Save as New Theme") { model.onSave?(model.buildNewTheme()) }
                        .keyboardShortcut(.return)
                    Spacer()
                    Button("Export…", action: exportTheme)
                    Button("Import…", action: importTheme)
                }
        }
        .padding(20)
        // objectWillChange fires before the value changes; async ensures we read new values.
        .onReceive(model.objectWillChange) { _ in
            DispatchQueue.main.async { model.onApply?(model.buildPreviewTheme()) }
        }
    }

    @ViewBuilder
    private func fontLabel(family: String, isMonospace: Bool) -> some View {
        let name = ThemeEditorModel.displayName(forFamily: family, isMonospace: isMonospace)
        if family.isEmpty {
            Text(name)
        } else {
            Text(name).font(.custom(family, size: 13))
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func colorRow(_ label: String, color: Binding<Color>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 160, alignment: .trailing)
            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 80, height: 24)
        }
    }

    @ViewBuilder
    private func ansiGrid() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([0..<8, 8..<16], id: \.lowerBound) { range in
                HStack(spacing: 0) {
                    ForEach(range, id: \.self) { i in
                        VStack(spacing: 3) {
                            ColorPicker("", selection: $model.ansi[i], supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 28, height: 24)
                            Text(ansiNames[i].components(separatedBy: " ").last ?? "")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: 44)
                        }
                        .frame(width: 44)
                    }
                }
            }
        }
    }

    private func exportTheme() {
        guard let data = try? model.buildPreviewTheme().exportData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let rawName = model.name.trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = (rawName.isEmpty ? "Custom" : rawName) + ".json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK,
                  let url = panel.url,
                  let data = try? Data(contentsOf: url),
                  let theme = try? Theme.from(exportData: data) else { return }
            model.populate(from: theme)
        }
    }
}

// MARK: - NSHostingController wrapper

/// A floating panel view controller for creating and editing themes.
final class ThemeEditorViewController: NSHostingController<ThemeEditorView> {

    var onApply: ((Theme) -> Void)? {
        get { model.onApply }
        set { model.onApply = newValue }
    }
    var onSave: ((Theme) -> Void)? {
        get { model.onSave }
        set { model.onSave = newValue }
    }

    private let model: ThemeEditorModel

    init(theme: Theme) {
        let m = ThemeEditorModel(theme: theme)
        self.model = m
        super.init(rootView: ThemeEditorView(model: m))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
