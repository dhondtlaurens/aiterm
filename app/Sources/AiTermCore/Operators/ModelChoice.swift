import Foundation

/// The agent and model a task starts on (spec §15). The Operator may only step to a model in the
/// agent's own list in Settings › Agents, and it moves a task to the other agent only when the
/// planned one is close to its weekly limit.
public enum ModelChoice {
    public enum Refusal: Error, Equatable {
        case notInstalled(AgentKind), unknownModel(String, AgentKind), unsupportedReasoning(String, String)
    }

    /// The weekly use, in percent, at which new tasks move to the other agent: AiTerm's amber line.
    static let switchAt = 80

    /// The two agents the Operator chooses between. An agent outside them never switches.
    public static let pair: [AgentKind] = [.claude, .codex]

    /// Explicit reasoning wins. Naming the configured default preserves its configured reasoning;
    /// another model takes its catalogue fallback. The agent must be installed either way.
    public static func resolve(agent: AgentKind, requested: String?, installed: Set<AgentKind>, catalogue: [AgentModel],
                               defaultModel: (model: String, reasoning: String?), requestedReasoning: String? = nil) throws(Refusal) -> (model: String, reasoning: String?) {
        guard installed.contains(agent) else { throw .notInstalled(agent) }
        let model = requested ?? defaultModel.model
        let known = catalogue.first(where: { $0.id == model })
        if requested != nil, model != defaultModel.model, known == nil { throw .unknownModel(model, agent) }
        if let requestedReasoning, let known, !known.efforts.contains(requestedReasoning) {
            throw .unsupportedReasoning(requestedReasoning, model)
        }
        let fallback = model == defaultModel.model ? defaultModel.reasoning : known?.defaultEffort
        return (model, requestedReasoning ?? fallback)
    }

    /// Omitted fields take the first matching Agents row, in the person's list order.
    public static func row(agent: AgentKind, model: String?, reasoning: String?, in rows: [AgentChoice]) -> AgentChoice? {
        rows.first { $0.agent == agent && (model == nil || $0.model == model)
            && (reasoning == nil || $0.reasoning == reasoning) }
    }

    /// A new broadcast's weekly-use switch takes the first row on the other agent, or stays put.
    public static func launchChoice(planned: AgentChoice, pinned: Bool, weekly: [AgentKind: Int],
                                    installed: Set<AgentKind>, rows: [AgentChoice]) -> AgentChoice {
        let agent = launchAgent(planned: planned.agent, pinned: pinned, weekly: weekly, installed: installed)
        guard agent != planned.agent else { return planned }
        return rows.first { $0.agent == agent } ?? planned
    }

    /// The agent a task starts on: its planned agent, unless that agent's weekly use is at or past
    /// `switchAt`, the task isn't pinned, and the other agent is installed and under `switchAt`.
    public static func launchAgent(planned: AgentKind, pinned: Bool, weekly: [AgentKind: Int], installed: Set<AgentKind>) -> AgentKind {
        guard !pinned, pair.contains(planned), (weekly[planned] ?? 0) >= switchAt else { return planned }
        guard let other = pair.first(where: { $0 != planned }), installed.contains(other),
              (weekly[other] ?? 0) < switchAt else { return planned }
        return other
    }
}
