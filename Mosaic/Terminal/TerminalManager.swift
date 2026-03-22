import AppKit

/// Tracks all live terminal windows. Does not own their views — just the list.
@MainActor
final class TerminalManager {
    private(set) var windows: [TerminalWindowView] = []

    func spawn(frame: CGRect, shell: String, cwd: String?) -> TerminalWindowView {
        let tw = TerminalWindowView(frame: frame, shell: shell, cwd: cwd)
        windows.append(tw)
        return tw
    }

    func kill(_ tw: TerminalWindowView) {
        tw.terminate()
        tw.removeFromSuperview()
        windows.removeAll { $0 === tw }
    }
}
