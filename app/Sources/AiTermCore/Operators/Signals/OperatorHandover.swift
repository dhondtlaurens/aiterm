import Foundation

/// Durable handover order. Unknown future phases remain inert when an older app reads them.
public enum OperatorHandover: Codable, Equatable, Sendable {
    case closing, revoking, opening, unknown(JSONValue)
    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        switch raw["kind"]?.stringValue {
        case "closing": self = .closing
        case "revoking": self = .revoking
        case "opening": self = .opening
        default: self = .unknown(raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        let value: JSONValue
        switch self {
        case .closing: value = ["kind": "closing"]
        case .revoking: value = ["kind": "revoking"]
        case .opening: value = ["kind": "opening"]
        case .unknown(let raw): value = raw
        }
        try value.encode(to: encoder)
    }
}
