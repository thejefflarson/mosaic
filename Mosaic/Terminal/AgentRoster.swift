import Foundation

/// A terminal's agent state copied into plain values, so the roster can be built and
/// ordered without holding a view or PTY (ADR 010). Consumers resolve `id` back to the
/// live terminal at click time; a closed terminal resolves to nil.
struct AgentSnapshot: Sendable, Equatable {
    let id: UUID
    let title: String
    let cwd: String
    let agentID: String
    let agentActivity: AgentActivity?
    let activityState: ActivityState
    let stateSince: Date
}

enum AgentGroup: Int, Sendable, CaseIterable {
    case needsYou, working, idle
}

/// Pure group assignment and ordering for the Agents View roster (ADR 010).
enum AgentRoster {
    /// `needsAttention` and `blocked` both mean the user owes a response, so they win over
    /// any working signal. The blocked / finished / exit-N distinction is a row sublabel,
    /// not a group.
    ///
    /// Every row here is a *recognized* agent, so the herdr `agentActivity` — not the
    /// generic `ActivityState.busy` — decides working vs idle. That matters because a
    /// running agent's TUI redraws constantly (spinner, token counter), which keeps the
    /// generic reducer `.busy` even while the agent sits idle at its prompt; letting
    /// `.busy` mean "working" would pin every agent to the working group forever. `.busy`
    /// is consulted only as a last resort when the manifest yields no opinion at all.
    static func group(activityState: ActivityState, agentActivity: AgentActivity?) -> AgentGroup {
        if case .needsAttention = activityState { return .needsYou }
        switch agentActivity {
        case .blocked: return .needsYou
        case .working: return .working
        case .idle: return .idle
        case .unknown, .none: return activityState == .busy ? .working : .idle
        }
    }

    static func group(for snapshot: AgentSnapshot) -> AgentGroup {
        group(activityState: snapshot.activityState, agentActivity: snapshot.agentActivity)
    }

    /// Orders by group, then within a group: needs-you oldest first (matching the attention
    /// pill's FIFO), working longest-running first, idle most recently active first. Ties
    /// break on id so the order is deterministic.
    static func ordered(_ snapshots: [AgentSnapshot]) -> [AgentSnapshot] {
        snapshots.sorted { a, b in
            let ga = group(for: a), gb = group(for: b)
            if ga != gb { return ga.rawValue < gb.rawValue }
            if a.stateSince != b.stateSince {
                return ga == .idle ? a.stateSince > b.stateSince : a.stateSince < b.stateSince
            }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
