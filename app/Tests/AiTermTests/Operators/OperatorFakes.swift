import Foundation
import Synchronization
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The profile, projects, runs, tasks and tabs the operator service tests start from, through Part C's
/// initialisers. Named apart from part E's `OperatorUIFixtures` and Core's `OperatorFixtures`.
enum OperatorServiceFixtures {
    /// The profile a broadcast froze: Claude on Opus, every slice off, the Oracle off unless asked for.
    static func profile(oracle: Bool = false, oracleAgent: AgentKind = .codex) -> OperatorProfile {
        OperatorProfile(model: "claude-opus-5-5", reasoning: "high",
                        oracle: OracleSetting(isOn: oracle, agent: oracleAgent, model: oracleAgent == .codex ? "gpt-6-astra" : "claude-opus-5-5",
                                              reasoning: "medium"),
                        instructions: "You are careful.")
    }

    static func project(path: String = "/tmp/aiterm-operators-none", name: String = "Shop", jira: [JiraProjectRef] = []) -> Project {
        Project(id: UUID(), name: name, path: path, provider: .git, remoteUrl: nil, addedAt: Date(timeIntervalSince1970: 0),
                collapsed: false, jiraProjects: jira)
    }

    static func run(_ profile: OperatorProfile = profile(), projects: [Project], state: OperatorRunState = .planning,
                    planRevision: Int = 0, id: UUID = UUID()) -> OperatorRun {
        OperatorRun(id: id, name: "Sprint 42", profile: profile, projectIds: projects.map(\.id), prompt: "Implement the sprint.",
                    state: state, planRevision: planRevision, createdAt: Date(timeIntervalSince1970: 0))
    }

    static func task(in run: OperatorRun, project: Project, key: String, state: OperatedState = .planned, agent: AgentKind = .claude,
                     worktree: String = "", branch: String? = nil, revision: Int = 1, dependsOn: [TaskDependency] = [],
                     end: TaskEnd = .commit) -> TaskItem {
        var task = TaskItem(id: UUID(), projectId: project.id, title: "Task \(key)", branch: branch ?? "feat/\(key.lowercased())",
                            worktreePath: worktree, baseBranch: "", jira: nil, agent: agent, model: "m", reasoning: nil,
                            firstPrompt: "Do \(key).", appendTicket: false, createdAt: Date(timeIntervalSince1970: 0), windowId: nil)
        task.operated = OperatedTask(runId: run.id, key: key, state: state, end: end, brief: "Do \(key).", dependsOn: dependsOn,
                                     stackedOn: dependsOn.first { $0.kind == .code }?.task, revision: revision)
        return task
    }

    static func state(projects: [Project], runs: [OperatorRun], tasks: [TaskItem] = []) -> AppState {
        var state = AppState.empty
        for project in projects { state.append(project: project) }
        state.runs = runs
        state.tasks = tasks
        return state
    }

    /// A tab tagged with `tag`: a task's id, or a run's for the operator's own tab.
    static func session(_ id: String, window: String = "w1", tag: UUID, agent: SessionAgent = .claude, state: SessionState = .idle,
                        conversation: String? = nil, cwd: String = "/") -> SessionInfo {
        var session = SessionInfo(sessionId: id, windowId: window, tabIndex: 0, taskId: tag.uuidString, projectId: nil, agent: agent,
                                  model: nil, state: state, title: "", cwd: cwd)
        session.conversationId = conversation
        return session
    }

    /// Each agent's model list in Settings › Agents, as the scratch ports give it.
    static let models: [AgentKind: [AgentModel]] = [
        .claude: [AgentModel(id: "claude-opus-5-5", label: "Opus", detail: nil, efforts: ["high"], defaultEffort: "high"),
                  AgentModel(id: "claude-named", label: "Named", detail: nil, efforts: [], defaultEffort: nil),
                  AgentModel(id: "claude-other", label: "Other", detail: nil, efforts: [], defaultEffort: nil)],
        .codex: [AgentModel(id: "gpt-6-astra", label: "Astra", detail: nil, efforts: ["medium"], defaultEffort: "medium"),
                 AgentModel(id: "gpt-6-mini", label: "Mini", detail: nil, efforts: [], defaultEffort: nil)],
    ]

