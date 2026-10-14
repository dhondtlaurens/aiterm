import Foundation

/// One run of a fixer CLI, built without touching disk except Codex's schema and answer files,
/// which it can only take as paths (written into the clone's `.git`, which the clone owns).
public struct FixerInvocation: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var sessionID: String?
    public var answerFile: String?
}

public enum FixerLaunch {
    static let readOnlyGit = ["status", "log", "diff", "show", "range-diff", "merge-base", "cherry", "rev-parse"]
        .map { "Bash(git \($0):*)" }
    /// Claude's run settings: no hooks, and its Bash sandbox with no network (spikes).
    static let claudeSettings = #"{"disableAllHooks":true,"sandbox":{"enabled":true,"allowUnsandboxedCommands":false,"network":{"allowedDomains":[]}}}"#
    /// The clone is the repository being fixed, so its own settings are not to be read: user settings only.
    static let claudeSettingSources = ["--setting-sources", "user"]
    /// Neither tool reaches the network through the sandbox, so neither is offered.
    static let claudeNoWeb = ["WebFetch", "WebSearch"]
    /// Codex's per-run hook switch (spikes: `-c 'hooks={}'` is accepted and does nothing), and no
    /// user config: its MCP servers would run outside the sandbox with network and credentials.
    /// Auth still comes from `CODEX_HOME`; the model is passed whenever there is one (`modelWords`).
    static let codexQuiet = ["--ignore-user-config", "--disable", "hooks"]
    /// An answer file larger than this is not an answer.
    static let answerLimit = 1_000_000

    /// `workspace-write` cannot write `.git` on its own, even in a plain clone (spikes). The path is
    /// a TOML string, so `\` and `"` in it are escaped.
    static func codexGitRoot(_ clone: FixClone) -> [String] {
        let path = (clone.path + "/.git").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ["-c", "sandbox_workspace_write.writable_roots=[\"\(path)\"]"]
    }

    /// Claude's absolute-path rule form: `//` and the path, so Edit and Write reach only the clone.
    static func claudeWriteRules(_ clone: FixClone) -> [String] {
        ["Edit(/\(clone.path)/**)", "Write(/\(clone.path)/**)"]
    }

    /// The model and its reasoning, as each agent takes them. An empty model is the agent's own
    /// default — no card default and no model picked yet — so neither is passed: `--model ""`
    /// fails the run.
    static func modelWords(_ agent: FixerAgent, _ model: String, _ reasoning: String?) -> [String] {
        guard !model.isEmpty else { return [] }
        return switch agent {
        case .claude: ["--model", model] + (reasoning.map { ["--effort", $0] } ?? [])
        case .codex: ["-m", model] + (reasoning.map { ["-c", "model_reasoning_effort=\($0)"] } ?? [])
        }
    }

    /// Codex takes its schema and answer as paths in the clone's `.git`: the schema written, any
    /// answer left by an earlier run removed, so a run that writes none can't be read as having one.
    private static func codexFiles(_ clone: FixClone, _ phase: String, schema: String) throws(FixRefusal) -> (schema: String, answer: String) {
        let schemaFile = clone.path + "/.git/aiterm-\(phase)-schema.json", answerFile = clone.path + "/.git/aiterm-\(phase)-answer.json"
        do {
            try schema.write(toFile: schemaFile, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: answerFile) { try FileManager.default.removeItem(atPath: answerFile) }
        } catch {
            throw .cloneFailed(GitError.displayReason(of: error))
        }
        return (schemaFile, answerFile)
    }

    public static func look(_ agent: FixerAgent, model: String, reasoning: String?, clone: FixClone,
                            request: FixRequest, sessionID: String) throws(FixRefusal) -> FixerInvocation {
        let problem = FixerPrompt.look(request: request, clone: clone)
        switch agent {
        case .claude:
            return FixerInvocation(executable: "claude", arguments: ["-p", problem, "--session-id", sessionID,
                "--permission-mode", "dontAsk", "--allowedTools", "Read", "Grep", "Glob"] + readOnlyGit
                + ["--disallowedTools"] + claudeNoWeb
                + ["--output-format", "json", "--json-schema", FixerPrompt.lookSchema, "--strict-mcp-config",
                   "--settings", claudeSettings] + claudeSettingSources
                + ["--append-system-prompt", FixerPrompt.instructions] + modelWords(agent, model, reasoning),
                environment: [:], sessionID: sessionID, answerFile: nil)
        case .codex:
            let files = try codexFiles(clone, "look", schema: FixerPrompt.lookSchema)
            return FixerInvocation(executable: "codex", arguments: ["exec", "--sandbox", "read-only", "--output-schema", files.schema,
                "-o", files.answer, "--json", "-C", clone.path] + codexQuiet + modelWords(agent, model, reasoning)
                + [FixerPrompt.instructions + "\n\n" + problem],
                environment: [:], sessionID: nil, answerFile: files.answer)
        }
    }

