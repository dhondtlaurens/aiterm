import Foundation

/// The port the status-line shims post to. A shim runs from the app bundle on every tick of its
/// agent's status line, so the port cannot be written into it: the drivers that install a shim
/// record the port in a small file (`AiTermPaths.hookPortURL`) that the shim reads with a shell
/// builtin. A shim with no port recorded posts nothing.
public enum ShimPort {
    /// Whether `port` is what the file says, which a driver's probe asks: a shim reading another
    /// port, or none, posts to nothing, however current the agent's own config is.
    public static func isRecorded(_ port: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let text = try? String(contentsOf: AiTermPaths.hookPortURL(home: home), encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == String(port)
    }

    /// Writes `port` for the shims, unless it is there already. The support folder is made if it is
    /// missing, never migrated: renaming the user's data is launch's job.
    public static func record(_ port: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard !isRecorded(port, home: home) else { return }
        let url = AiTermPaths.hookPortURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(port)\n".utf8).write(to: url, options: .atomic)
    }
}