    static func question(_ key: String = "q1", at date: Date = Date(timeIntervalSince1970: 0)) -> OperatorQuestion {
        OperatorQuestion(id: key, text: "Which locale is the default?", task: nil, askedAt: date)
    }
}

/// Notifications posted, in order, instead of macOS's: a test host has no notification centre.
@MainActor
final class RecordingNotifications: OperatorNotifications {
    private(set) var posted: [OperatorNote] = []
    /// The ids taken back, in order.
    private(set) var withdrawn: [String] = []
    private(set) var authorizationRequests = 0
    /// What an earlier run of AiTerm left showing, as the launch's reading of the centre finds it.
    var delivered: [String] = []
    func readDelivered() async -> [String] { delivered }
    var onOpen: (@MainActor (OperatorNote.Target) -> Void)?
    func requestAuthorization() { authorizationRequests += 1 }
    func post(_ note: OperatorNote) { posted.append(note) }
    func withdraw(ids: [String]) { withdrawn += ids }
}

extension TestClock {
    /// The Operator tests' wall clock, a test moves by hand: `ports.now` and `publishNow` alike.
    static func operators() -> TestClock { TestClock(Date(timeIntervalSince1970: 1_000_000)) }
}

extension OperatorPorts {
    /// Ports that reach nothing real: a fresh temporary folder as the home — run folders and the agents'
    /// conversations under it — notifications recorded,
    /// hermetic git, wake lines with no wait.
    @MainActor static func scratch(notifications: RecordingNotifications = RecordingNotifications(),
                                   git: any GitRunning = GitRunner.hermetic()) -> OperatorPorts {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-operators-\(UUID().uuidString)")
        var ports = OperatorPorts(home: home, git: git, notifications: notifications, wakeCoalesce: .zero)
        // Nothing is published but through a test's own fake host, and no merge watch waits for real.
        ports.publisher = { _ in throw MergeRequestSearch.Unavailable.notConnected(.gitLab) }
        ports.mergeSleep = { _ in throw CancellationError() }
        // No wait for a summary ends but a test's own: a test that gives up on one moves the clock or the sleep.
        ports.summarySleep = { _ in throw CancellationError() }
        ports.promptSleep = { _ in throw CancellationError() }
        // Both agents installed, each with a short model list of its own, so no test reads this Mac's.
        ports.installedAgents = { [.claude, .codex] }
        ports.agentModels = { OperatorServiceFixtures.models[$0] ?? [] }
        // The versions the recording daemon's delivery check vouches for, never this Mac's `--version`.
        ports.installedVersions = { agents in [AgentKind: String](uniqueKeysWithValues: agents.compactMap { agent in
            ([.claude: "2.1.301", .codex: "0.160.0"] as [AgentKind: String])[agent].map { (agent, $0) } }) }
        // Settings › Operator's profile, never this Mac's.
        ports.profile = { OperatorServiceFixtures.profile() }
        return ports
    }
}

extension WorkspaceStore {
    /// A loaded workspace holding `state`, saved to a file nothing else uses: a broadcast's start
    /// waits for its run to be on disk.
    static func saving(_ state: AppState) throws -> WorkspaceStore {
        let store = WorkspaceStore(file: StateStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("aiterm-operators-state-\(UUID().uuidString).json")))
        try store.load()
        store.mutate { $0 = state }
        return store
    }
}

/// The helper a world's controller sees: the recording daemon, or none while `attached` is false.
@MainActor
final class DaemonSwitch {
    let daemon: RecordingDaemon
    var attached = true
    init(_ daemon: RecordingDaemon) { self.daemon = daemon }
    var current: (any DaemonCommands)? { attached ? daemon : nil }
}

/// An `OperatorController` over a saved workspace, the recording daemon and scratch ports.
@MainActor
final class OperatorWorld {
    let workspace: WorkspaceStore, live: LiveSessions, daemon: RecordingDaemon, link: DaemonSwitch
    let notifications = RecordingNotifications()
    let ports: OperatorPorts
    let controller: OperatorController

