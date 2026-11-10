import Foundation

/// Empty, unique folders and paths for a test, all under one folder of this test process's own, which is removed when
/// the process exits: what a test forgets to remove is gone with the run instead of staying in the temporary directory
/// (it held 197,000 leftovers before this). A caller may still remove its own folder when its fixture ends.
public enum ScratchFolder {
    private static let rootPrefix = "aiterm-tests-"

    /// This process's folder, made on first use. The folders of test processes that died without removing theirs are
    /// swept then, off the calling thread.
    public static let root: URL = {
        let temporary = FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent(rootPrefix + String(getpid()))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: ScratchFolder.root) }
        DispatchQueue.global(qos: .utility).async { sweep(temporary) }
        return root
    }()

    /// An empty folder named from `prefix`.
    public static func make(_ prefix: String = "aiterm-test-") throws -> URL {
        let directory = path(prefix)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A path nothing is at yet, named from `prefix` and ending in `suffix`, for a file or folder the caller makes itself.
    public static func path(_ prefix: String, suffix: String = "") -> URL {
        root.appendingPathComponent(prefix + UUID().uuidString + suffix)
    }

    /// Removes the folders of test processes that no longer run: one killed or crashed never reached its `atexit`.
    private static func sweep(_ temporary: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: temporary.path) else { return }
        for name in names where name.hasPrefix(rootPrefix) {
            guard let pid = pid_t(name.dropFirst(rootPrefix.count)), pid != getpid(),
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }
}
