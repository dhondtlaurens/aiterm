import Foundation
import AiTermCore

/// New Task's part of `CreationModel`: it searches the project's tickets, names the worktree
/// after the task, and its prompt carries the ticket.
struct TaskCreation: CreationKind {
    typealias Draft = TaskDraft
    typealias Item = JiraTicket

    /// Whether Jira was connected when the sheet opened: the placeholder names only GitLab's issues
    /// when it was not.
    var jiraConnected = true

    var recovery: @MainActor (CreationFailure.Recovery) async throws -> Void = { _ in
        throw ActionUnavailable("Repository initialization is unavailable. Create the first commit in the project folder, then retry.")
    }

    func recover(_ recovery: CreationFailure.Recovery) async throws { try await self.recovery(recovery) }

    func draftChanged(from old: TaskDraft, in model: TaskCreationModel) {
        if old.baseBranch != model.draft.baseBranch { model.dropFailure() }
    }

    func slug(for draft: TaskDraft) -> String { draft.worktreeSlug }

    /// A task's prompt carries its ticket too, when the person kept "Include ticket details".
    func composedPrompt(_ text: String, draft: TaskDraft) -> String? {
        AgentCommand.composePrompt(userText: text, ticket: draft.ticket, appendTicket: draft.appendTicket)
    }
}

/// The New Task sheet's state.
typealias TaskCreationModel = CreationModel<TaskCreation>

extension CreationModel where Kind == TaskCreation {
    convenience init(project: Project, draft: TaskDraft, context: CreationContext,
                     searchIssues: @escaping @MainActor (String) async throws -> [JiraTicket],
                     jiraConnected: Bool = true,
                     createTask: @escaping @MainActor (TaskDraft) async throws -> Void,
                     recover: (@MainActor (CreationFailure.Recovery) async throws -> Void)? = nil) {
        var kind = TaskCreation()
        kind.jiraConnected = jiraConnected
        if let recover { kind.recovery = recover }
        self.init(kind: kind, project: project, draft: draft, context: context,
                  search: searchIssues, submit: createTask)
    }

    /// The ticket field's placeholder names what it searches: the linked Jira projects, or — with
    /// none linked — every project the account can see, which needs no naming; and the project's
    /// GitLab issues once the list has shown one, since a repository without open issues adds none.
    var ticketPlaceholder: String {
        Self.ticketPlaceholder(jiraProjects: project.jiraProjects.map(\.key), jiraConnected: kind.jiraConnected,
                               gitLabIssues: results.contains { $0.issueNumber != nil })
    }

    nonisolated static func ticketPlaceholder(jiraProjects: [String], jiraConnected: Bool, gitLabIssues: Bool) -> String {
        switch (gitLabIssues, jiraConnected, jiraProjects.isEmpty) {
        case (false, _, true): "Search by key or title"
        case (false, _, false): "Search \(jiraProjects.sentenceList) by key or title"
        case (true, false, _): "Search GitLab issues by #number or title"
        case (true, true, true): "Search Jira and GitLab issues by key, #number or title"
        case (true, true, false): "Search \(jiraProjects.sentenceList) and GitLab issues by key, #number or title"
        }
    }

    nonisolated static let connectJira = "Connect Jira in Settings › Integrations, or continue without a ticket."

    /// An empty query lists the person's open Jira tickets, across every linked Jira project, and the
    /// open issues of the project's GitLab repository when its remote is on the connected GitLab, in
    /// one list by when each last changed (`TicketSearch`); anything else searches for it in both.
    /// `jira` and `gitLab` are the connections as they stood when the sheet was prepared: reading
    /// them is a Keychain call, too slow for every keystroke on the main actor, so one changed in
    /// Settings meanwhile applies from the next sheet.
    static func ticketSearcher(for project: Project, jira: JiraConfig?, gitLab: GitLabConfig? = nil,
                               remote: RemoteInfo? = nil) -> @MainActor (String) async throws -> [JiraTicket] {
        let search = TicketSearch(jira: jiraSource(for: project, jira: jira), jiraUnavailable: connectJira,
                                  gitLabIssues: gitLabIssueSource(gitLab: gitLab, remote: remote))
        return { text in try await search.tickets(matching: text) }
    }

    nonisolated static func jiraSource(for project: Project, jira: JiraConfig?) -> TicketSearch.Source? {
        guard let jira else { return nil }
        let jiraProjects = project.jiraProjects
        return { text in
            let client = JiraClient(config: jira)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try await client.myOpenIssues(projects: jiraProjects)
                : try await client.search(text: text, projects: jiraProjects)
        }
    }

    /// The project's GitLab issues, when its remote is on the one GitLab host that is connected.
    nonisolated static func gitLabIssueSource(gitLab: GitLabConfig?, remote: RemoteInfo?) -> TicketSearch.Source? {
        guard let remote, case .gitLab(let config, let path)? = try? MergeRequestSearch.connection(for: remote, gitLab: gitLab, gitHub: nil)
        else { return nil }
        let client = GitLabClient(config: config, project: path)
        return { text in try await client.issues(search: text) }
    }
}
