import Foundation

public struct SignalEdge: Codable, Equatable, Sendable {
    public var from: TaskPhase
    public var to: TaskPhase
    public var stage: Int
    public var at: Date
    public init(from: TaskPhase, to: TaskPhase, stage: Int, at: Date) { self.from = from; self.to = to; self.stage = stage; self.at = at }
}
