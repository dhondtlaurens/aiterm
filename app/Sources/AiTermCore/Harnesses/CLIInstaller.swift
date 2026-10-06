import Foundation

public enum CLIInstallError: Error, Equatable, LocalizedError {
    case failed(AgentKind, String)
    case timedOut(AgentKind)
    case notOnPath(AgentKind)

    public var errorDescription: String? {
        switch self {
        case .failed(_, let reason): return reason
        case .timedOut(let agent): return "The \(agent.displayName) installer did not finish in time."
        case .notOnPath(let agent):
            return "\(agent.displayName) installed, but `\(agent.harness.executable)` isn’t on your login shell’s PATH."
        }
    }
}

/// Installs a missing harness CLI the way its vendor says to, so someone with no agent at all can
/// start from AiTerm. Each is the vendor's own `curl | sh` script, never a package manager, and
/// each keeps its CLI updated itself: Claude Code's and Codex's go in `~/.local/bin`, Grok Build's
/// in `~/.grok/bin` (a link to the versioned binary it downloads). PI's may install Node.js
/// first, which it only does after asking in a terminal — there is none here, so on a Mac without
/// Node it stops and says so, and that sentence becomes the card's. Each script is its harness's
/// `installCommand`.
public enum CLIInstaller {
    /// A download and, for PI, perhaps a Node.js install: minutes, not the seconds a probe gets.
    static let timeout: TimeInterval = 600

    /// Through the same login shell `HarnessCommandRunner.live` locates CLIs with, so the installer
    /// sees the `PATH` a task window will have — Codex's adds `~/.local/bin` to a profile only when
    /// that `PATH` lacks it. Standard input is closed; Codex is also told not to ask.
    ///
    /// Under `pipefail`: a pipeline exits with its last command's status, and `sh` given nothing
    /// to run exits 0, so a download that failed would otherwise read as a finished install.
    /// `installCommand` stays what the card shows. Afterwards the runner forgets where it found
    /// CLIs: the installer may have put one somewhere new.
    static func install(_ agent: AgentKind, runner: HarnessCommandRunner) throws {
        defer { runner.forgetLocations() }
        let output = try runner.run("/bin/zsh", ["-lic", "set -o pipefail; " + agent.harness.installCommand],
                                    ["CODEX_NON_INTERACTIVE": "1"], timeout)
        if let failure = failure(agent, output) { throw failure }
    }

    static func failure(_ agent: AgentKind, _ output: ProcessOutput) -> CLIInstallError? {
        if output.timedOut { return .timedOut(agent) }
        guard output.status != 0 else { return nil }
        guard let reason = lastLine(output.stderr) ?? lastLine(output.stdout) else {
            return .failed(agent, "The installer exited with status \(output.status).")
        }
        return .failed(agent, reason)
    }

    private static func lastLine(_ text: String) -> String? {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
