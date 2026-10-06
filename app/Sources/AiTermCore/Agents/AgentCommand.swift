import Foundation

public enum AgentCommand {
    /// The longest command typed inline, in bytes. It is typed into a tab whose shell may not have
    /// started its line editor yet, and until it does the terminal is in canonical mode, where macOS
    /// holds at most 1024 bytes of input (`MAX_CANON`) and drops the rest without a word: the closing
    /// quote goes, and zsh waits at `quote>`. The margin covers the daemon's leading space and newline.
    static let inlineLimit = 1000

    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// `s` as one word of a zsh command line: as it is when it holds nothing zsh would expand or
    /// split, quoted otherwise. A model id such as `claude-fable-5-1[1m]` is a glob to zsh, and one
    /// that matches no file fails the whole line with "no matches found". `=` is safe anywhere but
    /// first, where zsh's EQUALS option expands `=name` to that command's path.
    static func shellWord(_ s: String) -> String {
        s.range(of: "^[A-Za-z0-9_@%+:,./-][A-Za-z0-9_@%+=:,./-]*$", options: .regularExpression) != nil ? s : shellQuote(s)
    }

    /// The invocation without its prompt argument — shared by `build` and `previewCommand` so the
    /// footer preview can never drift from the command that is actually run. Every word goes
    /// through `shellWord`: the model and reasoning come from catalogues the app does not write.
    static func invocation(agent: AgentKind, model: String, reasoning: String?) -> [String] {
        agent.harness.launchWords(model: model, reasoning: reasoning).map(shellWord)
    }

    /// The exact command a task would launch, built without touching the disk: a prompt that goes
    /// through the file shows the `$(cat …)` form the real build would produce, instead of
    /// pretending the prompt is inline. For the New Task footer (spec 4.4), where no worktree exists yet.
    public static func previewCommand(agent: AgentKind, model: String, reasoning: String?, prompt: String?) -> String {
        var parts = invocation(agent: agent, model: model, reasoning: reasoning)
        if let prompt = prompt.map(normalized), !prompt.isEmpty {
            parts.append(readsFromFile(prompt, after: parts) ? "\"$(cat .aiterm/first-prompt.md)\"" : shellQuote(prompt))
        }
        return parts.joined(separator: " ")
    }

    public static func build(agent: AgentKind, model: String, reasoning: String?, prompt: String?, worktreePath: String,
                             git: any GitRunning) throws -> String {
        var parts = invocation(agent: agent, model: model, reasoning: reasoning)
        if let prompt = prompt.map(normalized), !prompt.isEmpty {
            if readsFromFile(prompt, after: parts) {
                let dir = worktreePath + "/.aiterm"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try prompt.write(toFile: dir + "/first-prompt.md", atomically: true, encoding: .utf8)
                excludeAitermDirectory(worktreePath: worktreePath, git: git)
                parts.append("\"$(cat .aiterm/first-prompt.md)\"")
            } else {
                parts.append(shellQuote(prompt))
            }
        }
        return parts.joined(separator: " ")
    }

    /// A pasted Windows line ending is a newline, not the CR that would accept the line early.
    private static func normalized(_ prompt: String) -> String { prompt.replacingOccurrences(of: "\r\n", with: "\n") }

    /// Whether the command reads `prompt` from `.aiterm/first-prompt.md` instead of carrying it.
    /// An inline prompt is typed into the terminal, where quoting does not stop a control character
    /// acting as a keystroke: TAB completes, CR accepts the line, ESC, ^C, ^D, ^U, ^W, ^R and DEL
    /// edit it. Only a newline is safe — inside the quotes, zsh just continues the line. The length
    /// is the whole typed command's, `invocation` and quoting included, against `inlineLimit`.
    private static func readsFromFile(_ prompt: String, after invocation: [String]) -> Bool {
        (invocation + [shellQuote(prompt)]).joined(separator: " ").utf8.count > inlineLimit
            || prompt.unicodeScalars.contains { $0 != "\n" && ($0.value < 0x20 || $0.value == 0x7F) }
    }

    /// Ruling P3: best-effort addition of `.aiterm/` to the worktree's repository exclude file.
    /// A worktree's own `info/exclude` lives in the *common* dir, so we resolve the actual file
    /// via `git rev-parse --git-path info/exclude` run in the worktree, rather than assuming
    /// `<worktreePath>/.git/info/exclude` (which is a file, not a directory, in a worktree
    /// checkout). This must never fail command building, so every step here is best-effort:
    /// a plain (non-repo) temp directory, like the one `testLongPromptGoesToFile` uses, is fine.
    /// The resolution and the append are ``ExcludeFile``'s, shared with a new worktree's.
    private static func excludeAitermDirectory(worktreePath: String, git: any GitRunning) {
        guard let excludeURL = ExcludeFile.url(forWorktreeOrRepo: worktreePath, git: git) else { return }
        try? ExcludeFile.append(".aiterm/", to: excludeURL)
    }

    public static func composePrompt(userText: String?, ticket: JiraTicket?, appendTicket: Bool) -> String? {
        var blocks: [String] = []
        if let t = userText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { blocks.append(t) }
        if appendTicket, let ticket {
            var block = "\(ticket.key): \(ticket.summary)"
            if let d = ticket.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { block += "\n\n" + d }
            blocks.append(block)
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }
}
