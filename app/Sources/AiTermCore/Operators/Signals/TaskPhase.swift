import Foundation

public enum TaskPhase: Codable, Equatable, Sendable {
    case launching
    case working
    case watching(DoneWhen)
    case blocked
    case done
    case archived
    case stopped
    case unknown(JSONValue)

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        switch raw["kind"]?.stringValue {
        case "launching": self = .launching
        case "working": self = .working
        case "watching":
            guard let value = raw["value"] else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing TaskPhase value")) }
            self = .watching(try value.decode(DoneWhen.self))
        case "blocked": self = .blocked
        case "done": self = .done
        case "archived": self = .archived
        case "stopped": self = .stopped
        default: self = .unknown(raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        let raw: JSONValue
        switch self {
        case .launching: raw = ["kind": "launching"]
        case .working: raw = ["kind": "working"]
        case .watching(let value): raw = ["kind": "watching", "value": try JSONValue(encoding: value)]
        case .blocked: raw = ["kind": "blocked"]
        case .done: raw = ["kind": "done"]
        case .archived: raw = ["kind": "archived"]
        case .stopped: raw = ["kind": "stopped"]
        case .unknown(let value): raw = value
        }
        try raw.encode(to: encoder)
    }
}

public extension TaskPhase {
    var isActive: Bool { self == .launching || self == .working }
    var canContinue: Bool {
        switch self { case .watching, .done, .archived: true; default: false }
    }
}
