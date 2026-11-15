import Foundation

public struct RequestConditions: Codable, Equatable, Sendable {
    public enum Event: Codable, Hashable, Sendable, RawRepresentable {
        case reviewRequested, myRequest
        case unknown(String)
        public init?(rawValue: String) {
            switch rawValue {
            case "reviewRequested": self = .reviewRequested
            case "myRequest": self = .myRequest
            default: self = .unknown(rawValue)
            }
        }
        public var rawValue: String {
            switch self {
            case .reviewRequested: "reviewRequested"
            case .myRequest: "myRequest"
            case .unknown(let value): value
            }
        }
        public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self))! }
        public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
    }
    public var event: Event
    public var waitingOnMyReply: Bool
    public var sentBackToMe: Bool
    /// Empty means every repository the account can read. Canonical remote locations otherwise.
    public var projects: [String]
    public init(event: Event, waitingOnMyReply: Bool = true, sentBackToMe: Bool = true, projects: [String] = []) {
        self.event = event; self.waitingOnMyReply = waitingOnMyReply; self.sentBackToMe = sentBackToMe; self.projects = projects
    }
}
