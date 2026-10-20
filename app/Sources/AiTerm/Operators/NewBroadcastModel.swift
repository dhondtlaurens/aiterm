import Foundation
import Observation
import AiTermCore

/// The New Broadcast sheet's state (spec §3.1): step 1's name, Jira projects and projects, then the
/// prompt, the review and the done, and Start Broadcast, which hands them to
/// `OperatorController.startBroadcast`. The Review and Done help read the slices of Settings ›
/// Operator's profile as the sheet opened, the profile the broadcast will freeze as it starts.
@MainActor
@Observable
final class NewBroadcastModel: Identifiable {
    /// What Start Broadcast hands the controller: `startBroadcast`'s arguments, trimmed, an empty
    /// field as none.
    struct Request: Equatable {
        let name: String?
        let jiraProjectKeys: [String]
        let projectIds: [UUID]
        let prompt: String
        let review: String?
        let done: String?
    }

    nonisolated let id = UUID()
    var name = ""
    /// The Jira projects it reads tickets in, in the order they were picked.
    private(set) var jiraProjects: [JiraProjectRef] = []
    /// The repositories it may work in, in the sidebar's order.
    private(set) var projects: [Project] = []
    var prompt = ""
    var review = ""
    var done = ""
    private(set) var starting = false
    /// Why the last start failed, shown in the footer as a `Notice`.
    private(set) var error: CreationFailure?
    /// What `/` lists in the three editors (both agents' skills) and `@` (one project's files).
    let completions = PromptCompletions()
    /// The sidebar's projects, which step 1 offers.
    let offeredProjects: [Project]
    /// Every Jira project the sidebar's projects link, each once.
    let offeredJiraProjects: [JiraProjectRef]
    let slices: Slices
    @ObservationIgnored private let skills: @Sendable (AgentKind, String?) -> [AgentCompletion]
    @ObservationIgnored private let files: @Sendable (String) -> FileIndex
    @ObservationIgnored private let startBroadcast: @MainActor (Request) async throws -> UUID

    static let title = "New broadcast"
    static let stepNames = ["Broadcast", "Prompt", "Review", "Done"]
    static let createLabel = "Start Broadcast"
    static let destination = Destination.operatorWindow
    static let namePlaceholder = "Named by the Operator from the prompt"
    static let nameHelp = "Optional."
    static let jiraProjectsPlaceholder = "Add a Jira project"
    static let jiraProjectsHelp = "Where it reads tickets, and files them with the Jira slice on."
    static let projectsPlaceholder = "Add a project"
    static let projectsHelp = "The repositories it may work in. Picking a Jira project adds its linked projects."
    static let promptHelp = "What to work on, as you’d tell a colleague. A Jira key brings in its ticket. Type / for skills, @ for files."
    static let reviewPlaceholder = "An adversarial review with /code-review, then fix what it finds"
    static let donePlaceholder = "A draft MR per ticket"

    /// The agents whose skills `/` lists: the two a task can run on.
    static let skillAgents: [AgentKind] = [.claude, .codex]

    init(projects: [Project], slices: Slices,
         skills: @escaping @Sendable (AgentKind, String?) -> [AgentCompletion] = { SkillCatalog.discover(agent: $0, projectPath: $1) },
         files: @escaping @Sendable (String) -> FileIndex = { _ in .empty },
         start: @escaping @MainActor (Request) async throws -> UUID) {
        offeredProjects = projects
        offeredJiraProjects = projects.flatMap(\.jiraProjects).linkedOnce
        self.slices = slices
        self.skills = skills
        self.files = files
        startBroadcast = start
    }

    // -- the help the slices decide -----------------------------------------------------

    /// Plain text naming Settings › Operator: an agent review needs no switch, people need Review.
    var reviewHelp: String {
        slices.review
            ? "Who reviews each task and how. Optional. An agent review (“an adversarial review with /code-review”) needs no switch; involving people needs Review, which is on in Settings › Operator."
            : "Who reviews each task and how. Optional. An agent review needs no switch. Review is off in Settings › Operator, so the Operator won’t involve people: those tasks stop at their draft MR."
    }

