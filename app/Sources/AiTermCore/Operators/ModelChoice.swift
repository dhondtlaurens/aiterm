import Foundation

/// The agent and model a task starts on (spec §15). The Operator may only step to a model in the
/// broadcast's allowed Agents rows, and it moves a task to the other agent only when the
/// planned one is close to its weekly limit.
public enum ModelChoice {
    /// The weekly use, in percent, at which new tasks move to the other agent: AiTerm's amber line.
    static let switchAt = 80

    /// The two agents the Operator chooses between. An agent outside them never switches.
    public static let pair: [AgentKind] = [.claude, .codex]

    /// Omitted fields take the first matching Agents row, in the person's list order.
    public static func row(agent: AgentKind, model: String?, reasoning: String?, in rows: [AgentChoice]) -> AgentChoice? {
        rows.first { $0.agent == agent && (model == nil || $0.model == model)
            && (reasoning == nil || $0.reasoning == reasoning) }
    }

    /// The weekly-use switch takes the first row on the other agent, or stays put.
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
