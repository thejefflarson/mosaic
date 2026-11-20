import Foundation

/// Pure display derivations for the Agents panel rows (ADR 010). Kept free of SwiftUI so
/// they can be unit tested.
enum AgentRowFormat {
    static let rowHeightNeedsYou: CGFloat = 44
    static let rowHeightCompact: CGFloat = 28
    static let headerHeight: CGFloat = 24
    static let panelPadding: CGFloat = 8

    enum Glyph: Equatable { case filledCircle, hollowCircle, triangle }

    static func displayName(agentID: String) -> String {
        switch agentID {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "opencode": return "opencode"
        default: return agentID.capitalized
        }
    }

    /// The working directory's last path component, or the window title when the cwd is
    /// empty or the home directory (where the basename says nothing about the project).
    static func location(cwd: String, title: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if trimmed.isEmpty || trimmed == "/" || trimmed == home { return title }
        return (trimmed as NSString).lastPathComponent
    }

    static func duration(since: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(since)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }

    static func glyph(for snapshot: AgentSnapshot) -> Glyph {
        if failureExitCode(of: snapshot) != nil { return .triangle }
        return AgentRoster.group(for: snapshot) == .idle ? .hollowCircle : .filledCircle
    }

    /// Reason line for needs-you rows; nil for other groups.
    static func reason(for snapshot: AgentSnapshot) -> String? {
        guard AgentRoster.group(for: snapshot) == .needsYou else { return nil }
        if snapshot.agentActivity == .blocked { return "Needs a decision" }
        if let code = failureExitCode(of: snapshot) { return "Finished · exit \(code)" }
        return "Waiting for you"
    }

    static func groupTitle(_ group: AgentGroup) -> String {
        switch group {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .idle: return "Idle"
        }
    }

    static func rowHeight(for group: AgentGroup) -> CGFloat {
        group == .needsYou ? rowHeightNeedsYou : rowHeightCompact
    }

    /// Total content height for `snapshots`, used to size the panel up to its cap.
    static func contentHeight(for snapshots: [AgentSnapshot]) -> CGFloat {
        var height = panelPadding * 2
        for group in AgentGroup.allCases {
            let count = snapshots.filter { AgentRoster.group(for: $0) == group }.count
            if count > 0 { height += headerHeight + CGFloat(count) * rowHeight(for: group) }
        }
        return height
    }

    /// A nonzero exit code only; exit 0 and no code read as plain "waiting".
    private static func failureExitCode(of snapshot: AgentSnapshot) -> Int? {
        if case .needsAttention(let code) = snapshot.activityState, let code, code != 0 { return code }
        return nil
    }
}
