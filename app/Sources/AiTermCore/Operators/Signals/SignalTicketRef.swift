import Foundation

public struct SignalTicketRef: Codable, Equatable, Sendable {
    public var site: String
    public var key: String
    public init(site: String, key: String) { self.site = site; self.key = key }
}
