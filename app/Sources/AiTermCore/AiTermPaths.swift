import Foundation

/// The one place that knows where AiTerm keeps its files and which port the agent hooks post to.
/// Both the app and the daemon supervisor read these, so a change here cannot leave the hook
/// installer and the daemon arguing about a port, or the log and the socket in different folders.
public enum AiTermPaths {
    /// Hook HTTP receiver port (daemon plan §1). The drivers install it: the agents' hook URLs
    /// carry it, PI's extension is written with it, and Claude's status-line shim reads it from
    /// `hookPortURL` (`ShimPort`). The supervisor passes it to `aitermd run --hook-port`.
    public static let hookPort = 47821

    /// AiTerm's folder in `home`'s Application Support: state, the helper's socket and log, and the
    /// small files the status-line shim reads. The shim spells the same path in shell
    /// (`StatusLineShimTests` pins that it does).
    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/AiTerm")
    }

    /// The port the status-line shim posts to, one line of digits: the shim runs on every tick of
    /// Claude Code's status line and reads it with a shell builtin.
    public static func hookPortURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("hook-port")
    }

    /// The delivery check's verdicts (`daemon/tools/delivery_check.py`), which the helper reads on
    /// every delivery (`delivery.POLICY_PATH`) and Settings › Agents on every card.
    public static func deliveryPolicyURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("delivery-policy.json")
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
