import Foundation
import AiTermCore

/// Installed workers and their current Settings defaults, read once when a signal sheet opens.
struct SignalContext: Equatable, Sendable {
    var models: [AgentKind: [AgentModel]]
    var defaults: [AgentKind: AgentChoice]
    static func read(installed: Set<AgentKind>, models: (AgentKind) -> [AgentModel], remembered: [AgentKind: String],
                     preferences: UserDefaults) -> Self {
        var lists: [AgentKind: [AgentModel]] = [:], choices: [AgentKind: AgentChoice] = [:]
        for agent in AgentCommand.workerAgents where installed.contains(agent) {
            let list = models(agent); lists[agent] = list
            var preference = ModelSettings.resolve(for: agent, catalog: list, remembered: remembered[agent], defaults: preferences)
            if preference.model.isEmpty, let first = list.first { preference.select(first) }
            if !preference.model.isEmpty { choices[agent] = AgentChoice(agent: agent, model: preference.model, reasoning: preference.reasoning) }
        }
        return Self(models: lists, defaults: choices)
    }
}
