import Foundation
import AiTermCore

/// The New Task sheet's state: a `CreationModel` that searches the project's Jira tickets.
final class TaskCreationModel: CreationModel<TaskDraft, JiraTicket> {
    /// `home` and `catalogue` have no defaults: each reads an agent's configuration, and a default
    /// would read the developer's own from anything that left them out.
    init(project: Project, draft: TaskDraft, home: URL, availableAgents: Set<AgentKind> = Set(AgentKind.allCases),
         rememberedModels: [AgentKind: String] = [:],
         catalogue: @escaping @Sendable (AgentKind) -> [AgentModel],
         initialCatalogue: [AgentModel]? = nil,
         defaults: UserDefaults = .standard, git: any GitRunning,
         canChangeWorkspace: @escaping @MainActor () -> Bool = { true },
         searchIssues: @escaping @MainActor (String) async throws -> [JiraTicket],
         createTask: @escaping @MainActor (TaskDraft) async throws -> Void) {
        super.init(project: project, draft: draft, home: home, availableAgents: availableAgents, rememberedModels: rememberedModels,
                   catalogue: catalogue, initialCatalogue: initialCatalogue, defaults: defaults, git: git, canChangeWorkspace: canChangeWorkspace,
                   search: searchIssues, submit: createTask)
    }

    /// The worktree directory the sheet names: the one create will make.
    var worktreeSlug: String { unusedSlug(draft.worktreeSlug) }

    /// A task's prompt carries its ticket too, when the person kept "Include Jira ticket details".
    override var composedPrompt: String? {
        AgentCommand.composePrompt(userText: draft.promptText, ticket: draft.ticket, appendTicket: draft.appendTicket)
    }

    /// The ticket field's placeholder names what it searches: the linked Jira projects, or — with
    /// none linked — every project the account can see, which needs no naming.
    var ticketPlaceholder: String {
        project.jiraProjects.isEmpty ? "Search by key or title" : "Search \(project.jiraProjects.keyList) by key or title"
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
