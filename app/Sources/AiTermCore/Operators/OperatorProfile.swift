import Foundation

// Operator preferences. Each broadcast freezes its own copy; OperatorProfileStore persists defaults.

/// What the Operator may do beyond the base (spec §5), each one switch.
public struct Slices: Codable, Equatable, Sendable {
    /// Create and update tickets in the broadcast's Jira projects.
    public var jira: Bool
    /// Involve people on a merge request: mark it ready, assign reviewers, answer their threads.
    public var review: Bool
    /// Merge when the written conditions hold, through the request or locally.
    public var merge: Bool

    public init(jira: Bool = false, review: Bool = false, merge: Bool = false) {
        self.jira = jira; self.review = review; self.merge = merge
    }

    /// The base alone: every slice off.
    public static let none = Slices()
}

/// The Oracle (spec §4.1, §8): another model that checks the Operator, on or off with its agent kept.
public struct OracleSetting: Codable, Equatable, Sendable {
    public var isOn: Bool
    public var agent: AgentKind
    public var model: String
    public var reasoning: String?

    public init(isOn: Bool, agent: AgentKind, model: String, reasoning: String?) {
        self.isOn = isOn; self.agent = agent; self.model = model; self.reasoning = reasoning
    }

    /// On, from another model family than the Claude lead.
    public static let standard = OracleSetting(isOn: true, agent: .codex, model: "gpt-6-astra", reasoning: "medium")
}

/// The Operator's profile. The lead is always Claude, so only its model and reasoning are kept.
public struct OperatorProfile: Codable, Equatable, Sendable {
    public var model: String
    public var reasoning: String?
    public var slices: Slices
    public var oracle: OracleSetting
    /// House rules for every broadcast, from Settings › Operator; empty for none.
    public var instructions: String

    public init(model: String, reasoning: String?, slices: Slices = .none, oracle: OracleSetting = .standard, instructions: String = "") {
        self.model = model; self.reasoning = reasoning; self.slices = slices; self.oracle = oracle; self.instructions = instructions
    }
}
