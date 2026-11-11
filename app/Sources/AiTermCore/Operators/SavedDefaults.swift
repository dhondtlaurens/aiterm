import Foundation

/// What a saved field reads as when a save lacks it: the value one of the two wrappers below gives it.
public protocol SavedDefault {
    associatedtype Value: Codable, Equatable, Sendable
    static var value: Value { get }
}

/// A record's field that a save may lack, read then as its default (`SavedDefault`) and always written: with synthesized
/// Codable, what `decodeIfPresent(…) ?? default` and an unconditional encode did by hand.
@propertyWrapper public struct Defaulted<Default: SavedDefault>: Codable, Equatable, Sendable {
    public var wrappedValue: Default.Value

    public init(wrappedValue: Default.Value) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws { wrappedValue = try decoder.singleValueContainer().decode(Default.Value.self) }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// A record's field read as its default when a save lacks it, and left out of the save while it is that default: a
/// record that never sets it saves as one from before it existed.
@propertyWrapper public struct OmittedWhenDefault<Default: SavedDefault>: Codable, Equatable, Sendable {
    public var wrappedValue: Default.Value

    public init(wrappedValue: Default.Value) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws { wrappedValue = try decoder.singleValueContainer().decode(Default.Value.self) }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

public extension KeyedDecodingContainer {
    /// A missing or null field is its default.
    func decode<Default>(_ type: Defaulted<Default>.Type, forKey key: Key) throws -> Defaulted<Default> {
        try decodeIfPresent(type, forKey: key) ?? Defaulted(wrappedValue: Default.value)
    }

    /// A missing or null field is its default.
    func decode<Default>(_ type: OmittedWhenDefault<Default>.Type, forKey key: Key) throws -> OmittedWhenDefault<Default> {
        try decodeIfPresent(type, forKey: key) ?? OmittedWhenDefault(wrappedValue: Default.value)
    }
}

public extension KeyedEncodingContainer {
    /// Written as its value.
    mutating func encode<Default>(_ value: Defaulted<Default>, forKey key: Key) throws {
        try encode(value.wrappedValue, forKey: key)
    }

    /// Written as its value, unless that is its default.
    mutating func encode<Default>(_ value: OmittedWhenDefault<Default>, forKey key: Key) throws {
        guard value.wrappedValue != Default.value else { return }
        try encode(value.wrappedValue, forKey: key)
    }
}

/// The defaults the Operator's records read a missing field as.
public enum SavedDefaults {
    /// An empty list.
    public enum None<Element: Codable & Equatable & Sendable>: SavedDefault { public static var value: [Element] { [] } }
    /// An empty table of keys to values.
    public enum NoEntries: SavedDefault { public static var value: [String: String] { [:] } }
    public enum False: SavedDefault { public static var value: Bool { false } }
    public enum Zero: SavedDefault { public static var value: Int { 0 } }
    /// A challenge saved before vetoes is a critique.
    public enum Critique: SavedDefault { public static var value: ChallengeKind { .critique } }
    /// A tab saved before roles does more work on its task.
    public enum Work: SavedDefault { public static var value: TabRole { .work } }
}
