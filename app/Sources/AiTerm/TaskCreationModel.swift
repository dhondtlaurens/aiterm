import Foundation
import AiTermCore

/// New Task's part of `CreationModel`: it searches the project's Jira tickets, names the worktree
/// after the task, and its prompt carries the ticket.
struct TaskCreation: CreationKind {
    typealias Draft = TaskDraft
    typealias Item = JiraTicket

    func slug(for draft: TaskDraft) -> String { draft.worktreeSlug }

    /// A task's prompt carries its ticket too, when the person kept "Include Jira ticket details".
    func composedPrompt(_ text: String, draft: TaskDraft) -> String? {
        AgentCommand.composePrompt(userText: text, ticket: draft.ticket, appendTicket: draft.appendTicket)
    }
}

/// The New Task sheet's state.
typealias TaskCreationModel = CreationModel<TaskCreation>

extension CreationModel where Kind == TaskCreation {
    convenience init(project: Project, draft: TaskDraft, context: CreationContext,
                     searchIssues: @escaping @MainActor (String) async throws -> [JiraTicket],
                     createTask: @escaping @MainActor (TaskDraft) async throws -> Void) {
        self.init(kind: TaskCreation(), project: project, draft: draft, context: context,
                  search: searchIssues, submit: createTask)
    }

    /// The ticket field's placeholder names what it searches: the linked Jira projects, or — with
    /// none linked — every project the account can see, which needs no naming.
    var ticketPlaceholder: String {
        project.jiraProjects.isEmpty ? "Search by key or title" : "Search \(project.jiraProjects.map(\.key).sentenceList) by key or title"
    }

    /// An empty query lists the person's open tickets, across every linked Jira project; anything
    /// else searches for it there. `jira` is the connection as it stood when the sheet was
    /// prepared: reading it is a Keychain call, too slow for every keystroke on the main actor, so
    /// one changed in Settings meanwhile applies from the next sheet.
    static func jiraSearcher(for project: Project, jira: JiraConfig?) -> @MainActor (String) async throws -> [JiraTicket] {
        let jiraProjects = project.jiraProjects
        return { text in
            guard let config = jira else {
                throw ActionUnavailable("Connect Jira in Settings › Integrations, or continue without a ticket.")
            }
            let client = JiraClient(config: config)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try await client.myOpenIssues(projects: jiraProjects)
                : try await client.search(text: text, projects: jiraProjects)
        }
    }
}
