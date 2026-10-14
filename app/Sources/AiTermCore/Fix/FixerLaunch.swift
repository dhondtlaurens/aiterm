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
    /// Codex's per-run hook switch (spikes: `-c 'hooks={}'` is accepted and does nothing).
    static let codexNoHooks = ["--disable", "hooks"]
    /// `workspace-write` cannot write `.git` on its own, even in a plain clone (spikes).
    static func codexGitRoot(_ clone: FixClone) -> [String] {
        ["-c", "sandbox_workspace_write.writable_roots=[\"\(clone.path)/.git\"]"]
    }

    static func modelWords(_ agent: FixerAgent, _ model: String, _ reasoning: String?) -> [String] {
        switch agent {
        case .claude: ["--model", model] + (reasoning.map { ["--effort", $0] } ?? [])
        case .codex: ["-m", model] + (reasoning.map { ["-c", "model_reasoning_effort=\($0)"] } ?? [])
        }
    }

    public static func look(_ agent: FixerAgent, model: String, reasoning: String?, clone: FixClone,
                            request: FixRequest, sessionID: String) -> FixerInvocation {
        let prompt = FixerPrompt.instructions + "\n\n" + FixerPrompt.look(request: request, clone: clone)
        switch agent {
        case .claude:
            return FixerInvocation(executable: "claude", arguments: ["-p", prompt, "--session-id", sessionID,
                "--permission-mode", "dontAsk", "--allowedTools", "Read", "Grep", "Glob"] + readOnlyGit
                + ["--output-format", "json", "--json-schema", FixerPrompt.lookSchema, "--strict-mcp-config",
                   "--settings", claudeSettings] + modelWords(agent, model, reasoning),
                environment: [:], sessionID: sessionID, answerFile: nil)
        case .codex:
            let schema = clone.path + "/.git/aiterm-look-schema.json", answer = clone.path + "/.git/aiterm-look-answer.json"
            try? FixerPrompt.lookSchema.write(toFile: schema, atomically: true, encoding: .utf8)
            return FixerInvocation(executable: "codex", arguments: ["exec", "--sandbox", "read-only", "--output-schema", schema,
                "-o", answer, "--json", "-C", clone.path] + codexNoHooks + modelWords(agent, model, reasoning) + [prompt],
                environment: [:], sessionID: nil, answerFile: answer)
        }
    }

    public static func apply(_ agent: FixerAgent, model: String, reasoning: String?, clone: FixClone,
                             proposal: FixProposal, sessionID: String) -> FixerInvocation {
        let prompt = FixerPrompt.instructions + "\n\n" + FixerPrompt.apply(proposal: proposal)
        switch agent {
        case .claude:
            let verify = proposal.verify.map { ["Bash(\($0))"] } ?? []
            return FixerInvocation(executable: "claude", arguments: ["-p", prompt, "--resume", sessionID,
                "--permission-mode", "dontAsk", "--allowedTools", "Read", "Grep", "Glob", "Edit", "Write", "Bash(git:*)"] + verify
                + ["--disallowedTools", "Bash(git push:*)", "Bash(git remote:*)", "Bash(git config:*)",
                   "--output-format", "json", "--json-schema", FixerPrompt.applySchema, "--strict-mcp-config",
                   "--settings", claudeSettings] + modelWords(agent, model, reasoning),
                environment: [:], sessionID: sessionID, answerFile: nil)
        case .codex:
            let schema = clone.path + "/.git/aiterm-apply-schema.json", answer = clone.path + "/.git/aiterm-apply-answer.json"
            try? FixerPrompt.applySchema.write(toFile: schema, atomically: true, encoding: .utf8)
            return FixerInvocation(executable: "codex", arguments: ["exec", "resume", sessionID,
                "-c", #"sandbox_mode="workspace-write""#] + codexGitRoot(clone) + ["--output-schema", schema, "-o", answer, "--json"]
                + codexNoHooks + modelWords(agent, model, reasoning) + [prompt],
                environment: [:], sessionID: sessionID, answerFile: answer)
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
            guard let file = invocation.answerFile, let data = FileManager.default.contents(atPath: file),
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
