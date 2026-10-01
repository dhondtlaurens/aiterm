import Foundation

/// The one place that knows where AiTerm keeps its files and which port the agent hooks post to.
/// Both the app and the daemon supervisor read these, so a change here cannot leave the hook
/// installer and the daemon arguing about a port, or the log and the socket in different folders.
public enum AiTermPaths {
    /// Hook HTTP receiver port (daemon plan §1). The installer writes it into the agent configs and
    /// the supervisor passes it to `aitermd run --hook-port`.
    public static let hookPort = 47821

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AiTerm")
    }

    /// Called before loading state or installing hooks. A temporary sibling makes a case-only
    /// rename work on either filesystem type. Failures propagate so startup cannot create empty
    /// state beside data it failed to migrate. Two distinct existing directories require recovery.
    @discardableResult
    public static func migrateSupportDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let base = homeDirectory.appendingPathComponent("Library/Application Support")
        let preferred = base.appendingPathComponent("AiTerm")
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

    public static var socketPath: String { supportDirectory.appendingPathComponent("aitermd.sock").path }
    public static var daemonLogURL: URL { supportDirectory.appendingPathComponent("aitermd.log") }

    /// Where a downloaded update is unpacked and verified, and where the replaced app waits until
    /// the new one launches. Caches, because every file in it is disposable: launch deletes it.
    public static var updatesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.laurensdhondt.aiterm/Updates")
    }
}