    init(_ state: AppState, daemon: RecordingDaemon = RecordingDaemon(), git: any GitRunning = GitRunner.hermetic(),
         adjust: (inout OperatorPorts) -> Void = { _ in }) throws {
        workspace = try WorkspaceStore.saving(state)
        live = LiveSessions(workspace: workspace)
        self.daemon = daemon
        link = DaemonSwitch(daemon)
        var ports = OperatorPorts.scratch(notifications: notifications, git: git)
        adjust(&ports)
        self.ports = ports
        controller = OperatorController(workspace: workspace, live: live, notices: Notices(toastLifetime: .seconds(10), isStale: { _ in false }),
                                        daemon: { [link] in link.current }, taskFrame: { Frame(x: 0, y: 0, w: 800, h: 600) }, ports: ports)
    }

    var state: AppState { workspace.state }
    func run(_ id: UUID) -> OperatorRun? { state.runs.first { $0.id == id } }
    func task(_ id: UUID) -> TaskItem? { state.task(id: id) }

    /// A Claude conversation the Operator can resume: its file under the scratch home's `~/.claude/projects`.
    func saveConversation(_ id: String) throws {
        let folder = ports.home.appendingPathComponent(".claude/projects/-operator")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent(id + ".jsonl"))
    }

    /// iTerm2's tabs as a connected snapshot reports them.
    func show(_ sessions: [SessionInfo]) {
        live.sessions = sessions
        controller.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: sessions, usage: .empty)))
    }
}

