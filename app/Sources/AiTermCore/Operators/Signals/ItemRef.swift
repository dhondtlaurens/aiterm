import Foundation

public enum ItemRef: Codable, Equatable, Sendable {
    case ticket(SignalTicketRef)
    case mergeRequest(SignalRequestRef)
    case unknown(JSONValue)

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        switch raw["kind"]?.stringValue {
        case "ticket":
            guard let value = raw["value"] else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing ItemRef value")) }
            self = .ticket(try value.decode(SignalTicketRef.self))
        case "mergeRequest":
            guard let value = raw["value"] else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing ItemRef value")) }
            self = .mergeRequest(try value.decode(SignalRequestRef.self))
        default: self = .unknown(raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        let raw: JSONValue
        switch self {
        case .ticket(let value): raw = ["kind": "ticket", "value": try JSONValue(encoding: value)]
        case .mergeRequest(let value): raw = ["kind": "mergeRequest", "value": try JSONValue(encoding: value)]
        case .unknown(let value): raw = value
        }
        try raw.encode(to: encoder)
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
