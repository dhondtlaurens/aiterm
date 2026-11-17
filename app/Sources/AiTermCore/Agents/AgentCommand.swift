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

    /// The invocation without its prompt argument. Model and reasoning words are shell-quoted
    /// because they come from catalogues the app does not write.
    static func invocation(agent: AgentKind, model: String, reasoning: String?, worker: Bool = false, readOnly: Bool = false, publishing: Bool = false, resuming: String? = nil) -> [String] {
        let words = worker ? workerWords(agent: agent, model: model, reasoning: reasoning, readOnly: readOnly, publishing: publishing)
            : agent.harness.launchWords(model: model, reasoning: reasoning)
        guard let resuming else { return words.map(shellWord) }
        return ([agent.harness.executable] + agent.harness.resumeArguments(resuming) + words.dropFirst()).map(shellWord)
    }

    /// The agents an operator may give a task: the two whose limits AiTerm can set.
    public static let workerAgents: [AgentKind] = [.claude, .codex]

    /// What Claude workers may not do outside a publishing stage: ask through a menu, push or change a request.
    /// A publishing stage uses `publishingClaudeDenials`; AiTerm alone merges when the signal permits it.
    public static let workerClaudeDenials = ["AskUserQuestion", "Bash(git push:*)", "Bash(gh pr merge:*)", "Bash(glab mr merge:*)", "Bash(gh pr create:*)", "Bash(glab mr create:*)", "Bash(gh pr ready:*)", "Bash(glab mr update:*)", "Bash(git -C * push:*)", "Bash(git * push:*)"]

    /// What a Claude review tab may never do on top of `workerClaudeDenials`, which deny its push already: write a
    /// file, or write through git, so the commit it reviews is the one it reads. Each git command is denied in the
    /// three forms the push is: plain, after `-C <dir>`, and after any other option.
    public static let publishingClaudeDenials = ["AskUserQuestion", "Bash(gh pr merge:*)", "Bash(glab mr merge:*)", "Bash(glab mr accept:*)", "Bash(git merge:*)"]

    public static let reviewClaudeDenials = ["Edit", "Write", "NotebookEdit"]
        + ["commit", "checkout", "switch", "reset", "rebase", "merge", "stash", "add"].flatMap { command in
            ["Bash(git \(command):*)", "Bash(git -C * \(command):*)", "Bash(git * \(command):*)"]
        }

    /// A worker's launch words, unquoted, when the Operator drives its task: one launch policy for every worker:
    ///
    /// - Claude: its usual words, then `--disallowedTools` with `workerClaudeDenials`, then
    ///   `--permission-mode auto`. `--disallowedTools` takes any number of values, so it is never
    ///   last: the prompt after `--permission-mode auto` would otherwise be read as one more tool. A review tab
    ///   (`readOnly`) adds `reviewClaudeDenials`.
    /// - Codex: the same `--dangerously-bypass-approvals-and-sandbox` as a task you make. A review tab launches
    ///   read-only instead (`codexReadOnlyLaunchWords`).
    /// - PI is not offered to the Operator (`workerAgents`) and launches as it always does.
    /// Neither review launch removes subagents or read-only shell commands.
    public static func workerWords(agent: AgentKind, model: String, reasoning: String?, readOnly: Bool = false, publishing: Bool = false) -> [String] {
        let harness = agent.harness
        switch agent {
        case .claude:
            let denials = (publishing ? publishingClaudeDenials : workerClaudeDenials) + (readOnly ? reviewClaudeDenials : [])
            return harness.launchWords(model: model, reasoning: reasoning) + ["--disallowedTools"] + denials + ["--permission-mode", "auto"]
        case .codex where readOnly:
            return harness.codexReadOnlyLaunchWords(model: model, reasoning: reasoning)
        case .codex, .pi:
            return harness.launchWords(model: model, reasoning: reasoning)
        }
    }

    /// The Operator's worker reopened in its worktree: its conversation resumed with the same launch
    /// flags it started with (`workerWords`), never the blanket bypass a sheet's
    /// Codex task resumes with. The CLI, its resume arguments, then the worker's options.
    public static func resumeWorker(agent: AgentKind, conversation: String, model: String, reasoning: String?, publishing: Bool = false) -> String {
        let words = workerWords(agent: agent, model: model, reasoning: reasoning, publishing: publishing)
        return ([agent.harness.executable] + agent.harness.resumeArguments(conversation) + words.dropFirst())
            .map(shellWord).joined(separator: " ")
    }

    /// The command that resumes conversation `id` of `agent` in a reopened window: the CLI, its resume
    /// arguments (`Harness.resumeArguments`), then — for the agent a task was launched with — that
    /// launch's model and reasoning; an empty model is none. Every word goes through `shellWord`: the
    /// id comes from the agent's own hooks.
    public static func resume(agent: AgentKind, conversation id: String, model: String?, reasoning: String?) -> String {
        let model = model.nonEmpty
        return agent.harness.resumeWords(conversation: id, model: model, reasoning: reasoning).map(shellWord).joined(separator: " ")
    }

    /// `worker`: the task is a signal's, so its worker launches with `workerWords`; false for a
    /// task you make yourself. `promptFile` names the file under `.aiterm/` a prompt that does not go inline is
    /// written to: an extra worker tab's own (`TabOpener`), so two agents started in one worktree never read
    /// each other's. It is typed into the command as it is, so it is a plain file name.
    public static func build(agent: AgentKind, model: String, reasoning: String?, prompt: String?, worktreePath: String,
                             git: any GitRunning, worker: Bool = false, readOnly: Bool = false, promptFile: String = "first-prompt.md", publishing: Bool = false, resuming: String? = nil) throws -> String {
        var parts = invocation(agent: agent, model: model, reasoning: reasoning, worker: worker, readOnly: readOnly, publishing: publishing, resuming: resuming)
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

    public static func composePrompt(userText: String?, ticket: JiraTicket?, appendTicket: Bool,
                                     request: MergeRequest? = nil, appendRequest: Bool = false) -> String? {
        let prompt = SignalWork(prompt: userText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                ticketDescription: appendTicket, requestDescription: appendRequest)
            .workerPrompt(ticket: ticket?.description, request: request?.description)
        return prompt.isEmpty ? nil : prompt
    }
}
