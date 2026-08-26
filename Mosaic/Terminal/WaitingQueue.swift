import Foundation

/// A terminal's identity plus when it started waiting — the minimal, non-retaining
/// snapshot `WaitingQueue.oldestWaiting` needs. A plain value type (not the concrete
/// `TerminalWindowView`) so the FIFO selection below is pure and directly
/// unit-testable, following `SnapEngine.snapRect`'s pattern of operating on values
/// extracted from views rather than the views themselves.
struct WaitingCandidate {
    let id: UUID
    let attentionRaisedAt: TimeInterval
}

/// Pure "next waiting terminal" selection shared by the attention pill's click
/// handler and the `Jump to Waiting Terminal` menu command (see
/// `Docs/ADR/007-agent-attention-routing.md`). The waiting set drains FIFO,
/// oldest-first — a queue, not a stack, so repeated jumps read as draining a
/// backlog and never starve a terminal that's been waiting a while.
enum WaitingQueue {
    /// The id of the candidate that has been waiting longest, or nil when
    /// `candidates` is empty.
    static func oldestWaiting(in candidates: [WaitingCandidate]) -> UUID? {
        candidates.min { $0.attentionRaisedAt < $1.attentionRaisedAt }?.id
    }
}
