import Foundation
import Synchronization

/// A `UserDefaults` domain of its own, for a test, an image or a Settings sheet that must start from
/// nothing and never read or write the developer's. Its name is a path in a temporary folder, which
/// cfprefsd takes as the file to keep the domain in: a suite named like an app instead lands in
/// `~/Library/Preferences`, and cfprefsd writes it back there, if only as an empty dictionary, even
/// after `removePersistentDomain` and a deleted file. `scripts/test.sh` fails a run that leaves one
/// there. The folder goes when the process exits — at exit rather than per domain, since a domain is
/// often handed to an object that outlives the scope that made it.
public enum ScratchDefaults {
    public static func make() -> UserDefaults {
        let path = folder.appendingPathComponent(UUID().uuidString).path
        return UserDefaults(suiteName: path)!
    }

    /// Made, and its removal registered, on first use.
    private static let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-scratch-defaults-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        created.withLock { $0 = folder }
        atexit { ScratchDefaults.removeFolder() }
        return folder
    }()
    private static let created = Mutex<URL?>(nil)

    private static func removeFolder() {
        guard let folder = created.withLock({ $0 }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
