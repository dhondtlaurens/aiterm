import Foundation

public enum ItemRef: KindTaggedEnum, Equatable, Sendable {
    case ticket(SignalTicketRef)
    case mergeRequest(SignalRequestRef)
    case unknown(JSONValue)

    static func savedCase(kind: String?, value: SavedEnumValue) throws -> Self? {
        switch kind {
        case "ticket":
            return .ticket(try value.decode(SignalTicketRef.self))
        case "mergeRequest":
            return .mergeRequest(try value.decode(SignalRequestRef.self))
        default: return nil
        }
    }

    var savedCase: SavedEnumCase {
        get throws {
            switch self {
            case .ticket(let value): return .known("ticket", try JSONValue(encoding: value))
            case .mergeRequest(let value): return .known("mergeRequest", try JSONValue(encoding: value))
            case .unknown(let value): return .unknown(value)
            }
        }
    }
}

public extension ItemRef {
    static func ticket(site: String, key: String) -> Self { .ticket(SignalTicketRef(site: site, key: key)) }
    static func request(remote: String, number: Int) -> Self { .mergeRequest(SignalRequestRef(remote: remote, number: number)) }
    var identity: String? {
        switch self {
        case .ticket(let ref):
            guard let url = URL(string: ref.site), url.host != nil else { return nil }
            return "jira:\(JiraConfig.normalizedSiteURL(url).absoluteString):\(ref.key.uppercased())"
        case .mergeRequest(let ref): return Self.repository(ref.remote).map { "request:\($0):\(ref.number)" }
        case .unknown: return nil
        }
    }
    static func repository(_ remote: String) -> String? {
        guard let parsed = RemoteURL(remote), let host = parsed.host, !parsed.path.isEmpty else { return nil }
        return host + "/" + parsed.path
    }
}

public struct SignalTicketRef: Codable, Equatable, Sendable {
    public var site: String
    public var key: String
    public init(site: String, key: String) { self.site = site; self.key = key }
}

public struct SignalRequestRef: Codable, Equatable, Sendable {
    public var remote: String
    public var number: Int
    public init(remote: String, number: Int) { self.remote = remote; self.number = number }
}
