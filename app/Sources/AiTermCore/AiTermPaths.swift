import Foundation

/// The one place that knows where AiTerm keeps its files and which port the agent hooks post to.
/// Both the app and the daemon supervisor read these, so a change here cannot leave the hook
/// installer and the daemon arguing about a port, or the log and the socket in different folders.
public enum AiTermPaths {
    /// Hook HTTP receiver port (daemon plan §1). The drivers install it: the agents' hook URLs
    /// carry it, PI's extension is written with it, and the status-line shims read it from
    /// `hookPortURL` (`ShimPort`). The supervisor passes it to `aitermd run --hook-port`.
    public static let hookPort = 47821

    /// AiTerm's folder in `home`'s Application Support: state, the helper's socket and log, and the
    /// small files the status-line shims read. The shims spell the same path in shell
    /// (`StatusLineShimTests` pins that they do).
    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/AiTerm")
    }

    /// The port the status-line shims post to, one line of digits: a shim runs on every tick of its
    /// agent's status line and reads it with a shell builtin.
    public static func hookPortURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("hook-port")
    }

    /// The command of the user's own Claude Code status line, which the shim runs.
    public static func statusLineOriginalURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("statusline-original.cmd")
    }

    /// The JSON record an older install kept of it in place of `statusLineOriginalURL`, which the
    /// launch migration reads once and nothing writes any more.
    public static func legacyStatusLineOriginalURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("statusline-original.json")
    }

    /// The command of the user's own Grok Build status line, which its shim runs.
    public static func grokStatusLineOriginalURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("grok-statusline-original.cmd")
    }

    /// Called once, at launch, before loading state: a driver's install writes into the folder but
    /// never renames it. A temporary sibling makes a case-only
    /// rename work on either filesystem type. Failures propagate so startup cannot create empty
    /// state beside data it failed to migrate. Two distinct existing directories require recovery.
    @discardableResult
    public static func migrateSupportDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let preferred = supportDirectory(home: homeDirectory)
        let base = preferred.deletingLastPathComponent()
        let legacy = base.appendingPathComponent("AIterm")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: base.path) else { return preferred }
        let names = try fileManager.contentsOfDirectory(atPath: base.path)
        guard names.contains("AIterm") else { return preferred }
        guard !names.contains("AiTerm") else {
            throw NSError(domain: "com.laurensdhondt.aiterm", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Both AIterm and AiTerm data folders exist in \(base.path). Neither folder was changed."])
        }
        let temporary = base.appendingPathComponent("AiTerm-migration-\(UUID().uuidString)")
        try fileManager.moveItem(at: legacy, to: temporary)
        do {
            try fileManager.moveItem(at: temporary, to: preferred)
        } catch {
            do { try fileManager.moveItem(at: temporary, to: legacy) }
            catch {
                throw NSError(domain: "com.laurensdhondt.aiterm", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Couldn’t rename the data folder. Your data is preserved at \(temporary.path).", NSUnderlyingErrorKey: error])
            }
            throw error
        }
        return preferred
    }

    public static var socketPath: String { supportDirectory().appendingPathComponent("aitermd.sock").path }
    public static var daemonLogURL: URL { supportDirectory().appendingPathComponent("aitermd.log") }

    /// Where a downloaded update is unpacked and verified, and where the replaced app waits until
    /// the new one launches. Caches, because every file in it is disposable: launch deletes it.
    public static var updatesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.laurensdhondt.aiterm/Updates")
    }
}
