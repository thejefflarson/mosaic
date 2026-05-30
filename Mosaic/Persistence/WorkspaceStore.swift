import Foundation

final class WorkspaceStore: Sendable {
    static let shared = WorkspaceStore()

    private let storeURL: URL
    /// Directory where image annotation assets are stored.
    let imagesDirectory: URL
    private let queue = DispatchQueue(label: "com.jeff.Mosaic.workspace", qos: .utility)

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("workspace.json")
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        // Restrict Images/ to 0700 — pasted screenshots and dropped image
        // annotations may contain sensitive content (terminal screenshots,
        // diagrams revealing internal infrastructure). Matches workspace.json's
        // 0600 treatment for at-rest exposure in Time Machine / iCloud Drive
        // / `tar` of home dir scenarios.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                ofItemAtPath: imagesDirectory.path)
    }

    private convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        self.init(directory: support.appendingPathComponent("Mosaic", isDirectory: true))
    }

    func save(_ snapshot: WorkspaceSnapshot) {
        // Capture snapshot by value (it's a struct) — no shared mutable state.
        let url = storeURL
        queue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                // Scrollback may include secrets the user pasted/typed (.env, tokens,
                // SSH passphrases). 0600 keeps the file off backups-as-other-users
                // and out of reach of unsandboxed peer processes harvesting Application
                // Support. Same treatment is applied to stalls.log on first write.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: url.path)
            } catch {
                print("[WorkspaceStore] save failed: \(error)")
            }
        }
    }

    /// Block until any in-flight async save completes. Call from `applicationWillTerminate`.
    func flushSynchronously() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync { }
    }

    /// Refuse to decode a workspace.json larger than this. The file is read on the
    /// main thread at launch, and a tampered/corrupt multi-MB JSON would beachball.
    private static let maxSnapshotBytes = 64 * 1024 * 1024

    /// Load the saved snapshot synchronously.
    ///
    /// This is intentionally synchronous — it only runs once at app launch, before
    /// any concurrent work begins, so there is no queue contention risk.
    func load() -> WorkspaceSnapshot? {
        let path = storeURL.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        // Refuse symlinks outright — lstat reports the link's own size (well
        // under maxSnapshotBytes), so a symlink-to-huge-file would bypass the
        // size cap and beachball the main thread at launch.
        guard (st.st_mode & S_IFMT) != S_IFLNK else {
            backupBadSnapshot(reason: "symlink")
            return nil
        }
        guard st.st_size <= Self.maxSnapshotBytes else {
            backupBadSnapshot(reason: "size>\(Self.maxSnapshotBytes)")
            return nil
        }
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        do {
            return try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        } catch {
            NSLog("[WorkspaceStore] decode failed: %@ — backing up corrupt file", "\(error)")
            backupBadSnapshot(reason: "decode")
            return nil
        }
    }

    private func backupBadSnapshot(reason: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = ".corrupt-\(f.string(from: Date()))-\(reason)"
        let dest = storeURL.path + suffix
        try? FileManager.default.moveItem(atPath: storeURL.path, toPath: dest)
    }
}
