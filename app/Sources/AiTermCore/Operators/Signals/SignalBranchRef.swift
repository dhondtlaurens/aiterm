import Foundation

public struct SignalBranchRef: Codable, Equatable, Sendable {
    public var remote: String
    public var name: String
    public init(remote: String, name: String) { self.remote = remote; self.name = name }
}
