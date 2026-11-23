import Foundation

public enum ItemRef: KindTaggedEnum, Equatable, Sendable {
    case ticket(SignalTicketRef)
    case mergeRequest(SignalRequestRef)
    /// A schedule's firing: no host item, only the signal and the time it was due.
    case run(SignalRunRef)
    case unknown(JSONValue)

    static func savedCase(kind: String?, value: SavedEnumValue) throws -> Self? {
        switch kind {
        case "ticket":
            return .ticket(try value.decode(SignalTicketRef.self))
        case "mergeRequest":
            return .mergeRequest(try value.decode(SignalRequestRef.self))
        case "run":
            return .run(try value.decode(SignalRunRef.self))
        default: return nil
        }
    }

    var savedCase: SavedEnumCase {
        get throws {
            switch self {
            case .ticket(let value): return .known("ticket", try JSONValue(encoding: value))
            case .mergeRequest(let value): return .known("mergeRequest", try JSONValue(encoding: value))
            case .run(let value): return .known("run", try JSONValue(encoding: value))
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
        case .run(let ref): return "run:\(ref.signal.uuidString):\(ref.at.formatted(.iso8601))"
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

/// One firing of a scheduled signal: the signal and the scheduled time, not the time it actually started.
public struct SignalRunRef: Codable, Equatable, Hashable, Sendable {
    public var signal: UUID
    public var at: Date
    public init(signal: UUID, at: Date) { self.signal = signal; self.at = at }
}

public struct SignalRequestRef: Codable, Equatable, Sendable {
    public var remote: String
    public var number: Int
    public init(remote: String, number: Int) { self.remote = remote; self.number = number }
}
