import Foundation

public struct SignalMatch: Equatable, Sendable {
    public var signal: UUID
    public var item: ItemRef
    public var project: UUID?
    public var matchedAt: Date
    public init(signal: UUID, item: ItemRef, project: UUID?, matchedAt: Date) {
        self.signal = signal; self.item = item; self.project = project; self.matchedAt = matchedAt
    }
}
