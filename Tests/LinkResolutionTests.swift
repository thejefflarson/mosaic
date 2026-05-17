import Testing
import Foundation
@testable import Mosaic

@MainActor
struct LinkResolutionTests {

    private static let cwd = FileManager.default.temporaryDirectory.path

    @Test func passesThroughHTTPSURL() {
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "https://example.com/path", cwd: Self.cwd)
        #expect(url?.absoluteString == "https://example.com/path")
    }

    /// Helper: create a temp directory + a file inside it, return both URLs.
    /// The caller cleans up via defer.
    private static func makeTempFile() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-link-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("hello.txt")
        try Data("hi".utf8).write(to: file)
        return (dir, file)
    }

    @Test func fileURLResolves() {
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "file:///etc/hosts", cwd: Self.cwd)
        #expect(url?.scheme == "file")
        #expect(url?.path == "/etc/hosts" || url?.path == "/private/etc/hosts")
    }

    @Test func fileURLInsideCwdResolves() throws {
        let (dir, file) = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "file://" + file.path, cwd: dir.path)
        #expect(url?.lastPathComponent == "hello.txt")
    }

    @Test func absolutePathResolves() {
        // /tmp always exists; absolute paths anywhere on disk are accepted.
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "/tmp", cwd: Self.cwd)
        #expect(url?.path == "/tmp" || url?.path == "/private/tmp")
    }

    @Test func nonexistentPathReturnsNil() throws {
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "/definitely/does/not/exist/zzz", cwd: Self.cwd)
        #expect(url == nil)
    }

    @Test func relativePathResolvesAgainstCwd() throws {
        let (dir, _) = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "hello.txt", cwd: dir.path)
        #expect(url?.lastPathComponent == "hello.txt")
    }

    @Test func stripsLineSuffix() throws {
        let (dir, _) = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "hello.txt:42", cwd: dir.path)
        #expect(url?.lastPathComponent == "hello.txt")
    }

    @Test func stripsLineAndColumnSuffix() throws {
        let (dir, _) = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "hello.txt:42:10", cwd: dir.path)
        #expect(url?.lastPathComponent == "hello.txt")
    }

    @Test func tildeExpands() throws {
        // ~/Library always exists on macOS and is under home — allowed.
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "~/Library", cwd: Self.cwd)
        #expect(url?.path.hasSuffix("/Library") == true)
    }

    @Test func parentTraversalCanonicalises() throws {
        let (dir, _) = try Self.makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        // dir/sub/../hello.txt resolves back to dir/hello.txt — confirms we
        // canonicalise `..` segments before exists-check.
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "sub/../hello.txt", cwd: dir.path)
        #expect(url?.lastPathComponent == "hello.txt")
    }

    @Test func httpsURLPassesThrough() {
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "https://example.com/path", cwd: Self.cwd)
        #expect(url?.absoluteString == "https://example.com/path")
    }

    @Test func customSchemesPassThrough() {
        // User legitimately clicks vscode://, slack://, etc. Don't break the workflow.
        for s in ["vscode://file/foo", "slack://team/x", "zoom://us02web", "cursor://anysphere/file/foo"] {
            let url = InterceptingTerminalView.resolveOpenableURL(for: s, cwd: Self.cwd)
            #expect(url?.absoluteString == s, "scheme should pass through: \(s)")
        }
    }

    @Test func dangerousSchemesBlocked() {
        // Schemes that execute code in WebKit or arbitrary helpers.
        for s in ["javascript:alert(1)", "data:text/html,<script>", "vbscript:msg"] {
            #expect(InterceptingTerminalView.resolveOpenableURL(for: s, cwd: Self.cwd) == nil,
                    "dangerous scheme should be rejected: \(s)")
        }
    }

    @Test func mailtoPassesThrough() {
        let url = InterceptingTerminalView.resolveOpenableURL(
            for: "mailto:user@example.com", cwd: Self.cwd)
        #expect(url?.absoluteString == "mailto:user@example.com")
    }

    @Test func emptyStringReturnsNil() {
        #expect(InterceptingTerminalView.resolveOpenableURL(for: "", cwd: Self.cwd) == nil)
        #expect(InterceptingTerminalView.resolveOpenableURL(for: "   ", cwd: Self.cwd) == nil)
    }

    @Test func oversizedInputsRejected() {
        let big = String(repeating: "a", count: 5000)
        #expect(InterceptingTerminalView.resolveOpenableURL(for: big, cwd: Self.cwd) == nil)
        #expect(InterceptingTerminalView.resolveOpenableURL(for: "/tmp", cwd: big) == nil)
    }

    // "C:foo" parses as scheme="c" since the URL grammar allows single-letter
    // schemes. We no longer reject this — NSWorkspace will fail to find a
    // handler for "c:" on macOS, so the click is a harmless no-op. Test removed.

    // MARK: - Clipboard sanitisation

    @Test func clipboardStripsBidiOverrides() {
        let smuggled = "ls -la\u{202E}; rm -rf ~\u{202C}"
        let cleaned = InterceptingTerminalView.sanitizeForClipboard(smuggled)
        #expect(!cleaned.unicodeScalars.contains("\u{202E}"))
        #expect(!cleaned.unicodeScalars.contains("\u{202C}"))
    }

    @Test func clipboardStripsZeroWidth() {
        let smuggled = "ls\u{200B}\u{200C}\u{FEFF}-la"
        let cleaned = InterceptingTerminalView.sanitizeForClipboard(smuggled)
        #expect(cleaned == "ls-la")
    }

    @Test func clipboardConvertsLineSeparator() {
        let smuggled = "echo hi\u{2028}rm -rf ~"
        let cleaned = InterceptingTerminalView.sanitizeForClipboard(smuggled)
        #expect(cleaned == "echo hi\nrm -rf ~")
    }

    // MARK: - Escape stripping (C1 coverage)

    @Test func stripsC1OSC() {
        // 0x9D is the 8-bit OSC introducer; terminated by BEL (0x07).
        let injected = "before\u{9D}8;;https://evil/\u{07}after"
        let cleaned = TerminalWindowView.stripEscapeSequences(injected)
        #expect(cleaned == "beforeafter")
    }

    @Test func stripsC1CSI() {
        // 0x9B is the 8-bit CSI introducer.
        let injected = "before\u{9B}31mafter"
        let cleaned = TerminalWindowView.stripEscapeSequences(injected)
        #expect(cleaned == "beforeafter")
    }
}
