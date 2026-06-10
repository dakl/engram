import Foundation

/// Polls the shared SQLite store file (and its WAL sibling) for changes and
/// calls `onChange` whenever the file signature differs from the last poll.
///
/// Why poll instead of a SQLite update-hook: the store is shared across
/// processes (the app, the `engram` CLI, the Claude Code hooks), and a
/// SQLite update-hook only fires for writes made on its own connection. The
/// only reliable cross-process signal is the file changing on disk. We watch
/// BOTH `engram.sqlite` and `engram.sqlite-wal`: in WAL mode commits land in
/// the `-wal` file until a checkpoint folds them into the main file, so the
/// pair together catches every write.
final class StoreWatcher {
    private let fileURL: URL
    private let walURL: URL
    private let onChange: @Sendable () -> Void
    private let timer: DispatchSourceTimer
    private var lastSignature: Signature

    /// Modification date + size of both store files. Cheap to compute and
    /// changes on any write; used purely to dedup poll ticks (not a content
    /// hash). Missing files contribute zeroed fields so an absent `-wal`
    /// (post-checkpoint) doesn't crash or spuriously trigger.
    private struct Signature: Equatable {
        var mainModified: TimeInterval = 0
        var mainSize: Int64 = 0
        var walModified: TimeInterval = 0
        var walSize: Int64 = 0
    }

    init(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.fileURL = fileURL
        self.walURL = URL(fileURLWithPath: fileURL.path + "-wal")
        self.onChange = onChange

        // Capture the starting signature so the first tick doesn't fire for a
        // store that hasn't actually changed since launch.
        self.lastSignature = StoreWatcher.signature(main: fileURL, wal: walURL)

        let queue = DispatchQueue(label: "com.engram.StoreWatcher", qos: .utility)
        self.timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = StoreWatcher.signature(main: self.fileURL, wal: self.walURL)
            if current != self.lastSignature {
                self.lastSignature = current
                self.onChange()
            }
        }
        timer.resume()
    }

    private static func signature(main: URL, wal: URL) -> Signature {
        var signature = Signature()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: main.path) {
            signature.mainModified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            signature.mainSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: wal.path) {
            signature.walModified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            signature.walSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return signature
    }

    /// Cancels polling. Idempotent (DispatchSource.cancel is safe to call
    /// more than once); also invoked from `deinit`.
    func stop() {
        timer.cancel()
    }

    deinit {
        stop()
    }
}
