import Foundation

extension AgentCommand {
    /// An operator's worker reopened in its worktree: its conversation resumed with the same launch
    /// flags its operation's autonomy gave it (`workerWords`) — never the blanket bypass a sheet's
    /// Codex task resumes with. The CLI, its resume arguments, then the worker's options.
    public static func resumeWorker(agent: AgentKind, conversation: String, model: String, reasoning: String?, autonomy: Autonomy) -> String {
        let words = workerWords(agent: agent, model: model, reasoning: reasoning, autonomy: autonomy)
        return ([agent.harness.executable] + agent.harness.resumeArguments(conversation) + words.dropFirst())
            .map(shellWord).joined(separator: " ")
    }
}
