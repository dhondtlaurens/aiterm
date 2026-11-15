import Foundation

public struct Signal: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var enabled: Bool
    public var collapsed: Bool
    public var source: SignalSource
    public var work: SignalWork
    public var agents: [AgentChoice]
    public var finish: SignalFinish
    public init(id: UUID = UUID(), name: String, createdAt: Date, enabled: Bool = true, collapsed: Bool = false,
                source: SignalSource, work: SignalWork, agents: [AgentChoice], finish: SignalFinish) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.enabled = enabled; self.collapsed = collapsed
        self.source = source; self.work = work; self.agents = agents; self.finish = finish
    }
    public var isRunnable: Bool { enabled && source.isSupported && finish.isValid(for: source) }

    private enum CodingKeys: String, CodingKey { case id, name, createdAt, enabled, collapsed, source, work, agents, finish }
    public func encode(to encoder: Encoder) throws {
        // Persistence preserves unsupported records. Creation and effect boundaries validate them.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(createdAt, forKey: .createdAt)
        try c.encode(enabled, forKey: .enabled); try c.encode(collapsed, forKey: .collapsed); try c.encode(source, forKey: .source)
        try c.encode(work, forKey: .work); try c.encode(agents, forKey: .agents); try c.encode(finish, forKey: .finish)
    }
}
