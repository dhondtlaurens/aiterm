import Foundation

public struct SignalQuote: Codable, Equatable, Sendable {
    public var source: String
    public var text: String
    public init(source: String, text: String) { self.source = source; self.text = text }
}