    public static func apply(_ agent: FixerAgent, model: String, reasoning: String?, clone: FixClone,
                             proposal: FixProposal, sessionID: String) throws(FixRefusal) -> FixerInvocation {
        let plan = FixerPrompt.apply(proposal: proposal)
        switch agent {
        case .claude:
            let verify = proposal.verify.map { ["Bash(\($0))"] } ?? []
            return FixerInvocation(executable: "claude", arguments: ["-p", plan, "--resume", sessionID,
                "--permission-mode", "dontAsk", "--allowedTools", "Read", "Grep", "Glob"] + claudeWriteRules(clone) + ["Bash(git:*)"] + verify
                // The real push guard is network off and no remote in the clone; this prefix rule is bypassable.
                + ["--disallowedTools", "Bash(git push:*)", "Bash(git remote:*)", "Bash(git config:*)"] + claudeNoWeb
                + ["--output-format", "json", "--json-schema", FixerPrompt.applySchema, "--strict-mcp-config",
                   "--settings", claudeSettings] + claudeSettingSources
                + ["--append-system-prompt", FixerPrompt.instructions] + modelWords(agent, model, reasoning),
                environment: [:], sessionID: sessionID, answerFile: nil)
        case .codex:
            let files = try codexFiles(clone, "apply", schema: FixerPrompt.applySchema)
            return FixerInvocation(executable: "codex", arguments: ["exec", "resume", sessionID,
                "-c", #"sandbox_mode="workspace-write""#] + codexGitRoot(clone) + ["--output-schema", files.schema, "-o", files.answer, "--json"]
                + codexQuiet + modelWords(agent, model, reasoning) + [FixerPrompt.instructions + "\n\n" + plan],
                environment: [:], sessionID: sessionID, answerFile: files.answer)
        }
    }

    public static func lookAnswer(_ agent: FixerAgent, output: ProcessOutput,
                                  invocation: FixerInvocation) throws(FixRefusal) -> (FixLookAnswer, sessionID: String) {
        try answer(agent, output: output, invocation: invocation)
    }

    public static func applyAnswer(_ agent: FixerAgent, output: ProcessOutput,
                                   invocation: FixerInvocation) throws(FixRefusal) -> FixApplyAnswer {
        try answer(agent, output: output, invocation: invocation).0
    }

    /// The schema-shaped answer and the session id, wherever this agent puts them. Whether the
    /// answer is a plan is `FixLook`'s to say; this only reads the shape.
    private static func answer<Answer: Decodable>(_ agent: FixerAgent, output: ProcessOutput,
                                                  invocation: FixerInvocation) throws(FixRefusal) -> (Answer, sessionID: String) {
        if output.timedOut { throw .timedOut(agent) }
        guard output.status == 0 else { throw .agentExited(agent, status: output.status, stderr: output.stderr) }
        let decoder = JSONDecoder()
        switch agent {
        case .claude:
            // Spikes: the answer is `structured_output`, beside `session_id`, in the one JSON result.
            // Some versions give it as a JSON string; read that too.
            guard let result = try? decoder.decode(ClaudeResult<Answer>.self, from: Data(output.stdout.utf8)),
                  let answer = result.structured_output?.value
            else { throw .unreadableAnswer(agent) }
            return (answer, result.session_id ?? invocation.sessionID ?? "")
        case .codex:
            // The `-o` file holds just the answer; the thread is on the first event.
            guard let file = invocation.answerFile, let data = readAnswerFile(file),
                  let answer = try? decoder.decode(Answer.self, from: data)
            else { throw .unreadableAnswer(agent) }
            let thread = output.stdout.split(separator: "\n").lazy.compactMap { line -> String? in
                guard let event = try? decoder.decode(CodexEvent.self, from: Data(line.utf8)), event.type == "thread.started"
                else { return nil }
                return event.thread_id
            }.first
            guard let session = thread ?? invocation.sessionID else { throw .unreadableAnswer(agent) }
            return (answer, session)
        }
    }

    /// The file's bytes, unless it is missing or larger than `answerLimit`.
    private static func readAnswerFile(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: answerLimit + 1), data.count <= answerLimit else { return nil }
        return data
    }

    private struct ClaudeResult<Answer: Decodable>: Decodable {
        var session_id: String?
        var structured_output: JSONAnswer<Answer>?
    }

    private struct CodexEvent: Decodable { var type: String; var thread_id: String? }

    /// An answer given as an object, or as a string holding one.
    private struct JSONAnswer<Answer: Decodable>: Decodable {
        var value: Answer
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let object = try? container.decode(Answer.self) { value = object; return }
            value = try JSONDecoder().decode(Answer.self, from: Data(try container.decode(String.self).utf8))
        }
    }
}
