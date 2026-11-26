import Foundation

/// The user's own status line, kept when AiTerm's shim takes its place: the shim runs it and prints
/// what it prints, so the user loses nothing. Claude Code's and Antigravity's drivers each keep it as a
/// plain-text command file of their own that their shim reads on every tick, and `record` decides what
/// an install does with it.
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
    /// is how a moved bundle is repaired.
    static func record(_ before: Before, home: URL, agent: AgentKind = .claude) throws {
        let command = AiTermPaths.statusLineOriginalURL(home: home, agent: agent)
        switch before {
        case .foreign(let original):
            try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(original.utf8).write(to: command, options: .atomic)
        case .missing:
            if FileManager.default.fileExists(atPath: command.path) {
                try FileManager.default.removeItem(at: command)
            }
        case .ours:
            break
        }
    }
}
