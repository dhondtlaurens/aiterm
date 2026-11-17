import Foundation

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
