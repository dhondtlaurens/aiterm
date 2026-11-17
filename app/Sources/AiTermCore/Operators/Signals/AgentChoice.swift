import Foundation

/// What is left to choose before a stage launches: the agent row among the signal's permitted rows
/// and, for a ticket linked to several projects, the project. The Operator chooses; one row and one
/// project leave nothing to choose and cost no tokens.
public enum AgentChoiceNeed: Equatable, Sendable {
    /// Nothing to choose: launch on this row.
    case ready(AgentChoice)
    /// The Operator chooses among `rows`, and among `projects` when there are several.
    case choose(rows: [AgentChoice], projects: [UUID]?)
    /// No permitted row is one the Operator can start.
    case unavailable

    /// Rows the Operator can start, in the person's list order. A saved main conversation keeps its
    /// agent: only that agent's rows are choosable, unless the signal permits none of them.
    public static func decide(permitted: [AgentChoice], projects: [UUID]?, conversationAgent: AgentKind?) -> Self {
        var rows = permitted.filter { AgentCommand.workerAgents.contains($0.agent) && !$0.model.isEmpty }
        if let agent = conversationAgent, rows.contains(where: { $0.agent == agent }) { rows = rows.filter { $0.agent == agent } }
        guard let only = rows.first else { return .unavailable }
        let candidates = (projects?.count ?? 0) > 1 ? projects : nil
        if rows.count == 1 && candidates == nil { return .ready(only) }
        return .choose(rows: rows, projects: candidates)
    }

    /// Only the project is open: the Operator decides it alone, without an Oracle round.
    public var isProjectOnly: Bool {
        if case .choose(let rows, let projects) = self { return rows.count == 1 && projects != nil }
        return false
    }

    /// The row a stage takes after three rounds of disagreement: the first in the person's order.
    public var fallback: AgentChoice? {
        switch self {
        case .ready(let row): row
        case .choose(let rows, _): rows.first
        case .unavailable: nil
        }
    }

    /// The reason a task blocks when no permitted row can start.
    public static let unavailableReason = "This signal permits no agent row the Operator can start."
}

/// The row and project a stage was given, why, and how that was decided. run_status shows it.
public struct AgentChoiceRecord: Codable, Equatable, Sendable {
    public enum Decided: OpenStringEnum, Hashable, Sendable {
        /// The Oracle agreed with the Operator's proposal.
        case oracleAgreed
        /// The Oracle is off, so the Operator's proposal applied.
        case oracleOff
        /// The Oracle could not give a clear verdict, so the Operator's proposal applied.
        case oracleUnavailable
        /// Three rounds ended in disagreement: the first permitted row applied.
        case disagreed
        /// Only the project was open; the Operator decided it alone.
        case operatorAlone
        case unknown(String)
        static let knownCases: [Self] = [.oracleAgreed, .oracleOff, .oracleUnavailable, .disagreed, .operatorAlone]
        var savedName: String {
            switch self {
            case .oracleAgreed: "oracleAgreed"
            case .oracleOff: "oracleOff"
            case .oracleUnavailable: "oracleUnavailable"
            case .disagreed: "disagreed"
            case .operatorAlone: "operatorAlone"
            case .unknown(let value): value
            }
        }
    }
    public var row: AgentChoice
    public var project: UUID?
    public var reason: String
    public var decided: Decided
    /// The Oracle round that settled it, when one did.
    public var round: Int?
    /// Why the Oracle was unavailable, or its last critique after a disagreement.
    public var note: String?
    public var at: Date
    /// The row AiTerm switched to at launch because of weekly usage. Only a fallback row switches.
    public var launchSwitch: AgentChoice?
    public init(row: AgentChoice, project: UUID?, reason: String, decided: Decided, round: Int?, note: String?, at: Date,
                launchSwitch: AgentChoice? = nil) {
        self.row = row; self.project = project; self.reason = reason; self.decided = decided
        self.round = round; self.note = note; self.at = at; self.launchSwitch = launchSwitch
    }

    /// The journal line for a fallback row AiTerm moved to the other agent at launch.
    public static func switchLine(_ row: AgentChoice) -> String {
        "AiTerm switched the agent row at launch to \(row.label): the fallback row's agent had reached \(ModelChoice.switchAtPercent)% weekly usage."
    }

    /// One journal line naming the row, the reason and how it was decided.
    public var journalLine: String {
        let how: String
        switch decided {
        case .oracleAgreed: how = "the Oracle agreed" + (round.map { " in round \($0)" } ?? "")
        case .oracleOff: how = "the Oracle is off, so the Operator's proposal applies"
        case .oracleUnavailable: how = "the Oracle was unavailable, so the Operator's proposal applies" + (note.map { " (\($0))" } ?? "")
        case .disagreed: how = "the Operator and the Oracle disagreed for three rounds, so the first permitted row applies"
        case .operatorAlone: how = "the Operator chose the project"
        case .unknown(let value): how = value
        }
        return "Agent row: \(row.label). Reason: \(reason) (\(how))."
    }
}

public extension TaskItem {
    /// For a stage that is about to launch: apply the only row, or wait in `choosing` for the
    /// Operator's choice of row and/or project. A stage without a startable row blocks.
    mutating func prepareLaunch(candidates: [UUID]?, at: Date) {
        guard let record = signalTask, record.phase == .launching else { return }
        switch AgentChoiceNeed.decide(permitted: record.current.configuration.agents, projects: candidates, conversationAgent: firstWorkerConversation?.agent) {
        case .ready(let row):
            agent = row.agent; model = row.model; reasoning = row.reasoning
        case .choose(let rows, let projects):
            guard var next = try? SignalTransitions.apply(.needChoice, to: record, at: at) else { return }
            next.choosableRows = rows; next.candidateProjects = projects
            signalTask = next
        case .unavailable:
            guard let next = try? SignalTransitions.apply(.block(AgentChoiceNeed.unavailableReason), to: record, at: at) else { return }
            signalTask = next
        }
    }

    /// What the Operator may choose now: a `choosing` stage's saved rows and projects, or, for a
    /// blocked stage, the rows it may resume on (its project is fixed). Nil for any other phase.
    func choiceNeed() -> AgentChoiceNeed? {
        guard let record = signalTask else { return nil }
        switch record.phase {
        case .choosing:
            guard let rows = record.choosableRows, !rows.isEmpty else { return .unavailable }
            return .choose(rows: rows, projects: record.candidateProjects)
        case .blocked:
            return AgentChoiceNeed.decide(permitted: record.current.configuration.agents, projects: nil, conversationAgent: firstWorkerConversation?.agent)
        default: return nil
        }
    }
}

public struct AgentChoice: Codable, Equatable, Hashable, Sendable {
    public var agent: AgentKind
    public var model: String
    public var reasoning: String?

    public init(agent: AgentKind, model: String, reasoning: String?) {
        self.agent = agent; self.model = model; self.reasoning = reasoning
    }

    /// The row as the brief and the tool refusals name it: "Agent · model · reasoning".
    public var label: String { [agent.displayName, model, reasoning].compactMap { $0 }.joined(separator: " · ") }
}

/// The agent and model a task starts on. The Operator may only step to a model in the
/// signal's permitted Agents rows, and it moves a task to the other agent only when the
/// planned one is close to its weekly limit.
public enum ModelChoice {
    /// The weekly use, in percent, at which new tasks move to the other agent: AiTerm's amber line.
    static let switchAt = 80
    public static var switchAtPercent: Int { switchAt }

    /// The two agents the Operator chooses between. An agent outside them never switches.
    public static let pair: [AgentKind] = [.claude, .codex]

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