    /// Plain text naming Settings › Operator: with Merge off a task ends at a commit or a draft MR.
    var doneHelp: String {
        slices.merge
            ? "Where each task ends: a commit, a draft MR, or merged and when. Optional: left empty, each task ends at a draft MR."
            : "Where each task ends. Optional: left empty, each task ends at a draft MR. Merge is off in Settings › Operator: each task ends at a commit or a draft MR, and a merge you ask for is left for you."
    }

    // -- step 1 ---------------------------------------------------------------------

    /// Picks `jiraProject`, and every offered project linked to it that isn't picked yet.
    func add(jiraProject: JiraProjectRef) {
        guard !jiraProjects.contains(where: { $0.id == jiraProject.id }) else { return }
        jiraProjects.append(jiraProject)
        let linked = offeredProjects.filter { project in project.jiraProjects.contains { $0.id == jiraProject.id } }
        let picked = Set(projects.map(\.id))
        let added = linked.filter { !picked.contains($0.id) }
        guard !added.isEmpty else { return }
        setProjects(projects + added)
    }

    /// Leaves the projects it added: they were picked, and may be wanted on their own.
    func remove(jiraProject: JiraProjectRef) { jiraProjects.removeAll { $0.id == jiraProject.id } }

    func add(project: Project) {
        guard !projects.contains(where: { $0.id == project.id }) else { return }
        setProjects(projects + [project])
    }

    func remove(project: Project) { projects.removeAll { $0.id == project.id } }

    /// Kept in the sidebar's order, whichever way they were picked.
    private func setProjects(_ picked: [Project]) {
        let ids = Set(picked.map(\.id))
        let ordered = offeredProjects.filter { ids.contains($0.id) }
        projects = ordered + picked.filter { project in !ordered.contains { $0.id == project.id } }
    }

    /// The offered Jira projects not picked yet, by key and then name (`JiraProjectSearch`).
    func matchingJiraProjects(query: String) -> [JiraProjectRef] {
        JiraProjectSearch.rank(offeredJiraProjects, query: query, excluding: jiraProjects)
    }

    /// The offered projects not picked yet whose name has `query` in it, those starting with it first.
    func matchingProjects(query: String) -> [Project] {
        let picked = Set(projects.map(\.id))
        let open = offeredProjects.filter { !picked.contains($0.id) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return open }
        let named = open.filter { $0.name.lowercased().contains(q) }
        return named.filter { $0.name.lowercased().hasPrefix(q) } + named.filter { !$0.name.lowercased().hasPrefix(q) }
    }

    // -- moving on and starting -----------------------------------------------------

    private static func said(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Step 1 needs a project; every later step a prompt too. Review and Done may be left empty.
    func canAdvance(step: Int) -> Bool {
        guard !starting, !projects.isEmpty else { return false }
        return step == 1 || Self.said(prompt) != nil
    }

    var canStart: Bool { canAdvance(step: CreationSteps.broadcast.count) }

    /// Starts the broadcast and returns its id, or nil with why in `error`.
    func start() async -> UUID? {
        guard canStart, let prompt = Self.said(prompt) else { return nil }
        starting = true
        defer { starting = false }
        error = nil
        let request = Request(name: Self.said(name), jiraProjectKeys: jiraProjects.map(\.key), projectIds: projects.map(\.id),
                              prompt: prompt, review: Self.said(review), done: Self.said(done))
        do { return try await startBroadcast(request) }
        catch { self.error = CreationFailure(reason: OperationIssue.reason(of: error), detail: nil); return nil }
    }

    // -- completions ----------------------------------------------------------------

    /// What `/` lists: Claude's skills, then Codex's not already listed, from the home and each picked
    /// project (the home alone with none picked). `@` lists the files of the one picked project; across
    /// several there is no one root to write a path from, so it lists none. Read off the main actor.
    func loadCompletions() async {
        let paths: [String?] = projects.isEmpty ? [nil] : projects.map(\.path)
        let only = projects.count == 1 ? projects.first?.path : nil
        let skills = self.skills, files = self.files, agents = Self.skillAgents
        let found = await BackgroundWork.run {
            var seen = Set<String>(), all: [AgentCompletion] = []
            for agent in agents {
                for path in paths {
                    for item in skills(agent, path) where seen.insert(item.name).inserted { all.append(item) }
                }
            }
            return (skills: all, files: only.map(files) ?? .empty)
        }
        guard !Task.isCancelled else { return }
        completions.all = found.skills
        completions.files = found.files
        completions.close()
    }
}
