import Foundation

enum FixerLaunch {
    static let readOnlyGit = ["status", "log", "diff", "show", "range-diff", "merge-base", "cherry", "rev-parse"]
        .map { "Bash(git \($0):*)" }

    /// Claude's absolute-path rule form: `//` and the path, so Edit and Write reach only the clone.
    static func claudeWriteRules(_ clone: FixClone) -> [String] {
        ["Edit(/\(clone.path)/**)", "Write(/\(clone.path)/**)"]
    }

    static func look(_ agent: FixerAgent, model: String, reasoning: String?, clone: FixClone,
                            request: FixRequest, sessionID: String) throws(FixRefusal) -> HeadlessInvocation {
        HeadlessInvocation(executable: "claude",
            arguments: HeadlessRun.claude(prompt: FixerPrompt.look(request: request, clone: clone),
                allowedTools: ["Read", "Grep", "Glob"] + readOnlyGit, deniedTools: [],
                options: ["--session-id", sessionID, "--json-schema", FixerPrompt.lookSchema,
                          "--append-system-prompt", FixerPrompt.instructions], model: model, reasoning: reasoning),
            environment: [:], sessionID: sessionID, answerFile: nil)
    }

    static func apply(_ agent: FixerAgent, model: String, reasoning: String?, clone: FixClone,
                             proposal: FixProposal, sessionID: String) throws(FixRefusal) -> HeadlessInvocation {
        let verify = proposal.verify.map { ["Bash(\($0))"] } ?? []
        return HeadlessInvocation(executable: "claude",
            arguments: HeadlessRun.claude(prompt: FixerPrompt.apply(proposal: proposal),
                allowedTools: ["Read", "Grep", "Glob"] + claudeWriteRules(clone) + ["Bash(git:*)"] + verify,
                deniedTools: ["Bash(git push:*)", "Bash(git remote:*)", "Bash(git config:*)"],
                options: ["--resume", sessionID, "--json-schema", FixerPrompt.applySchema,
                          "--append-system-prompt", FixerPrompt.instructions], model: model, reasoning: reasoning),
            environment: [:], sessionID: sessionID, answerFile: nil)
    }

    static func lookAnswer(_ agent: FixerAgent, output: ProcessOutput,
                                  invocation: HeadlessInvocation) throws(FixRefusal) -> (FixLookAnswer, sessionID: String) {
        try answer(agent, output: output, invocation: invocation)
    }

    static func applyAnswer(_ agent: FixerAgent, output: ProcessOutput,
                                   invocation: HeadlessInvocation) throws(FixRefusal) -> FixApplyAnswer {
        try answer(agent, output: output, invocation: invocation).0
    }

    /// The schema-shaped answer and the session id, wherever this agent puts them. Whether the
    /// answer is a plan is `FixLook`'s to say; this only reads the shape.
    private static func answer<Answer: Decodable>(_ agent: FixerAgent, output: ProcessOutput,
                                                  invocation: HeadlessInvocation) throws(FixRefusal) -> (Answer, sessionID: String) {
        if output.timedOut { throw .timedOut(agent) }
        guard output.status == 0 else { throw .agentExited(agent, status: output.status, stderr: output.stderr) }
        let decoder = JSONDecoder()
        // Some CLI versions return structured_output as a JSON string rather than an object.
        guard let result = try? decoder.decode(ClaudeResult<Answer>.self, from: Data(output.stdout.utf8)),
              let answer = result.structured_output?.value else { throw .unreadableAnswer(agent) }
        return (answer, result.session_id ?? invocation.sessionID ?? "")
    }

    private struct ClaudeResult<Answer: Decodable>: Decodable {
        var session_id: String?
        var structured_output: JSONAnswer<Answer>?
    }

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
