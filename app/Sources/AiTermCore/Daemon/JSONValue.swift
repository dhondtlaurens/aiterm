import Foundation

/// Any JSON value, as an operator's tool call carries its arguments and as AiTerm answers it. Integers
/// stay integers: a count routed through `Double` would not read back as one.
public indirect enum JSONValue: Codable, Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                                ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
                                ExpressibleByNilLiteral {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last })) }
    public init(nilLiteral: ()) { self = .null }

    /// `value` as JSON, dates as ISO 8601 — what an operator reads in a tool's answer.
    public init<Value: Encodable>(encoding value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    /// The value read as `type`, dates as ISO 8601.
    public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONEncoder().encode(self))
    }

    /// The member `key` of an object; nil for anything else, or a member it does not have.
    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { members[key] } else { nil }
    }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var intValue: Int? { if case .int(let v) = self { v } else { nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
}
