import Foundation

/// Classifies an AI coding agent's state from the bottom rows of a terminal's
/// *visible* screen — the screen-scraping approach herdr uses (its "screen
/// manifest"), because agents like Claude Code and opencode don't reliably emit a
/// machine-readable signal on turn completion.
///
/// The patterns are derived from herdr's published Claude Code / opencode detection
/// rules. The load-bearing, cross-agent signal is the **interrupt affordance**: both
/// Claude Code and opencode render an "esc to interrupt" hint while a turn is running,
/// so its presence means *working* and its disappearance (after having been working)
/// means *turn done*. Result is a heuristic, not a contract — treat timing as best
/// effort (herdr does too).
enum AgentActivity: Equatable {
    /// A turn is in progress (interrupt affordance on screen, or compaction running).
    case working
    /// A permission / confirmation prompt is up — the agent needs a decision now.
    case blocked
    /// The agent's input prompt is shown with no interrupt line — it's waiting for you.
    case idle
    /// Not an agent screen we recognize (a plain shell, a pager, etc.).
    case unknown
}

enum AgentActivityDetector {
    /// Classify from the bottom non-empty rows of the visible screen (pass ~15).
    /// Pure and case-insensitive; unit-testable without a PTY.
    static func classify(_ lines: [String]) -> AgentActivity {
        let joined = lines.joined(separator: "\n")

        // WORKING — Claude Code and opencode both show an interrupt affordance while a
        // turn runs ("esc to interrupt" / "esc again to interrupt"). Claude's
        // compaction/compression status must also read as working, not idle, so a
        // long compaction isn't mistaken for "done" (herdr's compacting_busy rule).
        if joined.range(of: #"(?i)esc (again )?to interrupt"#, options: .regularExpression) != nil
            || joined.range(of: #"(?i)(compacting conversation|compressing context)"#, options: .regularExpression) != nil {
            return .working
        }

        // BLOCKED — a permission / confirmation prompt (Claude "Do you want to
        // proceed?", "Enter to confirm · Esc to cancel"). Always wants the user.
        if joined.range(of: #"(?i)do you want to proceed"#, options: .regularExpression) != nil
            || joined.range(of: #"(?i)esc to cancel"#, options: .regularExpression) != nil {
            return .blocked
        }

        // IDLE — the agent's input box is shown and it isn't working/blocked, i.e. it
        // finished and is waiting. Claude uses "❯"; other agents use a similar prompt
        // glyph. Kept deliberately loose: the working→not-working *edge* is what
        // actually raises attention (see the caller), so a missed idle glyph for a
        // less-common agent still resolves to `.unknown`, which the caller treats the
        // same as `.idle` for the done-edge.
        if lines.contains(where: { $0.range(of: #"^\s*[❯›»▌]"#, options: .regularExpression) != nil }) {
            return .idle
        }

        return .unknown
    }
}
