/// A newer raw value falls back without making the whole saved state or daemon frame unreadable.
protocol LenientRawDecodable: RawRepresentable, Decodable where RawValue == String {
    static var unrecognized: Self { get }
}

extension LenientRawDecodable {
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? Self.unrecognized
    }
}
