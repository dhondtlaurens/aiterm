import Foundation

public struct SignalStage: Codable, Equatable, Sendable {
    public var signal: UUID
    public var item: ItemRef
    public var configuration: Signal?
    public var prompt: String?
    public var matchedAt: Date
    public init(signal: UUID, item: ItemRef, matchedAt: Date, configuration: Signal? = nil, prompt: String? = nil) {
        self.signal = signal; self.item = item; self.matchedAt = matchedAt
        self.configuration = configuration; self.prompt = prompt
    }
}
