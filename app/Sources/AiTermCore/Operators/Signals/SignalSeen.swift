import Foundation

public struct SignalSeen: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable { case baseline, started, skipped }
    public var signal: UUID
    public var item: ItemRef
    public var disposition: Disposition
    public var at: Date
    public var reason: String?
    public var isMatching: Bool
    public init(signal: UUID, item: ItemRef, disposition: Disposition, at: Date, reason: String? = nil, isMatching: Bool = true) {
        self.signal = signal; self.item = item; self.disposition = disposition; self.at = at; self.reason = reason
        self.isMatching = isMatching
    }
    public static func pruned(_ values: [Self], liveItems: Set<String>, now: Date) -> [Self] {
        values.filter { value in
            value.item.identity.map(liveItems.contains) == true || now.timeIntervalSince(value.at) <= 90 * 86400
        }
    }
}
