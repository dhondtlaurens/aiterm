import Foundation

/// A saved string choice whose newer names survive a read and write unchanged.
protocol OpenStringEnum: RawRepresentable, Codable where RawValue == String {
    init(rawValue: String)
    static var knownCases: [Self] { get }
    static func unknown(_ value: String) -> Self
    var savedName: String { get }
}

extension OpenStringEnum {
    public init(rawValue: String) {
        self = Self.knownCases.first { $0.savedName == rawValue } ?? Self.unknown(rawValue)
    }
    public var rawValue: String {
        savedName
    }
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}

/// The common coder for saved cases tagged with `kind` and an optional `value`.
protocol KindTaggedEnum: Codable {
    static func savedCase(kind: String?, value: SavedEnumValue) throws -> Self?
    static func unknown(_ raw: JSONValue) -> Self
    var savedCase: SavedEnumCase { get throws }
    /// The chat lifecycle keeps an undecodable known case inert, just like a newer kind.
    static var preservesInvalidValue: Bool { get }
}

extension KindTaggedEnum {
    static var preservesInvalidValue: Bool { false }

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        let value = SavedEnumValue(raw: raw["value"], type: String(describing: Self.self), codingPath: decoder.codingPath)
        do { self = try Self.savedCase(kind: raw["kind"]?.stringValue, value: value) ?? Self.unknown(raw) }
        catch {
            guard Self.preservesInvalidValue else { throw error }
            self = Self.unknown(raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        let raw: JSONValue
        switch try savedCase {
        case .known(let kind, let value):
            var fields: [String: JSONValue] = ["kind": .string(kind)]
            fields["value"] = value
            raw = .object(fields)
        case .unknown(let value): raw = value
        }
        try raw.encode(to: encoder)
    }
}

/// A known case's optional payload, with the saved type's existing missing-value error.
struct SavedEnumValue {
    let raw: JSONValue?
    let type: String
    let codingPath: [any CodingKey]

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        guard let raw else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Missing \(self.type) value"))
        }
        return try raw.decode(type)
    }
}

enum SavedEnumCase {
    case known(String, JSONValue? = nil)
    case unknown(JSONValue)
}
