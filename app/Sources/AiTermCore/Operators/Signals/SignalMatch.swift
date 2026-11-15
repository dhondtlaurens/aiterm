import Foundation

public struct SignalMatch: Equatable, Sendable {
    public var signal: UUID
    public var item: ItemRef
    public var project: UUID?
    public var branch: String?
    public var matchedAt: Date
    public init(signal: UUID, item: ItemRef, project: UUID?, matchedAt: Date, branch: String? = nil) {
        self.signal = signal; self.item = item; self.project = project; self.matchedAt = matchedAt; self.branch = branch
    }
}
