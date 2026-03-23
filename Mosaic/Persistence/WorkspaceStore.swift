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
            } catch {
                print("[WorkspaceStore] save failed: \(error)")
            }
        }
    }

    /// Block until any in-flight async save completes. Call from `applicationWillTerminate`.
    func flushSynchronously() {
        queue.sync { }
    }

    /// Load the saved snapshot synchronously.
    ///
    /// This is intentionally synchronous — it only runs once at app launch, before
    /// any concurrent work begins, so there is no queue contention risk.
    func load() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }
}
