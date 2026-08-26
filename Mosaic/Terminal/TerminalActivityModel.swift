import Foundation

// MARK: - State & events
//
// See Docs/ADR/007-agent-attention-routing.md for the full design. This file is the
// "load-bearing artifact" the ADR calls out — a pure, unit-testable reducer over one
// concept per terminal: "does this terminal want you." Views (minimap dots, title-bar
// indicator, a future roster panel) are cheap rendering over `ActivityState`; none of
// that lives here.

/// What a terminal wants from the user right now.
enum ActivityState: Equatable {
    case quiet
    case busy
    /// `exitCode` is carried through from `.commandFinished` when known; `nil` for
    /// bell/notification-triggered attention or the output-idle heuristic, where no
    /// exit code is available.
    case needsAttention(exitCode: Int?)
}

/// Inputs the reducer folds into `ActivityState`. All timing is caller-supplied via the
/// `at:` timestamps — the reducer never reads the clock itself, so it stays
/// deterministic and testable without sleeping.
enum ActivityEvent {
    case bell
    case notification
    case commandFinished(exitCode: Int?)
    case outputActivity(at: TimeInterval)
    case userKeystroke
    case becameActiveAndVisible
    case quietElapsed(at: TimeInterval)
}

// MARK: - Reducer

/// Per-terminal activity state machine. Pure value type: no AppKit, no PTY, no shared
/// mutable state — safe to construct, copy, and test off the main actor.
///
/// Owning code (a future ticket) is expected to drive this from OSC signals (bell,
/// OSC 777, OSC 133 D) and a per-terminal debounce timer for the output-idle heuristic
/// (ADR 007, decision 5) — this type only holds the reduction logic.
struct TerminalActivityModel {
    private(set) var state: ActivityState = .quiet

    // MARK: Tunable thresholds
    //
    // Guesses until dogfooded (ADR 007). Both are measured against event timestamps,
    // never wall-clock time read here.

    /// Keystroke-free sustained output required before a quiet transition can raise
    /// attention.
    static let busyThreshold: TimeInterval = 15
    /// Silence after a qualifying busy period, after which attention is raised.
    static let quietThreshold: TimeInterval = 4

    // MARK: Bookkeeping

    /// Timestamp of the most recent `outputActivity`.
    private var lastOutputTimestamp: TimeInterval?
    /// Timestamp the current busy period started, or `nil` when not in one.
    private var busyPeriodStart: TimeInterval?
    /// Whether a `userKeystroke` landed during the current busy period — disqualifies
    /// it from raising attention (the editor/pager shape: sustained output the user is
    /// actively driving, not a long-running command they've walked away from).
    private var keystrokeDuringBusyPeriod = false
    /// Whether this terminal is currently the active, on-viewport terminal in the
    /// active app — raising events are suppressed while this holds, since the user is
    /// already watching. Set by `becameActiveAndVisible`; wiring the corresponding
    /// "no longer" transition is deferred to the ticket that connects this model to
    /// `TerminalController`'s focus/culling state (ADR 007's extension seam is one new
    /// `ActivityEvent` case plus one reducer clause).
    private var isActiveAndVisible = false

    init() {}

    // MARK: - Reduce

    @discardableResult
    mutating func reduce(_ event: ActivityEvent) -> ActivityState {
        switch event {
        case .bell, .notification:
            raiseAttention(exitCode: nil)

        case .commandFinished(let exitCode):
            raiseAttention(exitCode: exitCode)

        case .outputActivity(let at):
            recordOutput(at: at)

        case .userKeystroke:
            switch state {
            case .needsAttention:
                clearToQuiet()
            case .busy:
                keystrokeDuringBusyPeriod = true
            case .quiet:
                break
            }

        case .becameActiveAndVisible:
            isActiveAndVisible = true
            if case .needsAttention = state {
                clearToQuiet()
            }

        case .quietElapsed(let at):
            handleQuietElapsed(at: at)
        }
        return state
    }

    // MARK: - Event handling

    /// Raises `needsAttention`, unless suppressed (active-and-visible). Idempotent: a
    /// repeat of the same signal is a no-op. When attention is already raised, a new
    /// exit code only *promotes* the state — never downgrades it — since OSC 133 D is
    /// a bonus coloring tier that lands after the primary signal (bell/notification/
    /// output-idle) already raised attention with no exit code (ADR 007, decision 4).
    private mutating func raiseAttention(exitCode: Int?) {
        guard !isActiveAndVisible else { return }
        guard case .needsAttention(let existingExitCode) = state else {
            state = .needsAttention(exitCode: exitCode)
            return
        }
        if existingExitCode == nil, let exitCode {
            state = .needsAttention(exitCode: exitCode)
        }
    }

    private mutating func clearToQuiet() {
        state = .quiet
        busyPeriodStart = nil
        keystrokeDuringBusyPeriod = false
        lastOutputTimestamp = nil
    }

    private mutating func recordOutput(at time: TimeInterval) {
        lastOutputTimestamp = time
        // Output while attention is pending doesn't clear it — attention persists
        // until the user actually attends (ADR 007, decision 3).
        guard case .quiet = state else { return }
        state = .busy
        busyPeriodStart = time
        keystrokeDuringBusyPeriod = false
    }

    private mutating func handleQuietElapsed(at time: TimeInterval) {
        guard case .busy = state else { return }

        let qualifies: Bool
        if let start = busyPeriodStart, let lastOutput = lastOutputTimestamp {
            qualifies = !keystrokeDuringBusyPeriod
                && (lastOutput - start) >= Self.busyThreshold
                && (time - lastOutput) >= Self.quietThreshold
        } else {
            qualifies = false
        }

        // The busy period is over either way — clear its bookkeeping and drop back to
        // quiet before (maybe) raising, so a suppressed or disqualified raise still
        // leaves the model in `.quiet` rather than stuck in `.busy`.
        clearToQuiet()
        if qualifies {
            raiseAttention(exitCode: nil)
        }
    }
}