/// Jira as `jira_search` sees it: the tickets it answers with, and every search it was asked for.
final class FakeJira: OperatorJira {
    /// A write the Operator's Jira slice made, as the client would have been asked.
    enum Write: Equatable {
        case create(project: String, type: String, summary: String, description: String, parent: String?)
        case move(key: String, status: String)
        case link(key: String, to: String, type: String)
        case sprint(tickets: [String], sprint: Int)
        case backlog(tickets: [String])
        case edit(key: String, fields: JiraEdit)
        case comment(key: String, body: String)
    }
    let tickets: [JiraTicket]
    /// Every write answers Jira's 500 while this is set.
    private let failing = Mutex<JiraError?>(nil)
    private let seen = Mutex<[(jql: String, projects: [String])]>([])
    private let made = Mutex<[Write]>([])
    init(tickets: [JiraTicket] = []) { self.tickets = tickets }
    let siteURL = URL(string: "https://acme.atlassian.net")!
    var searches: [(jql: String, projects: [String])] { seen.withLock { $0 } }
    var writes: [Write] { made.withLock { $0 } }
    func failWrites(_ value: Bool = true) { failing.withLock { $0 = value ? .badResponse(500) : nil } }
    /// Every write answers Jira's 400 with `detail`.
    func refuseWrites(_ detail: String) { failing.withLock { $0 = .refused(status: 400, detail: detail) } }
    func search(jql: String, in projects: [JiraProjectRef]) async throws -> [JiraTicket] {
        seen.withLock { $0.append((jql, projects.map(\.key))) }
        if let hold = searchHold.withLock({ $0 }) { await hold() }
        // A search for a label finds the tickets made with it, as Jira would.
        let queriedProjects = jql.components(separatedBy: "project = \"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        let requestedProjects = projects.isEmpty ? queriedProjects : projects.map(\.key)
        let marked = labels.filter { key, labels in
            let project = String(key.prefix { $0 != "-" })
            return (requestedProjects.isEmpty || requestedProjects.contains(project)) && labels.contains { jql.contains("\"\($0)\"") }
        }.keys.sorted()
        if !marked.isEmpty {
            return marked.map { JiraTicket(key: $0, summary: "", description: nil, issueType: "Task", status: "To Do", url: "https://acme.atlassian.net/browse/\($0)") }
        }
        return tickets
    }
    /// The labels each ticket made was given, by its key.
    private let labelled = Mutex<[String: [String]]>([:])
    var labels: [String: [String]] { labelled.withLock { $0 } }
    /// The next create reaches Jira, then its answer is lost; or fails on the way, before Jira has it.
    private let lose = Mutex<(reply: Bool, before: Bool)>((false, false))
    func loseNextCreateReply() { lose.withLock { $0.reply = true } }
    func failNextCreateOnTheWay() { lose.withLock { $0.before = true } }
    /// Awaited inside a move, after Jira's reads and before the move: a test changes the broadcast with it.
    let beforeTransition = Mutex<(@Sendable () async -> Void)?>(nil)
    /// Awaited inside a search, after it is recorded: a test holds a search in flight with it.
    let searchHold = Mutex<(@Sendable () async -> Void)?>(nil)
    func createIssue(project: String, type: String, summary: String, description: String, parent: String?, labels: [String]) async throws -> String {
        let fault = lose.withLock { l in defer { l = (false, false) }; return l }
        if fault.before { throw URLError(.timedOut) }
        try record(.create(project: project, type: type, summary: summary, description: description, parent: parent))
        let key = "\(project)-\(100 + writes.count)"
        labelled.withLock { $0[key] = labels }
        if fault.reply { throw URLError(.networkConnectionLost) }
        return key
    }
    /// The status each ticket is in already, by key; a ticket not named is in none the Operator names.
    private let statuses = Mutex<[String: String]>([:])
    func put(_ key: String, in status: String) { statuses.withLock { $0[key] = status } }
    func transition(key: String, to statusName: String, beforeWrite: @Sendable () async throws -> Void) async throws -> Bool {
        if statuses.withLock({ $0[key] }) == statusName { return false }
        if let hook = beforeTransition.withLock({ $0 }) { await hook() }
        try await beforeWrite()
        try record(.move(key: key, status: statusName))
        return true
    }
    func link(key: String, to other: String, type: String) async throws { try record(.link(key: key, to: other, type: type)) }
    /// The boards each Jira project has, and the sprints and columns of each board, as `jira_board` reads them.
    private let agile = Mutex<(boards: [String: [JiraBoard]], sprints: [Int: [JiraSprint]], columns: [Int: [JiraColumn]])>(([:], [:], [:]))
    func put(boards: [JiraBoard], sprints: [JiraSprint] = [], columns: [JiraColumn] = [], in project: String) {
        agile.withLock { agile in
            agile.boards[project, default: []] += boards
            for board in boards { agile.sprints[board.id] = sprints.filter { $0.boardId == board.id }; agile.columns[board.id] = columns }
        }
    }
    func boards(project: String) async throws -> [JiraBoard] { agile.withLock { $0.boards[project] ?? [] } }
    /// The boards whose sprints Jira refuses with its 400, "The board does not support sprints".
    private let sprintless = Mutex<Set<Int>>([])
    func refuseSprints(of board: Int) { sprintless.withLock { _ = $0.insert(board) } }
    func sprints(board: Int) async throws -> [JiraSprint] {
        if sprintless.withLock({ $0.contains(board) }) { throw JiraError.badResponse(400) }
        return agile.withLock { $0.sprints[board] ?? [] }
    }
    func columns(board: Int) async throws -> [JiraColumn] { agile.withLock { $0.columns[board] ?? [] } }
    /// Awaited inside a sprint write, before its last check: a test changes the broadcast with it.
    let beforeSprintWrite = Mutex<(@Sendable () async -> Void)?>(nil)
    func addToSprint(_ sprint: Int, tickets: [String], beforeWrite: @Sendable () async throws -> Void) async throws {
        if let hook = beforeSprintWrite.withLock({ $0 }) { await hook() }
        try await beforeWrite()
        try record(.sprint(tickets: tickets, sprint: sprint))
    }
    func moveToBacklog(tickets: [String], beforeWrite: @Sendable () async throws -> Void) async throws {
        if let hook = beforeSprintWrite.withLock({ $0 }) { await hook() }
        try await beforeWrite()
        try record(.backlog(tickets: tickets))
    }
    /// Awaited inside an edit or a comment, before its last check: a test changes the broadcast with it.
    let beforeEditWrite = Mutex<(@Sendable () async -> Void)?>(nil)
    func edit(key: String, fields: JiraEdit, beforeWrite: @Sendable () async throws -> Void) async throws {
        if let hook = beforeEditWrite.withLock({ $0 }) { await hook() }
        try await beforeWrite()
        try record(.edit(key: key, fields: fields))
    }
    /// The comments posted, with the tag each was given, as Jira would hold them.
    private let posted = Mutex<[(id: String, ticket: String, tag: String?)]>([])
    var comments: [(id: String, ticket: String, tag: String?)] { posted.withLock { $0 } }
    /// The next comment reaches Jira, then its answer is lost.
    private let loseComment = Mutex(false)
    func loseNextCommentReply() { loseComment.withLock { $0 = true } }
    func comment(key: String, body: String, tag: String?, beforeWrite: @Sendable () async throws -> Void) async throws -> String {
        if let hook = beforeEditWrite.withLock({ $0 }) { await hook() }
        try await beforeWrite()
        try record(.comment(key: key, body: body))
        let id = "c\(writes.count)"
        posted.withLock { $0.append((id, key, tag)) }
        if loseComment.withLock({ let was = $0; $0 = false; return was }) { throw URLError(.networkConnectionLost) }
        return id
    }
    func findComment(key: String, tag: String) async throws -> String? {
        posted.withLock { $0.first { $0.ticket == key && $0.tag == tag }?.id }
    }
    private func record(_ write: Write) throws {
        if let error = failing.withLock({ $0 }) { throw error }
        made.withLock { $0.append(write) }
    }
}

extension OperatorWorld {
    /// One tool call, as the daemon would forward it for `run`.
    func call(_ run: UUID, _ tool: String, _ arguments: JSONValue = [:]) async -> ToolAnswer {
        await controller.tools.answer(OperatorRequest(requestId: UUID().uuidString, runId: run.uuidString, tool: tool, arguments: arguments))
    }
}

/// A latch the test opens: an Oracle held by it is still judging until then, however long the test takes, and one
/// opened before it asks is not held at all. Use it, not a delay, to make an answer pending against the reply budget.
actor OracleGate {
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !isOpen { await withCheckedContinuation { held.append($0) } } }
    func open() { isOpen = true; held.forEach { $0.resume() }; held = [] }
}

