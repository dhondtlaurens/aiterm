import Foundation
import AiTermCore

// Drafts built from a catalogue read off a home, with no CLI to launch, for tests. The app reads the catalogue off the
// main actor and hands it to `initial(…catalog:)` (`AppController.prepareSheet`); these read it on
// the spot. `home` and `defaults` are required — a default of the developer's own `~/.codex` and
// `UserDefaults.standard` made a test's answer depend on the machine it ran on. A test passes
// `ScratchHome.bare` and `ScratchDefaults.make()`, or a home it filled.

extension AgentDraft {
    static func preference(for agent: AgentKind, state: AppState, home: URL, defaults: UserDefaults) -> ModelPreference {
        preference(for: agent, state: state, catalog: ModelCatalogue(home: home, runner: .nothingInstalled).read(agent).models, defaults: defaults)
    }

    mutating func setAgent(_ a: AgentKind, state: AppState, home: URL, defaults: UserDefaults) {
        agent = a
        let preference = Self.preference(for: a, state: state, home: home, defaults: defaults)
        model = preference.model
        reasoning = preference.reasoning
    }
}

extension TaskDraft {
    static func initial(project: Project, state: AppState, git: any GitRunning, home: URL, defaults: UserDefaults) -> TaskDraft {
        let agent = state.lastAgentByProject[project.id] ?? .claude
        return initial(project: project, state: state, git: git, agent: agent,
                       catalog: ModelCatalogue(home: home, runner: .nothingInstalled).read(agent).models, defaults: defaults)
    }
}

extension ReviewDraft {
    static func initial(project: Project, state: AppState, home: URL, defaults: UserDefaults) -> ReviewDraft {
        let agent = state.lastAgentByProject[project.id] ?? .claude
        return initial(state: state, agent: agent, catalog: ModelCatalogue(home: home, runner: .nothingInstalled).read(agent).models, defaults: defaults)
    }
}
