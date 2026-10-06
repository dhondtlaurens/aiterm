import Foundation

/// The user's own status line, kept when AiTerm's shim takes its place: the shim runs it and prints
/// what it prints, so the user loses nothing. Claude Code's driver and Grok Build's each keep one,
/// as a plain-text command file the shim reads on every tick.
public enum StatusLineOriginal {
    /// Launch's half of the status-line upgrade: an install from before the shim read plain text
    /// kept only the JSON record of the user's own Claude status line, which the shim no longer
    /// parses, and nothing else reports that install as out of date. Writing its command out here
    /// keeps that status line showing without waiting for Settings' Install or Repair.
    public static func migrate(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let support = home.appendingPathComponent("Library/Application Support/AiTerm")
        try migrate(from: support.appendingPathComponent("statusline-original.json"),
                    to: support.appendingPathComponent("statusline-original.cmd"))
    }

    /// Writes the command of an old JSON record out as the plain-text file the shim reads, once:
    /// a command file already there is the record, whatever the JSON says.
    static func migrate(from originalURL: URL, to commandURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: commandURL.path), let data = try? Data(contentsOf: originalURL),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try save(saved["command"] as? String, to: commandURL)
    }

    /// The agent runs the shim on every status-line tick, so the user's original command is kept
    /// as plain text the shim reads without starting an interpreter. No command, no file: the shim
    /// then prints nothing, as it does when there was never an original.
    static func save(_ command: String?, to url: URL) throws {
        if let command, !command.isEmpty { try Data(command.utf8).write(to: url, options: .atomic) }
        else { try remove(url) }
    }

    /// Forgets a record, when there is one: the user removed their own status line, and a repair
    /// must not bring an old one back.
    static func remove(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
