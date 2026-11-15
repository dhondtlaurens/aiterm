import Foundation

public struct JiraSearchPage: Sendable {
    public var tickets: [JiraTicket]
    public var nextPageToken: String?
    public var isLast: Bool
    public var complete: Bool
}
