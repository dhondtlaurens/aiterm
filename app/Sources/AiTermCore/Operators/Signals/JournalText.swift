import Foundation

public enum JournalText: Codable, Equatable, Sendable {
    case ours(String)
    case quoted(SignalQuote)
    case unknown(JSONValue)

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        switch raw["kind"]?.stringValue {
        case "ours":
            guard let value = raw["value"] else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing JournalText value")) }
            self = .ours(try value.decode(String.self))
        case "quoted":
            guard let value = raw["value"] else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing JournalText value")) }
            self = .quoted(try value.decode(SignalQuote.self))
        default: self = .unknown(raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        let raw: JSONValue
        switch self {
        case .ours(let value): raw = ["kind": "ours", "value": try JSONValue(encoding: value)]
        case .quoted(let value): raw = ["kind": "quoted", "value": try JSONValue(encoding: value)]
        case .unknown(let value): raw = value
        }
        try raw.encode(to: encoder)
    }
}
