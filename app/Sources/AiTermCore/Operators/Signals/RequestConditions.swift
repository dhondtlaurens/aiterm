import Foundation

public struct RequestConditions: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable { case reviewRequested, myRequest }
    public var event: Event
    public var waitingOnMyReply: Bool
    public var sentBackToMe: Bool
    /// Empty means every repository the account can read. Canonical remote locations otherwise.
    public var projects: [String]
    public init(event: Event, waitingOnMyReply: Bool = true, sentBackToMe: Bool = true, projects: [String] = []) {
        self.event = event; self.waitingOnMyReply = waitingOnMyReply; self.sentBackToMe = sentBackToMe; self.projects = projects
    }
}
