import Foundation

/// The agent and model a task starts on (spec §15). The Operator may only step to a model in the
/// agent's own list in Settings › Agents, and it moves a task to the other agent only when the
/// planned one is close to its weekly limit.
public enum ModelChoice {
    public enum Refusal: Error, Equatable {
        case notInstalled(AgentKind), unknownModel(String, AgentKind)
    }

    /// The weekly use, in percent, at which new tasks move to the other agent: AiTerm's amber line.
    static let switchAt = 80

    /// The two agents the Operator chooses between. An agent outside them never switches.
    static let pair: [AgentKind] = [.claude, .codex]

    /// `requested` nil takes the agent's default. Otherwise it must be an id in `catalogue`, and its
    /// reasoning is that model's default effort. The agent must be installed either way.
    public static func resolve(agent: AgentKind, requested: String?, installed: Set<AgentKind>, catalogue: [AgentModel],
                               defaultModel: (model: String, reasoning: String?)) throws(Refusal) -> (model: String, reasoning: String?) {
        guard installed.contains(agent) else { throw .notInstalled(agent) }
        guard let requested else { return defaultModel }
        guard let known = catalogue.first(where: { $0.id == requested }) else { throw .unknownModel(requested, agent) }
        return (known.id, known.defaultEffort)
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
