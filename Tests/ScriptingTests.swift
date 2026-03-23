import Testing
import AppKit
@testable import Mosaic

/// Tests for the AppleScript backing methods.
///
/// Full end-to-end command dispatch (FocusTerminalCommand, OpenTerminalCommand)
/// requires the app to be running and is covered by manual testing.
/// These tests cover the URL-matching logic used by focusTerminalInDirectory
/// and the NSApplication property extensions.
struct ScriptingTests {

    // MARK: - Path matching (mirrors focusTerminalInDirectory logic)

    /// Returns true if `path` resolves to the same directory as `target`
    /// using the same normalization applied in focusTerminalInDirectory.
    private func pathMatches(_ path: String, against target: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let a = URL(fileURLWithPath: expanded,  isDirectory: true).standardized
        let b = URL(fileURLWithPath: target,    isDirectory: true).standardized
        return a == b
    }

    @Test func exactPathMatches() {
        #expect(pathMatches("/Users/jeff/project", against: "/Users/jeff/project"))
    }

    @Test func trailingSlashIsNormalized() {
        #expect(pathMatches("/Users/jeff/project/", against: "/Users/jeff/project"))
    }

    @Test func subdirectoryDoesNotMatch() {
        #expect(!pathMatches("/Users/jeff/project/src", against: "/Users/jeff/project"))
    }

    @Test func parentDoesNotMatch() {
        #expect(!pathMatches("/Users/jeff", against: "/Users/jeff/project"))
    }

    @Test func differentPathsDoNotMatch() {
        #expect(!pathMatches("/Users/jeff/a", against: "/Users/jeff/b"))
    }

    @Test func tildeExpandsToHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(pathMatches("~", against: home))
    }

    @Test func tildeSubdirectoryExpandsCorrectly() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(pathMatches("~/Documents", against: "\(home)/Documents"))
    }

    // MARK: - Application property defaults

    // workingDirectory and terminalCount are backed by CanvasViewController.
    // When accessed without a live app delegate, they return safe defaults.

    @Test @MainActor func workingDirectoryFallsBackToEmptyString() {
        // NSApp.delegate is nil in the test runner → workingDirectory should be ""
        // rather than crashing.
        #expect(NSApp.workingDirectory == "")
    }

    @Test @MainActor func terminalCountFallsBackToZero() {
        #expect(NSApp.terminalCount == 0)
    }
}
