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
    static func invocation(agent: AgentKind, model: String, reasoning: String?, operated: Bool = false, readOnly: Bool = false) -> [String] {
        let words = operated ? workerWords(agent: agent, model: model, reasoning: reasoning, readOnly: readOnly)
            : agent.harness.launchWords(model: model, reasoning: reasoning)
        return words.map(shellWord)
    }

    /// The agents an operator may give a task (spec §4.0): the two whose limits AiTerm can set.
    public static let operatedAgents: [AgentKind] = [.claude, .codex]

    /// What Claude workers under an operator may never do themselves: ask through a menu, which the
    /// operator cannot answer (spec §4.1), push — only AiTerm's `finish_task` pushes — or merge,
    /// which `finish_task` does through the host when the plan's end says so (spec §4.3).
    public static let operatedClaudeDenials = ["AskUserQuestion", "Bash(git push:*)", "Bash(gh pr merge:*)", "Bash(glab mr merge:*)", "Bash(gh pr create:*)", "Bash(glab mr create:*)", "Bash(gh pr ready:*)", "Bash(glab mr update:*)", "Bash(git -C * push:*)", "Bash(git * push:*)"]

    /// What a Claude review tab may never do on top of `operatedClaudeDenials`, which deny its push already: write a
    /// file, or write through git, so the commit it reviews is the one it reads. Each git command is denied in the
    /// three forms the push is: plain, after `-C <dir>`, and after any other option.
    public static let reviewClaudeDenials = ["Edit", "Write", "NotebookEdit"]
        + ["commit", "checkout", "switch", "reset", "rebase", "merge", "stash", "add"].flatMap { command in
            ["Bash(git \(command):*)", "Bash(git -C * \(command):*)", "Bash(git * \(command):*)"]
        }

    /// A worker's launch words, unquoted, when the Operator drives its task: one profile for every
    /// broadcast, whatever the slices (spec §12's worker launch profile):
    ///
    /// - Claude: its usual words, then `--disallowedTools` with `operatedClaudeDenials`, then
    ///   `--permission-mode auto`. `--disallowedTools` takes any number of values, so it is never
    ///   last: the prompt after `--permission-mode auto` would otherwise be read as one more tool. A review tab
    ///   (`readOnly`) adds `reviewClaudeDenials`.
    /// - Codex: the same `--dangerously-bypass-approvals-and-sandbox` as a task you make. A review tab launches
    ///   read-only instead (`Harness.readOnlyArguments`).
    /// - PI is not offered to the Operator (`operatedAgents`) and launches as it always does.
    /// Neither review launch removes subagents or read-only shell commands.
    public static func workerWords(agent: AgentKind, model: String, reasoning: String?, readOnly: Bool = false) -> [String] {
        let harness = agent.harness
        if readOnly, let words = harness.readOnlyLaunchWords(model: model, reasoning: reasoning) { return words }
        switch agent {
        case .claude:
            let denials = operatedClaudeDenials + (readOnly ? reviewClaudeDenials : [])
            return harness.launchWords(model: model, reasoning: reasoning) + ["--disallowedTools"] + denials + ["--permission-mode", "auto"]
        case .codex, .pi:
            return harness.launchWords(model: model, reasoning: reasoning)
        }
    }

    /// The Operator's worker reopened in its worktree: its conversation resumed with the same launch
    /// flags it started with (`workerWords`), never the blanket bypass a sheet's
    /// Codex task resumes with. The CLI, its resume arguments, then the worker's options.
    public static func resumeWorker(agent: AgentKind, conversation: String, model: String, reasoning: String?) -> String {
        let words = workerWords(agent: agent, model: model, reasoning: reasoning)
        return ([agent.harness.executable] + agent.harness.resumeArguments(conversation) + words.dropFirst())
            .map(shellWord).joined(separator: " ")
    }

    /// The command that resumes conversation `id` of `agent` in a reopened window: the CLI, its resume
    /// arguments (`Harness.resumeArguments`), then — for the agent a task was launched with — that
    /// launch's model and reasoning; an empty model is none. Every word goes through `shellWord`: the
    /// id comes from the agent's own hooks.
    public static func resume(agent: AgentKind, conversation id: String, model: String?, reasoning: String?) -> String {
        let model = model.flatMap { $0.isEmpty ? nil : $0 }
        return agent.harness.resumeWords(conversation: id, model: model, reasoning: reasoning).map(shellWord).joined(separator: " ")
    }

    /// The exact command a task would launch, built without touching the disk: a prompt that goes
    /// through the file shows the `$(command cat …)` form the real build would produce, instead of
    /// pretending the prompt is inline. For the New Task footer (spec 4.4), where no worktree exists yet.
    public static func previewCommand(agent: AgentKind, model: String, reasoning: String?, prompt: String?,
                                      operated: Bool = false) -> String {
        var parts = invocation(agent: agent, model: model, reasoning: reasoning, operated: operated)
        if let prompt = prompt.map(normalized), !prompt.isEmpty {
            parts.append(readsFromFile(prompt, after: parts) ? "\"$(command cat .aiterm/first-prompt.md)\"" : shellQuote(prompt))
        }
        return parts.joined(separator: " ")
    }

    /// `operated`: the Operator drives the task, and its worker launches with `workerWords`; false for a
    /// task you make yourself. `promptFile` names the file under `.aiterm/` a prompt that does not go inline is
    /// written to: an extra worker tab's own (`TabOpener`), so two agents started in one worktree never read
    /// each other's. It is typed into the command as it is, so it is a plain file name.
    public static func build(agent: AgentKind, model: String, reasoning: String?, prompt: String?, worktreePath: String,
                             git: any GitRunning, operated: Bool = false, readOnly: Bool = false, promptFile: String = "first-prompt.md") throws -> String {
        var parts = invocation(agent: agent, model: model, reasoning: reasoning, operated: operated, readOnly: readOnly)
        if let prompt = prompt.map(normalized), !prompt.isEmpty {
            if readsFromFile(prompt, after: parts) {
                let dir = worktreePath + "/.aiterm"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try prompt.write(toFile: dir + "/" + promptFile, atomically: true, encoding: .utf8)
                excludeAitermDirectory(worktreePath: worktreePath, git: git)
                parts.append("\"$(command cat .aiterm/\(promptFile))\"")
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

    /// Best-effort addition of `.aiterm/` to the worktree's repository exclude file.
    /// A worktree's own `info/exclude` lives in the *common* dir, so we resolve the actual file
    /// via `git rev-parse --git-path info/exclude` run in the worktree, rather than assuming
    /// `<worktreePath>/.git/info/exclude` (which is a file, not a directory, in a worktree
    /// checkout). This must never fail command building, so every step here is best-effort:
    /// a plain (non-repo) temp directory, like the one `testLongPromptGoesToFile` uses, is fine.
    /// The resolution and the append are ``ExcludeFile``'s, shared with a new worktree's.
    private static func excludeAitermDirectory(worktreePath: String, git: any GitRunning) {
        guard let excludeURL = ExcludeFile.url(forWorktreeOrRepo: worktreePath, git: git) else { return }
        Log.git.attempt("Adding .aiterm/ to \(excludeURL.path)") { try ExcludeFile.append(".aiterm/", to: excludeURL) }
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
