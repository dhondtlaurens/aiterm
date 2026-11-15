import Foundation

public enum SignalSource: Codable, Equatable, Sendable {
    case jira(JiraConditions)
    case gitLab(RequestConditions)
    case gitHub(RequestConditions)
    case unknown(JSONValue)

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        switch raw["kind"]?.stringValue {
        case "jira":
            guard let value = raw["value"] else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing SignalSource value")) }
            self = .jira(try value.decode(JiraConditions.self))
        case "gitLab":
            guard let value = raw["value"] else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing SignalSource value")) }
            self = .gitLab(try value.decode(RequestConditions.self))
        case "gitHub":
            guard let value = raw["value"] else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing SignalSource value")) }
            self = .gitHub(try value.decode(RequestConditions.self))
        default: self = .unknown(raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        let raw: JSONValue
        switch self {
        case .jira(let value): raw = ["kind": "jira", "value": try JSONValue(encoding: value)]
        case .gitLab(let value): raw = ["kind": "gitLab", "value": try JSONValue(encoding: value)]
        case .gitHub(let value): raw = ["kind": "gitHub", "value": try JSONValue(encoding: value)]
        case .unknown(let value): raw = value
        }
        try raw.encode(to: encoder)
    }
}

public extension SignalSource {
    var isSupported: Bool {
        switch self {
        case .jira: true
        case .gitLab(let value), .gitHub(let value): value.event == .reviewRequested || value.event == .myRequest
        case .unknown: false
        }
    }
}
