import Foundation

/// What the New Task and New Review drafts share: which agent the first window runs, with which
/// model and reasoning effort, and the prompt it is handed.
public protocol AgentDraft {
    var agent: AgentKind { get set }
    var model: String { get set }
    var reasoning: String? { get set }
    var promptText: String { get set }
}

public extension AgentDraft {
    /// The model a draft opens with for `agent`: the saved app-wide default, else the last model
    /// used with that agent, else the catalogue's first (see `ModelSettings.resolve`), the catalogue
    /// being one the caller has already read.
    static func preference(for agent: AgentKind, state: AppState, catalog: [AgentModel],
                           defaults: UserDefaults = .standard) -> ModelPreference {
        ModelSettings.resolve(for: agent, catalog: catalog, remembered: state.lastModelByAgent[agent], defaults: defaults)
    }

    /// Switching model can change which reasoning levels exist (Codex publishes them per model), so
    /// a level the new model does not support is replaced by that model's default instead of being
    /// passed to the CLI as an unknown value.
    mutating func setModel(_ id: String, catalog: [AgentModel]) {
        model = id
        let picked = catalog.first { $0.id == id }
        let harness = agent.harness
        if let current = reasoning, harness.efforts(for: picked).contains(current) { return }
        reasoning = harness.defaultEffort(for: picked)
    }
}

public extension AppState {
    /// What a started task or review is remembered by, for the next draft: the agent for its
    /// project, and the model for that agent — the values `AgentDraft.preference` reads back.
    mutating func rememberChoice(_ draft: some AgentDraft, projectId: UUID) {
        lastAgentByProject[projectId] = draft.agent
        lastModelByAgent[draft.agent] = draft.model
    }
}