extension SecondOpinionRunner {
    /// A second opinion that answers `critique` once `gate` is open (at once with none) and after `delay`, as Claude's JSON result,
    /// or as PI's plain text when PI is the one run.
    static func answering(_ critique: String, after delay: Duration = .zero, gate: OracleGate? = nil,
                          receivePrompt: @escaping @Sendable (String) -> Void = { _ in }) -> SecondOpinionRunner {
        SecondOpinionRunner(locate: { "/opt/bin/\($0)" }, run: { executable, arguments, _, _, _ in
            let pi = executable.hasSuffix("/pi")
            // PI's prompt is its last word, after `--`; Claude's follows `-p`.
            if pi, let prompt = arguments.last { receivePrompt(prompt) }
            else if let at = arguments.firstIndex(of: "-p"), at + 1 < arguments.count { receivePrompt(arguments[at + 1]) }
            await gate?.wait()
            try? await Task.sleep(for: delay)
            let json = String(decoding: try JSONEncoder().encode(["result": critique]), as: UTF8.self)
            return ProcessOutput(status: 0, stdout: pi ? critique : json, stderr: "", timedOut: false)
        })
    }
}

/// A wait a test holds, and lets go of: `started` returns once something waits.
actor HeldGate {
    private var held: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { held = $0; entered?.resume(); entered = nil } }
    func started() async { if held == nil { await withCheckedContinuation { entered = $0 } } }
    func release() { held?.resume(); held = nil }
}

/// A git whose every read is told (`reads`) and then waits for `release`, answering `new-sha`.
final class HeldGit: GitRunning, @unchecked Sendable {
    let reads = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        reads.continuation.yield(())
        release.wait()
        return "new-sha"
    }
}

extension OperatorServiceFixtures {
    /// A world with one active broadcast holding task `A`, working, its worker's tab listed.
    @MainActor static func oneWorkingTask(_ daemon: RecordingDaemon = RecordingDaemon(), git: any GitRunning = GitRunner.hermetic(),
                                          adjust: (inout OperatorPorts) -> Void = { _ in }) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let project = Self.project()
        let run = Self.run(projects: [project], state: .active)
        let task = Self.task(in: run, project: project, key: "A", state: .working)
        let world = try OperatorWorld(Self.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon, git: git, adjust: adjust)
        world.live.sessions = [Self.session("worker", tag: task.id)]
        return (world, run, task)
    }
}
