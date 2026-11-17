import Foundation

public struct SignalSeen: Codable, Equatable, Sendable {
    public enum Disposition: Codable, Hashable, Sendable, RawRepresentable {
        case started, skipped
        case unknown(String)
        public init?(rawValue: String) {
            switch rawValue {
            case "started": self = .started
            case "skipped": self = .skipped
            default: self = .unknown(rawValue)
            }
        }
        public var rawValue: String {
            switch self {
            case .started: "started"
            case .skipped: "skipped"
            case .unknown(let value): value
            }
        }
        public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self))! }
        public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
    }
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
