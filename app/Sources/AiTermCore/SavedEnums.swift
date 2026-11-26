import Foundation

/// The common coder for saved cases tagged with `kind` and an optional `value`. A kind this build does not know
/// fails the read.
protocol KindTaggedEnum: Codable {
    static func savedCase(kind: String?, value: SavedEnumValue) throws -> Self?
    var savedCase: SavedEnumCase { get throws }
}

extension KindTaggedEnum {
    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        let kind = raw["kind"]?.stringValue
        let value = SavedEnumValue(raw: raw["value"], type: String(describing: Self.self), codingPath: decoder.codingPath)
        guard let known = try Self.savedCase(kind: kind, value: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown \(String(describing: Self.self)) kind \(kind ?? "nil")"))
        }
        self = known
    }
    public func encode(to encoder: Encoder) throws {
        let saved = try savedCase
        var fields: [String: JSONValue] = ["kind": .string(saved.kind)]
        fields["value"] = saved.value
        try JSONValue.object(fields).encode(to: encoder)
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

struct SavedEnumCase {
    let kind: String
    let value: JSONValue?
    static func known(_ kind: String, _ value: JSONValue? = nil) -> Self { Self(kind: kind, value: value) }
}
