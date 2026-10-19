import Foundation

extension AgentCommand {
    /// The Operator's worker reopened in its worktree: its conversation resumed with the same launch
    /// flags it started with (`workerWords`), never the blanket bypass a sheet's
    /// Codex task resumes with. The CLI, its resume arguments, then the worker's options.
    public static func resumeWorker(agent: AgentKind, conversation: String, model: String, reasoning: String?) -> String {
        let words = workerWords(agent: agent, model: model, reasoning: reasoning)
        return ([agent.harness.executable] + agent.harness.resumeArguments(conversation) + words.dropFirst())
            .map(shellWord).joined(separator: " ")
    }
}
