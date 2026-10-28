import Foundation
import Observation
import AiTermCore

/// What New Broadcast opens with, read as the sheet opens: Settings › Operator's slices and Oracle switch, as the profile
/// the broadcast will freeze has them; the installed agents a task can run (Claude, Codex), each with its own models in
/// Settings › Agents and the default it gives it there; and the last broadcast's Agents rows.
struct NewBroadcastContext: Equatable {
    var slices: Slices = .none
    var oracleIsOn = false
    /// Each installed agent's models, by agent: an agent not installed is left out.
    var models: [AgentKind: [AgentModel]] = [:]
    /// Each installed agent's default in Settings › Agents; an agent it resolves none for is left out.
    var defaults: [AgentKind: AgentChoice] = [:]
    /// The last broadcast's Agents rows (`OperatorProfileStore.lastAgents`), as saved.
    var lastAgents: [AgentChoice] = []

    /// Read from `profile` (none read: every slice and the Oracle off), the `installed` agents' model lists (`models`), the
    /// models last picked for each (`remembered`, the workspace's), and the defaults and rows `preferences` keeps.
    /// Blocking: read off the main actor.
    static func read(profile: OperatorProfile?, installed: [AgentKind], models: (AgentKind) -> [AgentModel],
                     remembered: [AgentKind: String], preferences: UserDefaults) -> NewBroadcastContext {
        let lists = Dictionary(installed.map { ($0, models($0)) }, uniquingKeysWith: { first, _ in first })
        var defaults: [AgentKind: AgentChoice] = [:]
        for (agent, list) in lists {
            let preference = ModelSettings.resolve(for: agent, catalog: list, remembered: remembered[agent], defaults: preferences)
            if !preference.model.isEmpty { defaults[agent] = AgentChoice(agent: agent, model: preference.model, reasoning: preference.reasoning) }
        }
        return NewBroadcastContext(slices: profile?.slices ?? .none, oracleIsOn: profile?.oracle.isOn ?? false, models: lists, defaults: defaults,
                                   lastAgents: OperatorProfileStore.lastAgents(preferences))
    }
}

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
        let agents: [AgentChoice]
        let taskSettings: TaskSettings?
        let goal: BroadcastGoal?
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
    /// Where the connection's Jira projects are: being fetched as the sheet opens, in hand, or not
    /// reached (Jira away, or not connected), which leaves the linked ones and holds nothing up.
    enum JiraLoad: Equatable { case loading, loaded, failed(String) }

    /// The sidebar's projects, which step 1 offers.
    let offeredProjects: [Project]
    /// Every Jira project the sidebar's projects link, each once: offered first, and alone until
    /// the connection answers.
    let linkedJiraProjects: [JiraProjectRef]
    /// The connection's Jira projects, as the Jira projects sheet fetches them (`JiraClient.projects`).
    private(set) var fetchedJiraProjects: [JiraProjectRef] = []
    private(set) var jiraLoad = JiraLoad.loading
    /// What the sheet opened with.
    let context: NewBroadcastContext
    var slices: Slices { context.slices }
    @ObservationIgnored private let skills: @Sendable (AgentKind, String?) -> [AgentCompletion]
    @ObservationIgnored private let files: @Sendable (String) -> FileIndex
    @ObservationIgnored private let startBroadcast: @MainActor (Request) async throws -> UUID
    @ObservationIgnored private let fetchJiraProjects: @MainActor () async throws -> [JiraProjectRef]
    @ObservationIgnored private let canChangeWorkspace: @MainActor () -> Bool
    /// What Start Broadcast waits for (`BroadcastReadiness`), read where it is kept: the cards' probes
    /// and the delivery check's file, both observed, so the footer follows them while the sheet is up.
    @ObservationIgnored private let readinessSource: @MainActor () -> BroadcastReadiness
    @ObservationIgnored private let prepareReadiness: @MainActor () async -> Void

    static let title = "New broadcast"
    static let stepNames = ["Broadcast", "Prompt", "Review", "Done"]
    static let createLabel = "Start Broadcast"
    static let destination = Destination.operatorWindow
    static let namePlaceholder = "Named by the Operator from the prompt"
    static let nameHelp = "Optional."
    static let jiraProjectsPlaceholder = "Add a Jira project"
    static let jiraProjectsHelp = "Where it reads tickets, and files them with the Jira slice on."
    static let jiraLoading = "Loading Jira projects…"
    static let noJiraProjects = "No Jira projects found."
    static let jiraLinkedOnly = "Only the Jira projects your projects link are offered."
    static let projectsPlaceholder = "Add a project"
    static let projectsHelp = "The repositories it may work in. Picking a Jira project adds its linked projects."
    static let promptHelp = "What to work on, as you’d tell a colleague. A Jira key brings in its ticket. Type / for skills, @ for files."
    static let reviewPlaceholder = "An adversarial review with /code-review, then fix what it finds"
    static let donePlaceholder = "A draft MR per ticket"


    /// `readiness` is what Start waits for as it stands; `checkReadiness` reads it, for as long as the
    /// sheet is open. A test or a snapshot that leaves them out is ready at once.
    init(projects: [Project], context: NewBroadcastContext,
         skills: @escaping @Sendable (AgentKind, String?) -> [AgentCompletion] = { SkillCatalog.discover(agent: $0, projectPath: $1) },
         files: @escaping @Sendable (String) -> FileIndex = { _ in .empty },
         loadJiraProjects: @escaping @MainActor () async throws -> [JiraProjectRef] = { [] },
         canChangeWorkspace: @escaping @MainActor () -> Bool = { true },
         readiness: @escaping @MainActor () -> BroadcastReadiness = { .ready },
         checkReadiness: @escaping @MainActor () async -> Void = {},
         start: @escaping @MainActor (Request) async throws -> UUID) {
        offeredProjects = projects
        linkedJiraProjects = projects.flatMap(\.jiraProjects).linkedOnce
        fetchJiraProjects = loadJiraProjects
        self.canChangeWorkspace = canChangeWorkspace
        readinessSource = readiness
        prepareReadiness = checkReadiness
        self.context = context
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

    /// Plain text naming Settings › Operator: with Merge off a task ends at a commit or a draft MR. Only with Merge
    /// on does the Oracle weigh an agent review before merging, so only then does the help say so.
    var doneHelp: String {
        slices.merge
            ? "Where each task ends: a commit, a draft MR, or merged and when. Write a condition per MR: “each MR merges once approved with all threads resolved; the run is done when every MR is merged”. Before a merge, the Oracle checks what the Review asks of an agent review against the review of the accepted commit. Optional: left empty, each task ends at a draft MR."
            : "Where each task ends. Optional: left empty, each task ends at a draft MR. Merge is off in Settings › Operator: each task ends at a commit or a draft MR, and a merge you ask for is left for you."
    }

    // -- step 1 ---------------------------------------------------------------------

    /// The linked Jira projects, then the connection's others in its order, each once.
    var offeredJiraProjects: [JiraProjectRef] { (linkedJiraProjects + fetchedJiraProjects).linkedOnce }

    /// The line under the Jira projects help while there is something to say: still loading, none
    /// found, or Jira not reached. Plain help, never amber: Start is not held up by it.
    var jiraStatus: String? {
        switch jiraLoad {
        case .loading: Self.jiraLoading
        case .failed(let reason): Self.jiraFailure(reason, linkedOffered: !linkedJiraProjects.isEmpty)
        case .loaded: offeredJiraProjects.isEmpty ? Self.noJiraProjects : nil
        }
    }

    /// Why Jira's projects couldn't be had, as the fetch said it ("Connect Jira in Settings › Integrations to choose a
    /// Jira project."), then that the linked ones are what is offered, when there are any.
    private static func jiraFailure(_ reason: String, linkedOffered: Bool) -> String {
        var said = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.isEmpty { said = "Jira couldn’t be reached." }
        if !".!?…".contains(said.last!) { said += "." }
        return linkedOffered ? said + " " + jiraLinkedOnly : said
    }

    /// Fetches the connection's Jira projects once, as the sheet opens.
    func loadJiraProjects() async {
        jiraLoad = .loading
        do {
            let found = try await fetchJiraProjects()
            guard !Task.isCancelled else { return }
            received(found)
        } catch {
            guard !Task.isCancelled else { return }
            jiraLoad = .failed(error.localizedDescription)
        }
    }

    /// The connection's answer, as a fetch lands it; the snapshots hand it in directly.
    func received(_ jiraProjects: [JiraProjectRef]) {
        fetchedJiraProjects = jiraProjects
        jiraLoad = .loaded
    }

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

    /// The offered Jira projects not picked yet, by key and then name (`JiraProjectSearch`), the
    /// linked ones first within each.
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

    /// Step 1 needs a project; every later step a prompt too. Review and Done may be left empty. Start
    /// Broadcast also waits for everything the broadcast needs to be ready (`readiness`); Continue never does.
    func canAdvance(step: Int) -> Bool {
        guard !starting, canChangeWorkspace(), !projects.isEmpty else { return false }
        guard step == 1 || Self.said(prompt) != nil else { return false }
        return step < CreationSteps.broadcast.count || readiness == .ready
    }

    var canStart: Bool { canAdvance(step: CreationSteps.broadcast.count) }

    /// What Start waits for, as it stands now.
    var readiness: BroadcastReadiness { readinessSource() }

    /// The footer's lines while something is not ready: one per agent, and iTerm2's.
    var notReadyLines: [String] { readiness.lines }

    /// Reads what Start waits for, until the sheet's task ends.
    func checkReadiness() async { await prepareReadiness() }

    /// Starts the broadcast and returns its id, or nil with why in `error`.
    func start() async -> UUID? {
        guard canStart, let prompt = Self.said(prompt) else { return nil }
        starting = true
        defer { starting = false }
        error = nil
        let request = Request(name: Self.said(name), jiraProjectKeys: jiraProjects.map(\.key), projectIds: projects.map(\.id),
                              prompt: prompt, review: Self.said(review), done: Self.said(done),
                              agents: [], taskSettings: nil, goal: nil)
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
        let skills = self.skills, files = self.files
        let found = await BackgroundWork.run {
            (skills: OperatorSkills.listed(at: paths, skills), files: only.map(files) ?? .empty)
        }
        guard !Task.isCancelled else { return }
        completions.all = found.skills
        completions.files = found.files
        completions.close()
    }
}

/// The skills `/` lists in the Operator's editors (New Broadcast's, Settings › Operator's Instructions): those of the two
/// agents a task can run on, Claude's first, then each of Codex's whose name is not listed yet.
enum OperatorSkills {
    static let agents: [AgentKind] = [.claude, .codex]

    /// Each agent's skills at each of `paths` (nil: the home alone), every name once, in that order. Blocking.
    static func listed(at paths: [String?], _ skills: (AgentKind, String?) -> [AgentCompletion]) -> [AgentCompletion] {
        var seen = Set<String>(), all: [AgentCompletion] = []
        for agent in agents {
            for path in paths {
                for item in skills(agent, path) where seen.insert(item.name).inserted { all.append(item) }
            }
        }
        return all
    }
}
