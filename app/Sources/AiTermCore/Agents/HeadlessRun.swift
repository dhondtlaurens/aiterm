import Foundation

/// One headless CLI run, including its optional session and answer file.
public struct HeadlessInvocation: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var sessionID: String?
    public var answerFile: String?
}

/// Shared sandbox settings for unattended agent runs.
enum HeadlessRun {
    /// Headless runs leave an empty model to the CLI and give PI only a level it accepts.
    static func modelArguments(_ agent: AgentKind, model: String, reasoning: String?) -> [String] {
        guard !model.isEmpty else { return [] }
        let effort = agent == .pi ? reasoning.flatMap { agent.harness.fallbackEfforts.contains($0) ? $0 : nil } : reasoning
        return agent.harness.modelArguments(model: model, reasoning: effort)
    }

    /// Claude's run settings: no hooks, and its Bash sandbox with no network (spikes).
    static let claudeSettings = #"{"disableAllHooks":true,"sandbox":{"enabled":true,"allowUnsandboxedCommands":false,"network":{"allowedDomains":[]}}}"#
    /// The clone is the repository being fixed, so its own settings are not to be read: user settings only.
    static let claudeSettingSources = ["--setting-sources", "user"]
    /// Neither tool reaches the network through the sandbox, so neither is offered.
    static let claudeNoWeb = ["WebFetch", "WebSearch"]
    /// Codex's per-run hook switch (spikes: `-c 'hooks={}'` is accepted and does nothing), and no
    /// user config: its MCP servers would run outside the sandbox with network and credentials.
    /// Auth still comes from `CODEX_HOME`; the model is passed whenever there is one.
    static let codexQuiet = ["--ignore-user-config", "--disable", "hooks"]
    /// An answer file larger than this is not an answer.
    static let answerLimit = 1_000_000

    static func claude(prompt: String, allowedTools: [String], deniedTools: [String],
                       options: [String] = [], model: String, reasoning: String?) -> [String] {
        ["-p", prompt] + options + ["--permission-mode", "dontAsk", "--allowedTools"] + allowedTools
            + ["--disallowedTools"] + deniedTools + claudeNoWeb
            + ["--output-format", "json", "--strict-mcp-config", "--settings", claudeSettings]
            + claudeSettingSources + modelArguments(.claude, model: model, reasoning: reasoning)
    }

    static func codex(prompt: String, directory: String, answerFile: String,
                      model: String, reasoning: String?) -> [String] {
        ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--json", "-C", directory, "-o", answerFile]
            + codexQuiet + modelArguments(.codex, model: model, reasoning: reasoning) + [prompt]
    }
}
