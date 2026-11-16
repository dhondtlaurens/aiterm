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
        var rows = permitted.filter { AgentCommand.operatedAgents.contains($0.agent) && !$0.model.isEmpty }
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
    public enum Decided: Codable, Hashable, Sendable, RawRepresentable {
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
        public init?(rawValue: String) {
            switch rawValue {
            case "oracleAgreed": self = .oracleAgreed
            case "oracleOff": self = .oracleOff
            case "oracleUnavailable": self = .oracleUnavailable
            case "disagreed": self = .disagreed
            case "operatorAlone": self = .operatorAlone
            default: self = .unknown(rawValue)
            }
        }
        public var rawValue: String {
            switch self {
            case .oracleAgreed: "oracleAgreed"
            case .oracleOff: "oracleOff"
            case .oracleUnavailable: "oracleUnavailable"
            case .disagreed: "disagreed"
            case .operatorAlone: "operatorAlone"
            case .unknown(let value): value
            }
        }
        public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self))! }
        public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
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
