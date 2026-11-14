import Foundation

public struct SignalRead: Equatable, Sendable {
    public var items: [SignalItem]
    public var complete: Bool
    public var cursor: Date?
    public var full: Bool
    public var accountUser: String?
    public init(items: [SignalItem], complete: Bool, cursor: Date? = nil, full: Bool = true, accountUser: String? = nil) {
        self.items = items; self.complete = complete; self.cursor = complete ? cursor : nil; self.full = full; self.accountUser = accountUser
    }
}
