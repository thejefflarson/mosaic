import AppKit
import SwiftUI

// MARK: - View model

final class TerminalSettingsModel: ObservableObject {
    @Published var cursorStyle: TerminalSettings.StoredCursorStyle
    @Published var scrollbackLines: String
    @Published var optionAsMetaKey: Bool
    @Published var backspaceSendsControlH: Bool
    @Published var allowMouseReporting: Bool
    @Published var useBrightColors: Bool
    @Published var panOnBell: Bool
    @Published var flashOnBell: Bool

    var onApply: ((TerminalSettings) -> Void)?

    init() {
        let s = TerminalSettings.shared
        cursorStyle            = s.cursorStyle
        scrollbackLines        = ""
        optionAsMetaKey        = s.optionAsMetaKey
        backspaceSendsControlH = s.backspaceSendsControlH
        allowMouseReporting    = s.allowMouseReporting
        useBrightColors        = s.useBrightColors
        panOnBell              = s.panOnBell
        flashOnBell            = s.flashOnBell
    }

    func buildSettings() -> TerminalSettings {
        var s = TerminalSettings()
        s.cursorStyle            = cursorStyle
        s.scrollbackLines        = scrollbackLines.isEmpty ? TerminalSettings.shared.scrollbackLines : (Int(scrollbackLines) ?? 500)
        s.optionAsMetaKey        = optionAsMetaKey
        s.backspaceSendsControlH = backspaceSendsControlH
        s.allowMouseReporting    = allowMouseReporting
        s.useBrightColors        = useBrightColors
        s.panOnBell              = panOnBell
        s.flashOnBell            = flashOnBell
        return s
    }
}

// MARK: - SwiftUI view

struct TerminalSettingsView: View {
    @ObservedObject var model: TerminalSettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Cursor style", selection: $model.cursorStyle) {
                    ForEach(TerminalSettings.StoredCursorStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                HStack {
                    Text("Scrollback lines")
                    Spacer()
                    TextField("500", text: $model.scrollbackLines)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("lines")
                        .foregroundStyle(.secondary)
                }
                .help("Buffer size for new terminals. Existing terminals are unaffected.")
            } header: {
                Text("New Terminals")
            }
            .padding(.bottom, 4)

            Section {
                Toggle("Option key sends Meta (ESC prefix)", isOn: $model.optionAsMetaKey)
                    .help("Makes ⌥ act as the Meta key in Vim, Emacs, etc.")
                Toggle("Backspace sends ^H", isOn: $model.backspaceSendsControlH)
                    .help("Default is ^? (DEL). Enable only if your remote system requires ^H.")
                Toggle("Allow mouse reporting", isOn: $model.allowMouseReporting)
                    .help("Lets terminal applications (Vim, tmux, etc.) receive mouse events.")
                Toggle("Use bright colors for bold text", isOn: $model.useBrightColors)
                    .help("When off, bold text renders in bold weight using the normal colour.")
            } header: {
                Text("Input & Rendering")
            }

            Section {
                Toggle("Flash terminal border on bell", isOn: $model.flashOnBell)
                    .help("Briefly flash the terminal border when it emits a bell or notification.")
                Toggle("Pan to terminal on bell", isOn: $model.panOnBell)
                    .help("Automatically pan the canvas to a terminal when it emits a bell or OSC notification.")
            } header: {
                Text("Notifications")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
        .onReceive(model.objectWillChange) { _ in
            DispatchQueue.main.async { [weak model] in
                guard let model else { return }
                let s = model.buildSettings()
                TerminalSettings.shared = s
                model.onApply?(s)
            }
        }
    }
}

// MARK: - NSHostingController wrapper

final class TerminalSettingsViewController: NSHostingController<TerminalSettingsView> {

    var onApply: ((TerminalSettings) -> Void)? {
        get { model.onApply }
        set { model.onApply = newValue }
    }

    private let model: TerminalSettingsModel

    init() {
        let m = TerminalSettingsModel()
        self.model = m
        super.init(rootView: TerminalSettingsView(model: m))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}
