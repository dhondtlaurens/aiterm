import Foundation

public struct SignalItem: Equatable, Sendable {
    public var item: ItemRef
    public var title: String
    public var description: String?
    public var ticket: JiraTicket?
    public var mergeRequest: MergeRequest?
    public var updated: Date?
    public var assignees: [String]
    public var changesRequested: Bool
    public init(item: ItemRef, title: String, description: String? = nil, ticket: JiraTicket? = nil,
                mergeRequest: MergeRequest? = nil, updated: Date? = nil, assignees: [String] = [], changesRequested: Bool = false) {
        self.item = item; self.title = title; self.description = description; self.ticket = ticket
        self.mergeRequest = mergeRequest; self.updated = updated; self.assignees = assignees; self.changesRequested = changesRequested
    }
}
