import Foundation

/// The user's own status line, kept when AiTerm's shim takes its place: the shim runs it and prints
/// what it prints, so the user loses nothing. Claude Code's driver and Grok Build's each keep one,
/// as a plain-text command file the shim reads on every tick, and decide what to do with it by the
/// same rule (`record`).
public enum StatusLineOriginal {
    /// What the agent's status line was before an install, as the driver reads it off the agent's
    /// own config.
    enum Before: Equatable {
        /// The user has none: no status line, a disabled one, or one with no command to run.
        case missing
        /// AiTerm's shim, a moved bundle's included: whatever was kept is still the user's.
        case ours
        /// The user's own command, which the shim is about to replace.
        case foreign(String)
    }

    /// Keeps what the install is about to replace, before it writes the agent's config, so a
    /// failure between the two can never leave the agent on the shim with no record of the user's
    /// own status line. A foreign command is saved; with none, the record is forgotten, or a repair
    /// would bring back a status line the user removed; behind our own shim it stays as it is, which
    /// is how a moved bundle is repaired. `legacy` is an older record of the same command that a
    /// removed status line must not leave to be migrated again.
    static func record(_ before: Before, command: URL, legacy: URL? = nil) throws {
        switch before {
        case .foreign(let original):
            try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(original.utf8).write(to: command, options: .atomic)
        case .missing:
            for url in [command] + (legacy.map { [$0] } ?? []) where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        case .ours:
            break
        }
    }

    /// Launch's half of the status-line upgrade: an install from before the shim read plain text
    /// kept only the JSON record of the user's own Claude status line, which the shim no longer
    /// parses, and nothing else reports that install as out of date. Writing its command out here
    /// keeps that status line showing without waiting for Settings' Install or Repair.
    public static func migrate(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let command = AiTermPaths.statusLineOriginalURL(home: home)
        guard !FileManager.default.fileExists(atPath: command.path),
              let data = try? Data(contentsOf: AiTermPaths.legacyStatusLineOriginalURL(home: home)),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let original = saved["command"] as? String, !original.isEmpty else { return }
        try record(.foreign(original), command: command)
    }
}
