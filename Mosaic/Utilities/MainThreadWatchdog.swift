import AppKit
import Foundation
import Darwin

/// Detects main-thread stalls and captures the main thread's call stack
/// in-process using Mach APIs. Works in signed/notarized builds because we
/// inspect our own threads — no `task_for_pid` against another process,
/// so no `get-task-allow` entitlement is required.
///
/// A heartbeat from main updates `lastMainHeartbeat`; a watcher on a
/// background queue compares against the current time. If the gap exceeds
/// `stallThreshold`, we suspend main briefly, snapshot its registers and
/// frame pointer, resume, then symbolicate the captured stack and append
/// it to `~/Library/Logs/Mosaic/stalls.log`.
///
/// Console: filter on "MainThreadWatchdog".
/// Stack file: `~/Library/Logs/Mosaic/stalls.log` (rolling text log).
enum MainThreadWatchdog {
    private static let stallThreshold: TimeInterval = 0.5
    private static let pingInterval: TimeInterval = 0.2
    /// Don't capture more than once per this interval — symbolisation can
    /// allocate, and we don't want a pathological self-amplifying loop where
    /// the capture itself starves main further.
    private static let captureCooldown: TimeInterval = 30

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMainHeartbeat: TimeInterval = 0
    nonisolated(unsafe) private static var lastCaptureAt: TimeInterval = 0
    nonisolated(unsafe) private static var heartbeatTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var watchdogTimer: DispatchSourceTimer?
    /// Mach port for the main thread, captured at start time. Mach send
    /// rights are reference-counted; we hold this for the app lifetime.
    nonisolated(unsafe) private static var mainThreadPort: thread_t = 0
    /// Track suspended state ourselves — DispatchSource counts suspend()/resume()
    /// and double-resume on an unsuspended source crashes the process.
    nonisolated(unsafe) private static var timersSuspended = false

    static func start() {
        guard heartbeatTimer == nil else { return }
        ensureLogsDirectory()

        // start() must be called from main. mach_thread_self returns a fresh
        // send right to the calling thread; we never deallocate it.
        precondition(Thread.isMainThread, "MainThreadWatchdog.start() must be called from main")
        mainThreadPort = mach_thread_self()
        lastMainHeartbeat = ProcessInfo.processInfo.systemUptime

        let mainTimer = DispatchSource.makeTimerSource(queue: .main)
        mainTimer.schedule(deadline: .now() + pingInterval, repeating: pingInterval, leeway: .milliseconds(50))
        mainTimer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            lock.withLock { lastMainHeartbeat = now }
        }
        mainTimer.resume()
        heartbeatTimer = mainTimer

        let watcher = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.jeff.Mosaic.watchdog", qos: .utility))
        watcher.schedule(deadline: .now() + pingInterval, repeating: pingInterval, leeway: .milliseconds(50))
        watcher.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            let (gap, shouldCapture): (TimeInterval, Bool) = lock.withLock {
                let gap = now - lastMainHeartbeat
                let capture = gap > stallThreshold && (now - lastCaptureAt) > captureCooldown
                if capture { lastCaptureAt = now }
                return (gap, capture)
            }
            guard gap > stallThreshold else { return }
            NSLog("[MainThreadWatchdog] main thread stalled for %.2fs", gap)
            if shouldCapture { captureMainStack(stallDuration: gap) }
        }
        watcher.resume()
        watchdogTimer = watcher

        // App Nap suspends main-thread timer firings while we're inactive; without
        // these observers the watcher records the entire backgrounded interval as
        // a "stall" and spams capture logs the instant the user foregrounds.
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.willResignActiveNotification,
                       object: nil, queue: .main) { _ in
            guard !timersSuspended else { return }
            timersSuspended = true
            heartbeatTimer?.suspend()
            watchdogTimer?.suspend()
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                       object: nil, queue: .main) { _ in
            guard timersSuspended else { return }
            timersSuspended = false
            let now = ProcessInfo.processInfo.systemUptime
            lock.withLock { lastMainHeartbeat = now }
            heartbeatTimer?.resume()
            watchdogTimer?.resume()
        }
    }

    private static var logFileURL: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Mosaic/stalls.log")
    }

    private static func ensureLogsDirectory() {
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }

    private static func captureMainStack(stallDuration: TimeInterval) {
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let captured: Int32 = frames.withUnsafeMutableBufferPointer { buf in
            mosaic_capture_thread_stack(mainThreadPort,
                                        buf.baseAddress,
                                        Int32(buf.count))
        }
        guard captured > 0 else {
            NSLog("[MainThreadWatchdog] capture returned 0 frames")
            return
        }

        // backtrace_symbols allocates a contiguous block we own and must free.
        let n = Int(captured)
        var lines: [String] = []
        lines.reserveCapacity(n)
        frames.withUnsafeMutableBufferPointer { buf in
            guard let symbols = backtrace_symbols(buf.baseAddress, captured) else { return }
            defer { free(symbols) }
            for i in 0..<n {
                if let cstr = symbols[i] {
                    lines.append(String(cString: cstr))
                }
            }
        }

        let stamp = Self.timestamp()
        var entry = "==== \(stamp)  stall=\(String(format: "%.2f", stallDuration))s  frames=\(n) ====\n"
        entry += lines.enumerated().map { i, s in "  \(String(format: "%2d", i))  \(s)" }.joined(separator: "\n")
        entry += "\n\n"

        appendToLog(entry)
        NSLog("[MainThreadWatchdog] captured %d-frame stack → %@", n, logFileURL.path)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    /// Cap stalls.log at 1 MiB; on overflow we roll the file aside before writing.
    private static let logSizeCap: off_t = 1 << 20

    private static func appendToLog(_ entry: String) {
        guard let data = entry.data(using: .utf8) else { return }
        let path = logFileURL.path

        // Roll over if the file already exceeds the cap (lstat to avoid following
        // a symlink that could be redirecting our writes).
        var st = stat()
        if lstat(path, &st) == 0, st.st_size > logSizeCap {
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }

        // Open with O_NOFOLLOW so a pre-planted symlink at the log path can't
        // redirect our writes (e.g. into ~/.zshrc or a LaunchAgent plist). Mode
        // 0600 keeps captured stack symbols off-limits to other users.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return write(fd, base, buf.count)
        }
    }
}
