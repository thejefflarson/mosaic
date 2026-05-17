import Testing
import Foundation
@testable import Mosaic

/// Validates the AppleScript-IPC path-validation helper.
///
/// AppleScript callers must hold macOS Automation TCC permission for Mosaic,
/// but once permitted they can drive `spawn at` / `navigate to` with arbitrary
/// strings. ScriptingCwd.validate canonicalises the path, requires it to live
/// under the user's home, and rejects oversize / NUL-bearing input.
struct ScriptingCwdTests {

    /// Per-test home directory under /tmp so we don't depend on the real home
    /// having any particular structure.
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private func cleanup() { try? FileManager.default.removeItem(at: home) }

    @Test func acceptsExistingDirectoryInsideHome() throws {
        defer { cleanup() }
        let sub = home.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let resolved = ScriptingCwd.validate(sub.path, home: home)
        #expect(resolved != nil)
    }

    @Test func acceptsHomeItself() {
        defer { cleanup() }
        let resolved = ScriptingCwd.validate(home.path, home: home)
        #expect(resolved != nil)
    }

    @Test func rejectsEmpty() {
        defer { cleanup() }
        #expect(ScriptingCwd.validate("", home: home) == nil)
    }

    @Test func rejectsNULByte() {
        defer { cleanup() }
        #expect(ScriptingCwd.validate("/Users/jeff\u{00}/foo", home: home) == nil)
    }

    @Test func rejectsOversize() {
        defer { cleanup() }
        let big = "/" + String(repeating: "a", count: 5000)
        #expect(ScriptingCwd.validate(big, home: home) == nil)
    }

    @Test func rejectsNonexistent() {
        defer { cleanup() }
        let path = home.appendingPathComponent("does-not-exist").path
        #expect(ScriptingCwd.validate(path, home: home) == nil)
    }

    @Test func rejectsFileRatherThanDirectory() throws {
        defer { cleanup() }
        let file = home.appendingPathComponent("a-file")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(ScriptingCwd.validate(file.path, home: home) == nil)
    }

    @Test func rejectsPathOutsideHome() {
        defer { cleanup() }
        // /etc exists and is a directory but is not under the home root.
        #expect(ScriptingCwd.validate("/etc", home: home) == nil)
    }

    @Test func rejectsParentTraversalEscape() throws {
        defer { cleanup() }
        // home/../somewhere-outside — canonicalises out of home.
        let escape = home.appendingPathComponent("../../../").path
        #expect(ScriptingCwd.validate(escape, home: home) == nil)
    }

    @Test func tildeExpansionRespectsRealHome() {
        // `~` is expanded against the *real* process home (NSString.expandingTildeInPath
        // doesn't take a home parameter), so this test passes a real-home-rooted
        // path and validates against the real home.
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        // Skip if real home is unexpected (CI runners may have an odd HOME).
        guard FileManager.default.fileExists(atPath: realHome.path) else { return }
        let resolved = ScriptingCwd.validate("~", home: realHome)
        #expect(resolved == realHome.resolvingSymlinksInPath().standardizedFileURL.path)
    }
}
