import Foundation

public struct SignalRequestRef: Codable, Equatable, Sendable {
    public var remote: String
    public var number: Int
    public init(remote: String, number: Int) { self.remote = remote; self.number = number }
}
