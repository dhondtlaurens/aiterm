import Foundation

/// Where a ticket lives: Jira, or the issues of a GitLab project on the connected host.
public enum TicketSource: Codable, Equatable, Hashable, Sendable {
    case jira
    /// An issue of the GitLab project at `project` (`ai/agentflow`).
    case gitLab(project: String)
}

/// A ticket as the New Task and New Review sheets show and prompt with it: a Jira issue, or a GitLab
/// issue. A GitLab issue's `key` is `#55`, its `status` its first label (the picker's lane column)
/// and its `issueType` its labels, from which `BranchType(issueType:)` reads the branch type.
public struct JiraTicket: Equatable, Sendable {
    public var key: String, summary: String, description: String?, issueType: String?, status: String?, url: String
    public var source: TicketSource
    /// When it last changed, for the one list both sources share; nil sorts last.
    public var updated: Date?

    public init(key: String, summary: String, description: String?, issueType: String?, status: String?, url: String,
                source: TicketSource = .jira, updated: Date? = nil) {
        self.key = key; self.summary = summary; self.description = description; self.issueType = issueType; self.status = status; self.url = url
        self.source = source; self.updated = updated
    }

    /// A GitLab issue's number, from its `#55` key; nil for a Jira ticket.
    public var issueNumber: Int? {
        guard case .gitLab = source else { return nil }
        return Int(key.drop { $0 == "#" })
    }

    /// What the branch name opens with: the Jira key, or a GitLab issue's bare number (`55`).
    public var branchKey: String { issueNumber.map(String.init) ?? key }
}

/// `SearchPicker` is generic over `Item: Identifiable`; a ticket's `key` is already unique and
/// `ForEach` keyed on it before this conformance existed. Jira keys hold a letter and issue keys
/// start with `#`, so the two sources never share one.
extension JiraTicket: Identifiable { public var id: String { key } }
