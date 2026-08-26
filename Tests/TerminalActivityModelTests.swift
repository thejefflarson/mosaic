import Testing
@testable import Mosaic

struct TerminalActivityModelTests {

    // MARK: - Protocol signals raise attention

    @Test func bellRaisesAttention() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.bell(at: 0)) == .needsAttention(exitCode: nil))
    }

    @Test func notificationRaisesAttention() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.notification(at: 0)) == .needsAttention(exitCode: nil))
    }

    @Test func commandFinishedCarriesExitCodeThrough() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.commandFinished(exitCode: 1, at: 0)) == .needsAttention(exitCode: 1))
    }

    @Test func commandFinishedWithoutExitCodeCarriesNilThrough() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.commandFinished(exitCode: nil, at: 0)) == .needsAttention(exitCode: nil))
    }

    @Test func nonzeroZeroAndNilExitAreAllDistinguished() {
        var nonzero = TerminalActivityModel()
        var zero = TerminalActivityModel()
        var noExit = TerminalActivityModel()
        _ = nonzero.reduce(.commandFinished(exitCode: 1, at: 0))
        _ = zero.reduce(.commandFinished(exitCode: 0, at: 0))
        _ = noExit.reduce(.commandFinished(exitCode: nil, at: 0))
        #expect(nonzero.state != zero.state)
        #expect(zero.state != noExit.state)
        #expect(nonzero.state != noExit.state)
    }

    // MARK: - Suppression

    @Test func suppressedWhileActiveAndVisible() {
        var model = TerminalActivityModel()
        _ = model.reduce(.becameActiveAndVisible)
        #expect(model.reduce(.bell(at: 0)) == .quiet)
        #expect(model.reduce(.notification(at: 0)) == .quiet)
        #expect(model.reduce(.commandFinished(exitCode: 1, at: 0)) == .quiet)
    }

    // MARK: - Clearing

    @Test func userKeystrokeClearsAttention() {
        var model = TerminalActivityModel()
        _ = model.reduce(.bell(at: 0))
        #expect(model.reduce(.userKeystroke) == .quiet)
    }

    @Test func becameActiveAndVisibleClearsAttention() {
        var model = TerminalActivityModel()
        _ = model.reduce(.notification(at: 0))
        #expect(model.reduce(.becameActiveAndVisible) == .quiet)
    }

    // MARK: - resignedActiveOrHidden (closes the suppression gap left by JEF-884)

    @Test func resignedActiveOrHiddenAloneIsNoOp() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.resignedActiveOrHidden) == .quiet)
    }

    @Test func suppressionPersistsUntilResigned() {
        var model = TerminalActivityModel()
        _ = model.reduce(.becameActiveAndVisible)
        // Still suppressed: nothing raised the flag back down yet.
        #expect(model.reduce(.bell(at: 0)) == .quiet)
        _ = model.reduce(.resignedActiveOrHidden)
        // Set-then-unset restores ordinary, non-suppressed behavior.
        #expect(model.reduce(.bell(at: 1)) == .needsAttention(exitCode: nil))
    }

    @Test func resignedActiveOrHiddenDoesNotClearAlreadyRaisedAttention() {
        // Losing focus/visibility must not itself clear a pending attention
        // raised while suppressed was off — only userKeystroke and
        // becameActiveAndVisible do that (ADR 007, decision 3: attention
        // persists until the user actually attends).
        var model = TerminalActivityModel()
        _ = model.reduce(.bell(at: 0))
        #expect(model.reduce(.resignedActiveOrHidden) == .needsAttention(exitCode: nil))
    }

    @Test func heuristicRaiseWorksAgainAfterResign() {
        var model = TerminalActivityModel()
        _ = model.reduce(.becameActiveAndVisible)
        _ = model.reduce(.resignedActiveOrHidden)
        #expect(model.reduce(.outputActivity(at: 0)) == .busy)
        #expect(model.reduce(.outputActivity(at: 15)) == .busy)
        #expect(model.reduce(.quietElapsed(at: 19)) == .needsAttention(exitCode: nil))
    }

    // MARK: - Idempotence

    @Test func repeatedBellsDoNotThrash() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.bell(at: 0)) == .needsAttention(exitCode: nil))
        #expect(model.reduce(.bell(at: 1)) == .needsAttention(exitCode: nil))
        #expect(model.reduce(.bell(at: 2)) == .needsAttention(exitCode: nil))
    }

    @Test func laterExitCodePromotesExistingAttention() {
        var model = TerminalActivityModel()
        // Bell/notification/heuristic raises land before the shell reports an exit
        // code; OSC 133 D is a bonus coloring tier that arrives after (ADR 007,
        // decision 4) and should promote the already-raised state, not be discarded.
        _ = model.reduce(.bell(at: 0))
        #expect(model.reduce(.commandFinished(exitCode: 1, at: 1)) == .needsAttention(exitCode: 1))
    }

    @Test func laterNilExitDoesNotDowngradeKnownExitCode() {
        var model = TerminalActivityModel()
        _ = model.reduce(.commandFinished(exitCode: 1, at: 0))
        // A stray bell (or repeat) after the real exit code is known must not clobber
        // it back to nil.
        #expect(model.reduce(.bell(at: 1)) == .needsAttention(exitCode: 1))
    }

    // MARK: - attentionRaisedAt (ADR 007's FIFO "jump to next waiting" ordering)

    @Test func attentionRaisedAtIsNilWhileQuietOrBusy() {
        var model = TerminalActivityModel()
        #expect(model.attentionRaisedAt == nil)
        _ = model.reduce(.outputActivity(at: 0))
        #expect(model.state == .busy)
        #expect(model.attentionRaisedAt == nil)
    }

    @Test func attentionRaisedAtStampsTheRaisingEventsTimestamp() {
        var model = TerminalActivityModel()
        _ = model.reduce(.bell(at: 42))
        #expect(model.attentionRaisedAt == 42)
    }

    @Test func exitCodePromotionDoesNotResetAttentionRaisedAt() {
        // The FIFO order must reflect when attention first became pending, not when
        // OSC 133 D's bonus exit-code coloring happened to arrive (ADR 007, decision 4).
        var model = TerminalActivityModel()
        _ = model.reduce(.bell(at: 10))
        _ = model.reduce(.commandFinished(exitCode: 1, at: 99))
        #expect(model.attentionRaisedAt == 10)
    }

    @Test func repeatedRaisesDoNotAdvanceAttentionRaisedAt() {
        var model = TerminalActivityModel()
        _ = model.reduce(.bell(at: 5))
        _ = model.reduce(.bell(at: 500))
        #expect(model.attentionRaisedAt == 5)
    }

    @Test func clearingAttentionNilsOutAttentionRaisedAt() {
        var model = TerminalActivityModel()
        _ = model.reduce(.bell(at: 5))
        _ = model.reduce(.userKeystroke)
        #expect(model.attentionRaisedAt == nil)
    }

    @Test func heuristicRaiseStampsAttentionRaisedAtAtTheQuietElapsedTime() {
        var model = TerminalActivityModel()
        _ = model.reduce(.outputActivity(at: 0))
        _ = model.reduce(.outputActivity(at: 15))
        _ = model.reduce(.quietElapsed(at: 19))
        #expect(model.attentionRaisedAt == 19)
    }

    // MARK: - Output-idle heuristic

    @Test func sustainedKeystrokeFreeOutputThenQuietRaisesAttention() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.outputActivity(at: 0)) == .busy)
        #expect(model.reduce(.outputActivity(at: 15)) == .busy)
        // Busy period is 15s (>= busyThreshold), then 4s of silence (>= quietThreshold).
        #expect(model.reduce(.quietElapsed(at: 19)) == .needsAttention(exitCode: nil))
    }

    @Test func sameRunWithInterleavedKeystrokeNeverRaisesAttention() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.outputActivity(at: 0)) == .busy)
        _ = model.reduce(.userKeystroke)
        #expect(model.reduce(.outputActivity(at: 15)) == .busy)
        #expect(model.reduce(.quietElapsed(at: 19)) == .quiet)
    }

    @Test func shortBusyPeriodDoesNotRaiseAttention() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.outputActivity(at: 0)) == .busy)
        #expect(model.reduce(.outputActivity(at: 5)) == .busy)
        // Only 5s busy (< busyThreshold) even with 4s of silence after.
        #expect(model.reduce(.quietElapsed(at: 9)) == .quiet)
    }

    @Test func insufficientSilenceDoesNotRaiseAttention() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.outputActivity(at: 0)) == .busy)
        #expect(model.reduce(.outputActivity(at: 15)) == .busy)
        // Only 2s of silence (< quietThreshold).
        #expect(model.reduce(.quietElapsed(at: 17)) == .quiet)
    }

    @Test func quietElapsedWithoutPriorBusyPeriodIsNoOp() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.quietElapsed(at: 100)) == .quiet)
    }

    @Test func outputActivityDoesNotDisturbExistingAttention() {
        var model = TerminalActivityModel()
        _ = model.reduce(.bell(at: 0))
        #expect(model.reduce(.outputActivity(at: 0)) == .needsAttention(exitCode: nil))
    }

    @Test func heuristicRaiseSuppressedWhileActiveAndVisible() {
        var model = TerminalActivityModel()
        _ = model.reduce(.becameActiveAndVisible)
        #expect(model.reduce(.outputActivity(at: 0)) == .busy)
        #expect(model.reduce(.outputActivity(at: 15)) == .busy)
        #expect(model.reduce(.quietElapsed(at: 19)) == .quiet)
    }

    // MARK: - Determinism

    @Test func reducerNeverReadsWallClock() {
        // If the reducer read Date()/DispatchTime internally, this sequence of
        // caller-supplied timestamps far in the past would still behave identically —
        // there is no wall-clock dependency to desync from.
        var model = TerminalActivityModel()
        #expect(model.reduce(.outputActivity(at: -1_000_000)) == .busy)
        #expect(model.reduce(.outputActivity(at: -1_000_000 + 15)) == .busy)
        #expect(model.reduce(.quietElapsed(at: -1_000_000 + 19)) == .needsAttention(exitCode: nil))
    }
}
