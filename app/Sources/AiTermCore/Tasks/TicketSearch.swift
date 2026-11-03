import Foundation

/// The results a search found although part of it failed, and the sentence that says which part:
/// thrown so a picker shows both the rows and the line.
public struct PartialSearch<Item: Sendable>: Error, Sendable {
    public let items: [Item], message: String
    public init(items: [Item], message: String) { self.items = items; self.message = message }
}

/// The ticket picker's one search over a project's tickets: its Jira tickets as before, and the
/// issues of its GitLab project when its remote is on the connected GitLab, in one list by when
/// each last changed. A repository without open issues adds nothing, so its picker is Jira's alone.
public struct TicketSearch: Sendable {
    public typealias Source = @Sendable (String) async throws -> [JiraTicket]

    /// Nil when Jira is not connected; `jiraUnavailable` says so then.
    let jira: Source?
    let jiraUnavailable: String
    /// Nil when the project's remote is not on the connected GitLab.
    let gitLabIssues: Source?

    public init(jira: Source?, jiraUnavailable: String, gitLabIssues: Source?) {
        self.jira = jira; self.jiraUnavailable = jiraUnavailable; self.gitLabIssues = gitLabIssues
    }

    /// What GitLab failing says while Jira answered.
    public static let issuesFailed = "Couldn’t read this project’s GitLab issues. Showing Jira tickets only."

    /// Both sources at once. Jira failing while issues were found shows the issues alone, with
    /// Jira's reason unless Jira is simply not connected; GitLab failing shows Jira's with
    /// `issuesFailed`. With nothing found anywhere, Jira's failure is the answer.
    public func tickets(matching text: String) async throws -> [JiraTicket] {
        async let fromJira = attemptJira(text)
        async let fromGitLab = Self.attempt(gitLabIssues, text)
        let (jiraAnswer, gitLabAnswer) = await (fromJira, fromGitLab)

        let issues: [JiraTicket]
        var gitLabFailure: Error?
        switch gitLabAnswer {
        case .success(let found): issues = found
        case .failure(let error): issues = []; gitLabFailure = error
        }

        switch jiraAnswer {
        case .success(let tickets):
            let merged = Self.ordered(tickets, issues, for: text)
            if gitLabFailure != nil { throw PartialSearch(items: merged, message: Self.issuesFailed) }
            return merged
        case .failure(let error):
            guard !issues.isEmpty else {
                // Jira merely not connected says less than GitLab failing: that is what to fix.
                if error is NotConnected, let gitLabFailure { throw gitLabFailure }
                throw error
            }
            if error is NotConnected { return Self.ordered([], issues, for: text) }
            throw PartialSearch(items: Self.ordered([], issues, for: text), message: error.localizedDescription)
        }
    }

    /// The list with nothing typed is by when each last changed. A search keeps each source's own
    /// order — Jira puts the exact key first, then the keys it starts — with the ticket whose key
    /// is exactly what was typed (`JVS-57`, `#53`, `53`) ahead of everything, so six newer prefix
    /// matches never push it out of the picker.
    static func ordered(_ jira: [JiraTicket], _ issues: [JiraTicket], for text: String) -> [JiraTicket] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !typed.isEmpty else { return newestFirst(jira + issues) }
        let all = jira + issues
        let exact = all.filter { $0.key.uppercased() == typed || $0.key == "#" + typed }
        return exact + all.filter { ticket in !exact.contains { $0.key == ticket.key } }
    }

    /// Jira not connected: a reason, not a failure, while GitLab issues fill the list.
    struct NotConnected: LocalizedError { let errorDescription: String? }

    private static func attempt(_ source: Source?, _ text: String) async -> Result<[JiraTicket], Error> {
        guard let source else { return .success([]) }
        do { return .success(try await source(text)) } catch { return .failure(error) }
    }

    private func attemptJira(_ text: String) async -> Result<[JiraTicket], Error> {
        guard jira != nil else { return .failure(NotConnected(errorDescription: jiraUnavailable)) }
        return await Self.attempt(jira, text)
    }

    /// Newest first; a ticket with no time keeps its place after the dated ones.
    static func newestFirst(_ tickets: [JiraTicket]) -> [JiraTicket] {
        tickets.enumerated().sorted { a, b in
            switch (a.element.updated, b.element.updated) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }
}
