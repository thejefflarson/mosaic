import Testing
import AppKit
@testable import Mosaic

/// Docs/ADR/007-agent-attention-routing.md: the title-bar dot mirrors the terminal's
/// `ActivityState` directly and must persist while attention is unattended — no
/// self-owned fade. These tests exercise `StatusIndicatorView` (the rendering) and
/// `TitleBarView.setActivity` (the plumbing) without needing a live `TerminalWindowView`
/// or PTY. They assert on `StatusIndicatorView`'s semantic surface (`isDotHidden`,
/// `dotFillColor`, `dotShape`, `isPulsing`), not on the `CAShapeLayer` that renders it,
/// so a rendering-detail change doesn't break a test whose behavior didn't change.
@MainActor
struct TitleBarViewTests {

    private func makeIndicator() -> StatusIndicatorView {
        let view = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        view.layout()
        return view
    }

    // MARK: - quiet

    @Test func quietHidesTheDot() {
        let view = makeIndicator()
        view.activityState = .quiet
        #expect(view.isDotHidden)
    }

    // MARK: - busy

    @Test func busyShowsADimForegroundDot() {
        let view = makeIndicator()
        view.foregroundColor = .white
        view.activityState = .busy
        #expect(!view.isDotHidden)
        let expected = NSColor.white.withAlphaComponent(0.35).cgColor
        #expect(view.dotFillColor == expected)
    }

    @Test func busyDoesNotPulse() {
        let view = makeIndicator()
        view.activityState = .busy
        #expect(!view.isPulsing)
    }

    // MARK: - needsAttention: amber, no exit code / zero exit code

    @Test func needsAttentionWithNilExitCodeIsAmber() {
        let view = makeIndicator()
        view.activityState = .needsAttention(exitCode: nil)
        #expect(!view.isDotHidden)
        #expect(view.dotFillColor == NSColor.systemOrange.cgColor)
    }

    @Test func needsAttentionWithZeroExitCodeIsAmberNotGreen() {
        // ADR 007's fixed semantic palette has no distinct "success" color — a
        // finished command still needs the user's attention, so it's amber like
        // any other waiting state, not a separate green.
        let view = makeIndicator()
        view.activityState = .needsAttention(exitCode: 0)
        #expect(view.dotFillColor == NSColor.systemOrange.cgColor)
    }

    @Test func needsAttentionAmberIsDrawnAsADot() {
        let view = makeIndicator()
        view.activityState = .needsAttention(exitCode: nil)
        #expect(view.dotShape == .dot)
    }

    // MARK: - needsAttention: red triangle on nonzero exit

    @Test func needsAttentionWithNonzeroExitCodeIsRed() {
        let view = makeIndicator()
        view.activityState = .needsAttention(exitCode: 1)
        #expect(view.dotFillColor == NSColor.systemRed.cgColor)
    }

    @Test func needsAttentionErrorIsDrawnAsATriangle() {
        let view = makeIndicator()
        view.activityState = .needsAttention(exitCode: 1)
        #expect(view.dotShape == .triangle)
    }

    // MARK: - pulsing (Reduce Motion is honored by falling back to a static dot;
    // exercised indirectly here since flipping the system setting isn't available
    // in a unit test — see `busyDoesNotPulse` for the always-static state, and
    // `clearingToQuietHidesAndRemovesThePulse` for teardown).

    @Test func needsAttentionPulsesWhenMotionIsNotReduced() {
        let view = makeIndicator()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        view.activityState = .needsAttention(exitCode: nil)
        #expect(view.isPulsing)
    }

    // MARK: - clearing is instant

    @Test func clearingToQuietHidesAndRemovesThePulse() {
        let view = makeIndicator()
        view.activityState = .needsAttention(exitCode: nil)
        view.activityState = .quiet
        #expect(view.isDotHidden)
        #expect(!view.isPulsing)
    }

    // MARK: - TitleBarView plumbing

    @Test func setActivityForwardsToTheIndicator() {
        let bar = TitleBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        bar.layoutSubtreeIfNeeded()
        bar.setActivity(.needsAttention(exitCode: 1))
        // The indicator is private to TitleBarView; assert observable behavior via
        // its subview instead of reaching into TitleBarView's internals.
        let indicator = bar.subviews.compactMap { $0 as? StatusIndicatorView }.first
        #expect(indicator?.activityState == .needsAttention(exitCode: 1))
    }
}
