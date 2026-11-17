import Foundation

/// The Oracle: another model that checks the Operator, on or off with its agent kept.
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
    public var oracle: OracleSetting
    /// Standing instructions for every signal, from Settings › Operator; empty for none.
    public var instructions: String

    public init(model: String, reasoning: String?, oracle: OracleSetting = .standard, instructions: String = "") {
        self.model = model; self.reasoning = reasoning; self.oracle = oracle; self.instructions = instructions
    }
}
