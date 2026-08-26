import AppKit
import Testing
@testable import Mosaic

/// Covers the pure state→dot mapping behind the minimap's per-terminal status dots
/// (ADR 007). Everything else in `MinimapView` — the actual `NSBezierPath` drawing —
/// is view code exercised by manual verification (see the PR description).
struct MinimapStatusDotTests {

    private let largeRect = CGSize(width: 200, height: 140)
    private let fg = NSColor.white

    // MARK: - statusDotKind

    @Test func quietDrawsNothing() {
        #expect(MinimapView.statusDotKind(for: .quiet) == .none)
    }

    @Test func busyMapsToBusyKind() {
        #expect(MinimapView.statusDotKind(for: .busy) == .busy)
    }

    @Test func needsAttentionWithNoExitCodeIsWaiting() {
        #expect(MinimapView.statusDotKind(for: .needsAttention(exitCode: nil)) == .waiting)
    }

    @Test func needsAttentionWithZeroExitCodeIsWaiting() {
        #expect(MinimapView.statusDotKind(for: .needsAttention(exitCode: 0)) == .waiting)
    }

    @Test func needsAttentionWithNonzeroExitCodeIsError() {
        #expect(MinimapView.statusDotKind(for: .needsAttention(exitCode: 1)) == .error)
    }

    // MARK: - statusDotSpec: quiet draws nothing

    @Test func quietSpecIsNil() {
        #expect(MinimapView.statusDotSpec(for: .quiet, rectSize: largeRect, foreground: fg) == nil)
    }

    // MARK: - statusDotSpec: color per ADR 007's fixed semantic palette

    @Test func waitingSpecIsAmber() {
        let spec = MinimapView.statusDotSpec(for: .needsAttention(exitCode: nil), rectSize: largeRect, foreground: fg)
        #expect(spec?.color == .systemOrange)
    }

    @Test func errorSpecIsRed() {
        let spec = MinimapView.statusDotSpec(for: .needsAttention(exitCode: 1), rectSize: largeRect, foreground: fg)
        #expect(spec?.color == .systemRed)
    }

    @Test func busySpecIsNil() {
        // Busy is no longer surfaced on the minimap (distracting); only attention shows.
        #expect(MinimapView.statusDotSpec(for: .busy, rectSize: largeRect, foreground: fg) == nil)
    }

    // MARK: - statusDotSpec: uniform size

    @Test func statusDotIsUniformSizeRegardlessOfRect() {
        let big = MinimapView.statusDotSpec(for: .needsAttention(exitCode: nil),
                                            rectSize: CGSize(width: 1000, height: 1000), foreground: fg)
        let small = MinimapView.statusDotSpec(for: .needsAttention(exitCode: nil),
                                              rectSize: CGSize(width: 8, height: 8), foreground: fg)
        #expect(big?.diameter == MinimapView.statusDotDiameter)
        #expect(small?.diameter == MinimapView.statusDotDiameter)
    }

    @Test func waitingAndErrorNeverVanish() {
        // The load-bearing signal must still draw even on a near-zero rect (ADR 007).
        let tiny = CGSize(width: 1, height: 1)
        #expect(MinimapView.statusDotSpec(for: .needsAttention(exitCode: nil), rectSize: tiny, foreground: fg) != nil)
        #expect(MinimapView.statusDotSpec(for: .needsAttention(exitCode: 1), rectSize: tiny, foreground: fg) != nil)
    }
}
