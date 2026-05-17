import Testing
import Foundation
@testable import Mosaic

/// Containment tests for AnnotationController.containedImagePath.
///
/// A tampered workspace.json could specify an imagePath that escapes the app's
/// Images directory via `..` segments or a symlink. The validator must
/// canonicalise both sides before the prefix check.
@MainActor
struct AnnotationImagePathTests {

    /// Per-test temp directory acting as the Images root.
    let imagesDir: URL

    init() throws {
        imagesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: imagesDir)
    }

    @Test func acceptsFileInsideDirectory() {
        defer { cleanup() }
        let inside = imagesDir.appendingPathComponent("foo.png").path
        FileManager.default.createFile(atPath: inside, contents: Data())
        let resolved = AnnotationController.containedImagePath(inside, imagesDirectory: imagesDir)
        #expect(resolved != nil)
    }

    @Test func acceptsImagesRootItself() {
        defer { cleanup() }
        let resolved = AnnotationController.containedImagePath(imagesDir.path, imagesDirectory: imagesDir)
        #expect(resolved != nil)
    }

    @Test func rejectsParentTraversal() {
        defer { cleanup() }
        // `<imagesDir>/../../etc/passwd` would pass a raw hasPrefix check but
        // canonicalises to something outside the Images directory.
        let escape = imagesDir.appendingPathComponent("../../etc/passwd").path
        #expect(AnnotationController.containedImagePath(escape, imagesDirectory: imagesDir) == nil)
    }

    @Test func rejectsArbitraryAbsolutePath() {
        defer { cleanup() }
        #expect(AnnotationController.containedImagePath("/etc/passwd", imagesDirectory: imagesDir) == nil)
        #expect(AnnotationController.containedImagePath("/", imagesDirectory: imagesDir) == nil)
    }

    @Test func rejectsSiblingDirectory() {
        defer { cleanup() }
        // /tmp/mosaic-images-XXX_sibling — same prefix length but different dir.
        let sibling = imagesDir.deletingLastPathComponent()
            .appendingPathComponent(imagesDir.lastPathComponent + "_sibling")
        try? FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let path = sibling.appendingPathComponent("foo.png").path
        FileManager.default.createFile(atPath: path, contents: Data())
        #expect(AnnotationController.containedImagePath(path, imagesDirectory: imagesDir) == nil)
    }

    @Test func rejectsSymlinkOutOfDirectory() throws {
        defer { cleanup() }
        // Plant a symlink inside imagesDir pointing at an outside file. Even
        // though the link's literal path satisfies the prefix, the canonical
        // (symlink-resolved) path is outside — must be rejected.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosaic-outside-\(UUID().uuidString).png")
        FileManager.default.createFile(atPath: outside.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = imagesDir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(AnnotationController.containedImagePath(link.path, imagesDirectory: imagesDir) == nil)
    }
}
