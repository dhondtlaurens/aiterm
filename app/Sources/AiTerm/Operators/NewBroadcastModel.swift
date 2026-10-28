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
    /// Each installed agent's default in Settings › Agents, else its first model; an agent listing none is left out.
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
            var preference = ModelSettings.resolve(for: agent, catalog: list, remembered: remembered[agent], defaults: preferences)
            // A saved default no longer listed resolves to none: the agent's first model stands in, so it is still offered.
            if preference.model.isEmpty, let first = list.first { preference.select(first) }
            if !preference.model.isEmpty { defaults[agent] = AgentChoice(agent: agent, model: preference.model, reasoning: preference.reasoning) }
        }
        return NewBroadcastContext(slices: profile?.slices ?? .none, oracleIsOn: profile?.oracle.isOn ?? false, models: lists, defaults: defaults,
                                   lastAgents: OperatorProfileStore.lastAgents(preferences))
    }
}

/// The New Broadcast sheet's state (spec §3.1, broadcast setup v2): step 1's name, Jira projects and projects, then the
/// prompt, the Agents rows, the Task step's review, end and closing, the Done step's goal and extra rounds, and Start
/// Broadcast, which hands them to `OperatorController.startBroadcast`. The end the Task step allows reads the Merge slice,
/// and the goal the Oracle switch, of Settings › Operator's profile as the sheet opened, the profile the broadcast will
/// freeze as it starts.
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
    /// The Agents step's rows, as they stand: two alike are kept while one is being picked, and handed over once.
    private(set) var agentRows: [AgentRow]
    /// The Task step's review prompt.
    var review = ""
    /// The end last picked on the Task step.
    private var pickedEnd = TaskEnd.draftMR
    /// The chosen projects found with no connected code host, as last checked: Draft MR and Merge wait for none.
    private(set) var projectsWithoutCodeHost: [Project] = []
    /// The chosen projects, by id, as the last check found them: Start waits until they are the chosen ones.
    private var codeHostsChecked: [UUID] = []
    /// Unticked, it unticks deleting branches too: a branch is deleted only by closing its task.
    var closeWhenDone = true { didSet { if !closeWhenDone { deleteMergedBranch = false } } }
    var deleteMergedBranch = false
    /// The Done step's goal.
    var done = ""
    /// The Done step's extra rounds as typed: digits only, and no more of them than a count can hold.
    var extraRoundsText = String(defaultExtraRounds) {
        didSet {
            let digits = extraRoundsText.filter { $0.isASCII && $0.isNumber }
            let kept = digits.isEmpty || Int(digits) != nil ? digits : oldValue
            if kept != extraRoundsText { extraRoundsText = kept }
        }
    }
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
    @ObservationIgnored private let hasCodeHost: (@Sendable (Project) async -> Bool)?

    static let title = "New broadcast"
    static let stepNames = ["Broadcast", "Prompt", "Agents", "Task", "Done"]
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
    static let agentsHelp = "The Operator starts every worker, tab and reviewer from this list, and nothing else. It starts as your last broadcast’s list."
    static let addAgentLabel = "Add an agent"
    static let taskLeadTitle = "Every task follows these."
    static let taskLead = "The broadcast’s own goal is the next step."
    static let reviewLabel = "Each task is reviewed with"
    static let reviewPlaceholder = "An adversarial review with /code-review, then fix what it finds"
    static let reviewHelp = "Who reviews each task, what counts as passing, and how many rounds of fixes it gets before it comes to you. Type / for skills. Optional: left empty, a task is accepted without a review."
    static let endLabel = "Each task ends at"
    static let closingLabel = "When the broadcast ends"
    static let closeLabel = "Close finished tasks’ tabs and remove their worktrees"
    static let deleteBranchLabel = "Delete their local branches once merged into the default branch"
    static let goalLabel = "Goal"
    static let goalPlaceholder = "Every ticket is merged and its work is released"
    static let extraRoundsLabel = "Extra rounds"
    /// What an emptied extra-rounds field counts as, and shows.
    static let extraRoundsPlaceholder = String(defaultExtraRounds)
    /// A goal's own default (`BroadcastGoal`).
    private static let defaultExtraRounds = BroadcastGoal(text: "").extraRounds

    /// `readiness` is what Start waits for as it stands; `checkReadiness` reads it, for as long as the
    /// sheet is open. A test or a snapshot that leaves them out is ready at once. `hasCodeHost` says whether a project's
    /// origin is on a code host AiTerm is connected to; left out, every project's is, with nothing to wait for.
    init(projects: [Project], context: NewBroadcastContext,
         skills: @escaping @Sendable (AgentKind, String?) -> [AgentCompletion] = { SkillCatalog.discover(agent: $0, projectPath: $1) },
         files: @escaping @Sendable (String) -> FileIndex = { _ in .empty },
         loadJiraProjects: @escaping @MainActor () async throws -> [JiraProjectRef] = { [] },
         canChangeWorkspace: @escaping @MainActor () -> Bool = { true },
         readiness: @escaping @MainActor () -> BroadcastReadiness = { .ready },
         checkReadiness: @escaping @MainActor () async -> Void = {},
         hasCodeHost: (@Sendable (Project) async -> Bool)? = nil,
         start: @escaping @MainActor (Request) async throws -> UUID) {
        offeredProjects = projects
        linkedJiraProjects = projects.flatMap(\.jiraProjects).linkedOnce
        fetchJiraProjects = loadJiraProjects
        self.canChangeWorkspace = canChangeWorkspace
        readinessSource = readiness
        prepareReadiness = checkReadiness
        self.hasCodeHost = hasCodeHost
        self.context = context
        agentRows = Self.seededRows(context).map { AgentRow(choice: $0) }
        self.skills = skills
        self.files = files
        startBroadcast = start
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

    // -- step 3: agents ---------------------------------------------------------------

    /// One row of the Agents step, kept apart from its combination so it stays put while that is picked.
    struct AgentRow: Identifiable, Equatable {
        let id = UUID()
        var choice: AgentChoice
    }

    /// The last broadcast's rows less those whose agent is no longer installed or whose model is no longer listed, each at
    /// a reasoning its model offers, alike rows once; with none of them, each installed agent at its Settings › Agents
    /// default.
    private static func seededRows(_ context: NewBroadcastContext) -> [AgentChoice] {
        let kept = context.lastAgents.compactMap { row in
            context.models[row.agent]?.first { $0.id == row.model }.map { picked(row, model: $0) }
        }
        return kept.isEmpty ? ModelChoice.pair.compactMap { context.defaults[$0] } : once(kept)
    }

    /// `row` on `model`, at its reasoning while `model` offers it, else `model`'s default (`ModelPreference.select`).
    private static func picked(_ row: AgentChoice, model: AgentModel) -> AgentChoice {
        var preference = ModelPreference(model: row.model, reasoning: row.reasoning)
        preference.select(model)
        return AgentChoice(agent: row.agent, model: preference.model, reasoning: preference.reasoning)
    }

    private static func once(_ rows: [AgentChoice]) -> [AgentChoice] {
        var seen = Set<AgentChoice>()
        return rows.filter { seen.insert($0).inserted }
    }

    /// The agents a row may run: those installed with a default, Claude first.
    var offeredAgents: [AgentKind] { ModelChoice.pair.filter { context.defaults[$0] != nil } }

    /// `agent`'s own models, as Settings › Agents lists them.
    func models(for agent: AgentKind) -> [AgentModel] { context.models[agent] ?? [] }

    /// The rows Start hands over: each combination once, in the order first given.
    var agents: [AgentChoice] { Self.once(agentRows.map(\.choice)) }

    /// Adds the first offered agent that has no row yet, else the first offered, at its Settings › Agents default.
    func addAgent() {
        let listed = Set(agentRows.map(\.choice.agent))
        guard let agent = offeredAgents.first(where: { !listed.contains($0) }) ?? offeredAgents.first,
              let choice = context.defaults[agent] else { return }
        agentRows.append(AgentRow(choice: choice))
    }

    func removeAgent(_ row: AgentRow.ID) { agentRows.removeAll { $0.id == row } }

    /// The row on `agent`, at its Settings › Agents default. The agent it already runs keeps its model and reasoning: a
    /// popup reports picking its selected item again.
    func setAgent(_ agent: AgentKind, of row: AgentRow.ID) {
        guard agentRows.first(where: { $0.id == row })?.choice.agent != agent, let choice = context.defaults[agent] else { return }
        update(row) { $0 = choice }
    }

    func setModel(_ model: AgentModel, of row: AgentRow.ID) { update(row) { $0 = Self.picked($0, model: model) } }

    func setReasoning(_ reasoning: String?, of row: AgentRow.ID) { update(row) { $0.reasoning = reasoning } }

    private func update(_ row: AgentRow.ID, _ change: (inout AgentChoice) -> Void) {
        guard let index = agentRows.firstIndex(where: { $0.id == row }) else { return }
        change(&agentRows[index].choice)
    }

    // -- step 4: task -------------------------------------------------------------------

    /// An end as its segment reads: its name, capitalised.
    static func title(of end: TaskEnd) -> String { end.displayName.prefix(1).uppercased() + end.displayName.dropFirst() }

    /// Merge and Local merge only with the Merge slice on; Draft MR and Merge only while every chosen project has a
    /// connected code host.
    func canPick(_ end: TaskEnd) -> Bool {
        (!end.merges || slices.merge) && (!end.needsCodeHost || projectsWithoutCodeHost.isEmpty)
    }

    func pick(end: TaskEnd) { if canPick(end) { pickedEnd = end } }

    /// Every task's end as it starts, the one Start hands over: the end picked while it can be picked, else Commit.
    var end: TaskEnd { canPick(pickedEnd) ? pickedEnd : .commit }

    /// Plain text saying why an end is dimmed, Settings › Operator's Merge slice or the projects with no connected code
    /// host, and the ends left: “… Merge is off in Settings › Operator, so a task ends at a commit or a draft MR.” An end
    /// picked that is dimmed since is said to have moved to Commit.
    var endHelp: String {
        let lead = "Where every task’s work ends."
        var reasons: [String] = []
        if !slices.merge { reasons.append("Merge is off in Settings › Operator") }
        if let last = projectsWithoutCodeHost.last {
            let names = projectsWithoutCodeHost.dropLast().map(\.name)
            let listed = names.isEmpty ? last.name : names.joined(separator: ", ") + " and " + last.name
            reasons.append(listed + (names.isEmpty ? " has" : " have") + " no connected code host")
        }
        guard !reasons.isEmpty else { return lead }
        let ends = TaskEnd.allCases.filter(canPick).map { "a " + $0.displayName }
        let help = "\(lead) \(reasons.joined(separator: " and ")), so a task ends at \(ends.joined(separator: " or "))."
        return end == pickedEnd ? help : "\(help) \(Self.title(of: pickedEnd)) moved to \(Self.title(of: end))."
    }

    /// Checks each chosen project for a connected code host, as the chosen ones change.
    func loadCodeHosts() async {
        guard let hasCodeHost else { return }
        let chosen = projects
        var without: [Project] = []
        for project in chosen {
            if await !hasCodeHost(project) { without.append(project) }
        }
        guard !Task.isCancelled else { return }
        received(withoutCodeHost: without)
        codeHostsChecked = chosen.map(\.id)
    }

    /// Whether the chosen projects' code hosts are known: checked as they stand, or not checked at all.
    private var codeHostsKnown: Bool { hasCodeHost == nil || codeHostsChecked == projects.map(\.id) }

    /// The projects a check found with no connected code host; the snapshots hand them in directly.
    func received(withoutCodeHost projects: [Project]) { projectsWithoutCodeHost = projects }

    /// A branch is deleted only by closing its task.
    var canDeleteMergedBranch: Bool { closeWhenDone }

    // -- step 5: done -------------------------------------------------------------------

    /// A goal is checked with the Oracle, so it needs the Oracle on.
    var goalIsAvailable: Bool { context.oracleIsOn }

    var goalHelp: String {
        goalIsAvailable
            ? "What must be true once every task is done. The Operator checks it with the Oracle. Optional: left empty, the broadcast ends when its tasks do."
            : "The Oracle is off in Settings › Operator, and a goal needs it: the broadcast ends when its tasks do."
    }

    /// None while the Oracle is off: the goal's help says it for both.
    var extraRoundsHelp: String? {
        goalIsAvailable
            ? "How many times the Operator may plan what the goal still misses, once every task is done. When they are used up, it stops and says what is left."
            : nil
    }

    /// The extra rounds typed, the default when none are.
    var extraRounds: Int { Int(extraRoundsText) ?? Self.defaultExtraRounds }

    // -- moving on and starting -----------------------------------------------------

    private static func said(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Step 1 needs a project; every later step a prompt too, and from the Agents step on a row. The review and the goal
    /// may be left empty. Start Broadcast also waits for everything the broadcast needs to be ready (`readiness`), and
    /// for the chosen projects' code hosts to be checked; Continue never does.
    func canAdvance(step: Int) -> Bool {
        guard !starting, canChangeWorkspace(), !projects.isEmpty else { return false }
        guard step == 1 || Self.said(prompt) != nil else { return false }
        if let agentsStep = CreationSteps.broadcast.agentsListStep, step >= agentsStep, agentRows.isEmpty { return false }
        return step < CreationSteps.broadcast.count || (readiness == .ready && codeHostsKnown)
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
        let taskSettings = TaskSettings(review: Self.said(review), end: end, closeWhenDone: closeWhenDone,
                                        deleteMergedBranch: deleteMergedBranch)
        let goal = goalIsAvailable ? Self.said(done).map { BroadcastGoal(text: $0, extraRounds: extraRounds) } : nil
        let request = Request(name: Self.said(name), jiraProjectKeys: jiraProjects.map(\.key), projectIds: projects.map(\.id),
                              prompt: prompt, review: nil, done: nil, agents: agents, taskSettings: taskSettings, goal: goal)
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
