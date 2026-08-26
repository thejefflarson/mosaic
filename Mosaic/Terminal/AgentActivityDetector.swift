import Foundation

/// Classifies an AI coding agent's state from the bottom rows of a terminal's
/// *visible* screen — the screen-scraping approach herdr uses (its "screen
/// manifest"), because agents like Claude Code and opencode don't reliably emit a
/// machine-readable signal on turn completion.
///
/// Patterns are ported from herdr's published `claude.toml` / `opencode.toml`
/// detection manifests (`herdrdev/herdr`, `src/detect/manifests`). The important
/// subtlety, learned there: "working" must be the **live turn line** — a spinner
/// glyph at line start followed by the interrupt hint (`⠋ Baking… (esc to interrupt)`,
/// `⏵ … esc to interrupt`, `✻ Thinking…`) — *not* merely a line that contains
/// "esc to interrupt". Matching the bare phrase gets stuck in "working" because stale
/// interrupt text can linger above a fresh idle prompt (herdr's own bug #352). Result
/// is a heuristic, not a contract — treat timing as best effort.
enum AgentActivity: Equatable {
    /// A turn is in progress (a live spinner/interrupt line, or compaction running).
    case working
    /// A permission / confirmation prompt is up — the agent needs a decision now.
    case blocked
    /// The agent's input prompt (`❯`) is shown — it finished and is waiting for you.
    case idle
    /// Not an agent screen we recognize (a plain shell, a pager, etc.).
    case unknown
}

enum AgentActivityDetector {
    /// A live interrupt-hint line: an interrupt spinner (⏸/⏵, braille U+2800–28FF, or
    /// half-circle U+25D0–25D3) at line start, then "esc to interrupt". Deliberately
    /// excludes the `·`/`*`/`✻` activity bullets — those only introduce the ellipsis
    /// line below, and a stale "· … esc to interrupt" note must not read as working.
    private static let interruptLineRegex =
        #"(?i)^\s*[\x{23F8}\x{23F5}\x{2800}-\x{28FF}\x{25D0}-\x{25D3}].*esc to interrupt"#
    /// A live activity line: an activity bullet (·, *, ✢, ✶, ✻, ✽) then text ending in
    /// an ellipsis ("✻ Thinking…"). Mirrors herdr's `live_turn_working` second matcher.
    private static let activityLineRegex =
        #"^\s*[\x{002A}\x{00B7}\x{2722}\x{2736}\x{273B}\x{273D}]\s+\S.*…"#

    /// Classify from the bottom non-empty rows of the visible screen (pass ~15). Pure
    /// and case-insensitive; unit-testable without a PTY.
    static func classify(_ lines: [String]) -> AgentActivity {
        let lower = lines.joined(separator: "\n").lowercased()

        // BLOCKED — a permission / confirmation prompt (highest attention priority).
        if lower.contains("do you want to proceed?") || lower.contains("esc to cancel")
            || lower.contains("permission required") || lower.contains("waiting for permission")
            || lower.contains("do you want to allow this connection?") {
            return .blocked
        }

        // WORKING — a live turn line (Claude), or Claude compaction, or opencode's
        // interrupt hints. opencode redraws its footer so a plain phrase is safe there;
        // Claude needs the strict leading-glyph line above.
        for line in lines {
            if line.range(of: interruptLineRegex, options: .regularExpression) != nil { return .working }
            if line.range(of: activityLineRegex, options: .regularExpression) != nil { return .working }
        }
        if lower.contains("press esc to interrupt") || lower.contains("ctrl+c to interrupt")
            || lower.contains("esc again to interrupt")
            || lower.contains("compacting conversation") || lower.contains("compressing context") {
            return .working
        }

        // IDLE — the input prompt box (`❯`), agent finished and waiting for you.
        for line in lines where line.range(of: #"^\s*❯"#, options: .regularExpression) != nil {
            return .idle
        }

        return .unknown
    }
}
