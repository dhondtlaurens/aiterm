import Foundation

public struct SignalStage: Codable, Equatable, Sendable {
    public var signal: UUID
    public var item: ItemRef
    public var matchedAt: Date
    public init(signal: UUID, item: ItemRef, matchedAt: Date) { self.signal = signal; self.item = item; self.matchedAt = matchedAt }
}
