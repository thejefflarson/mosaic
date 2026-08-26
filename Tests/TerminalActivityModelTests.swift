import Testing
@testable import Mosaic

struct TerminalActivityModelTests {

    // MARK: - Protocol signals raise attention

    @Test func bellRaisesAttention() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.bell) == .needsAttention(exitCode: nil))
    }

    @Test func notificationRaisesAttention() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.notification) == .needsAttention(exitCode: nil))
    }

    @Test func commandFinishedCarriesExitCodeThrough() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.commandFinished(exitCode: 1)) == .needsAttention(exitCode: 1))
    }

    @Test func commandFinishedWithoutExitCodeCarriesNilThrough() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.commandFinished(exitCode: nil)) == .needsAttention(exitCode: nil))
    }

    @Test func nonzeroZeroAndNilExitAreAllDistinguished() {
        var nonzero = TerminalActivityModel()
        var zero = TerminalActivityModel()
        var noExit = TerminalActivityModel()
        _ = nonzero.reduce(.commandFinished(exitCode: 1))
        _ = zero.reduce(.commandFinished(exitCode: 0))
        _ = noExit.reduce(.commandFinished(exitCode: nil))
        #expect(nonzero.state != zero.state)
        #expect(zero.state != noExit.state)
        #expect(nonzero.state != noExit.state)
    }

    // MARK: - Suppression

    @Test func suppressedWhileActiveAndVisible() {
        var model = TerminalActivityModel()
        _ = model.reduce(.becameActiveAndVisible)
        #expect(model.reduce(.bell) == .quiet)
        #expect(model.reduce(.notification) == .quiet)
        #expect(model.reduce(.commandFinished(exitCode: 1)) == .quiet)
    }

    // MARK: - Clearing

    @Test func userKeystrokeClearsAttention() {
        var model = TerminalActivityModel()
        _ = model.reduce(.bell)
        #expect(model.reduce(.userKeystroke) == .quiet)
    }

    @Test func becameActiveAndVisibleClearsAttention() {
        var model = TerminalActivityModel()
        _ = model.reduce(.notification)
        #expect(model.reduce(.becameActiveAndVisible) == .quiet)
    }

    // MARK: - Idempotence

    @Test func repeatedBellsDoNotThrash() {
        var model = TerminalActivityModel()
        #expect(model.reduce(.bell) == .needsAttention(exitCode: nil))
        #expect(model.reduce(.bell) == .needsAttention(exitCode: nil))
        #expect(model.reduce(.bell) == .needsAttention(exitCode: nil))
    }

    @Test func laterExitCodePromotesExistingAttention() {
        var model = TerminalActivityModel()
        // Bell/notification/heuristic raises land before the shell reports an exit
        // code; OSC 133 D is a bonus coloring tier that arrives after (ADR 007,
        // decision 4) and should promote the already-raised state, not be discarded.
        _ = model.reduce(.bell)
        #expect(model.reduce(.commandFinished(exitCode: 1)) == .needsAttention(exitCode: 1))
    }

    @Test func laterNilExitDoesNotDowngradeKnownExitCode() {
        var model = TerminalActivityModel()
        _ = model.reduce(.commandFinished(exitCode: 1))
        // A stray bell (or repeat) after the real exit code is known must not clobber
        // it back to nil.
        #expect(model.reduce(.bell) == .needsAttention(exitCode: 1))
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
        _ = model.reduce(.bell)
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
