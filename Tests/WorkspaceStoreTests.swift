import Testing
import Foundation
@testable import Mosaic

/// Tests for WorkspaceStore save/flush/load contract.
///
/// Each test gets its own WorkspaceStore pointed at a fresh temp directory
/// so the real ~/Library/Application Support/Mosaic/workspace.json is
/// never touched.
struct WorkspaceStoreTests {

    private let store: WorkspaceStore
    private let tmp: URL

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicTests-\(UUID().uuidString)", isDirectory: true)
        store = WorkspaceStore(directory: tmp)
    }

    private func makeSnapshot(
        panX: CGFloat = 0,
        windows: [WorkspaceSnapshot.WindowSnapshot] = [],
        annotations: [AnnotationSnapshot] = []
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            viewport: .init(panX: panX, panY: 0, zoom: 1),
            windows: windows,
            annotations: annotations
        )
    }

    private func makeWindow(cwd: String = "/tmp") -> WorkspaceSnapshot.WindowSnapshot {
        WorkspaceSnapshot.WindowSnapshot(
            id: UUID(), x: 0, y: 0, width: 800, height: 500,
            shell: "/bin/zsh", cwd: cwd, title: "test", scrollback: nil
        )
    }

    // MARK: - Round-trip

    @Test func saveAndLoadRoundTrip() {
        let snap = makeSnapshot(panX: 42, windows: [makeWindow()])
        store.save(snap)
        store.flushSynchronously()
        let loaded = store.load()
        #expect(loaded != nil)
        #expect(loaded?.viewport.panX == 42)
        #expect(loaded?.windows.count == 1)
    }

    @Test func flushSynchronouslyDrainsQueueBeforeReturning() {
        // After flush, load must see the just-saved data (not nil or stale).
        let snap = makeSnapshot(panX: 99)
        store.save(snap)
        store.flushSynchronously()
        #expect(store.load()?.viewport.panX == 99)
    }

    @Test func multipleAsyncSavesLastOneWins() {
        store.save(makeSnapshot(panX: 1))
        store.save(makeSnapshot(panX: 2))
        store.save(makeSnapshot(panX: 3))
        store.flushSynchronously()
        // Queue is serial — the last enqueued save must be the persisted one.
        #expect(store.load()?.viewport.panX == 3)
    }

    // MARK: - Window fields

    @Test func windowFieldsPreservedThroughStore() {
        let id = UUID()
        let window = WorkspaceSnapshot.WindowSnapshot(
            id: id, x: 10, y: 20, width: 640, height: 480,
            shell: "/bin/bash", cwd: "/Users/test", title: "my term", scrollback: "line1\nline2"
        )
        store.save(makeSnapshot(windows: [window]))
        store.flushSynchronously()
        let w = store.load()?.windows.first
        #expect(w?.id == id)
        #expect(w?.x == 10)
        #expect(w?.cwd == "/Users/test")
        #expect(w?.scrollback == "line1\nline2")
    }

    // MARK: - Annotation fields

    @Test func annotationFieldsPreservedThroughStore() {
        let id = UUID()
        let annot = AnnotationSnapshot(
            id: id, kind: .stickyNote, x: 5, y: 10, width: 200, height: 150,
            content: "remember me", colorName: "pink"
        )
        store.save(makeSnapshot(annotations: [annot]))
        store.flushSynchronously()
        let a = store.load()?.annotations.first
        #expect(a?.id == id)
        #expect(a?.kind == .stickyNote)
        #expect(a?.content == "remember me")
        #expect(a?.colorName == "pink")
    }

    // MARK: - Viewport

    @Test func viewportValuesPreserved() {
        let snap = WorkspaceSnapshot(
            viewport: .init(panX: -123.5, panY: 77.25, zoom: 2.0),
            windows: []
        )
        store.save(snap)
        store.flushSynchronously()
        let vp = store.load()?.viewport
        #expect(vp?.panX == -123.5)
        #expect(vp?.panY == 77.25)
        #expect(vp?.zoom == 2.0)
    }

    // MARK: - Failure paths

    private var snapshotPath: URL { tmp.appendingPathComponent("workspace.json") }

    @Test func saveSetsRestrictivePermissions() throws {
        store.save(makeSnapshot())
        store.flushSynchronously()
        let attrs = try FileManager.default.attributesOfItem(atPath: snapshotPath.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600,
                "saved workspace.json should be 0600, got \(String(perms, radix: 8))")
    }

    @Test func loadReturnsNilWhenFileMissing() {
        // Fresh store directory; no save → load is nil, no crash.
        #expect(store.load() == nil)
    }

    @Test func oversizeFileIsBackedUpAndLoadReturnsNil() throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // 65 MiB exceeds the 64 MiB cap.
        let big = Data(repeating: 0x7B, count: 65 * 1024 * 1024)
        try big.write(to: snapshotPath)

        #expect(store.load() == nil)

        let entries = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        let backups = entries.filter { $0.hasPrefix("workspace.json.corrupt-") && $0.contains("size>") }
        #expect(backups.count == 1, "expected one size> backup, found \(backups)")
        #expect(!FileManager.default.fileExists(atPath: snapshotPath.path),
                "original should be moved aside")
    }

    @Test func corruptJSONIsBackedUpAndLoadReturnsNil() throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "this is not json".data(using: .utf8)!.write(to: snapshotPath)

        #expect(store.load() == nil)

        let entries = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        let backups = entries.filter {
            $0.hasPrefix("workspace.json.corrupt-") && $0.hasSuffix("-decode")
        }
        #expect(backups.count == 1, "expected one decode backup, found \(backups)")
    }
}
