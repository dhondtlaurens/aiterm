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

    /// `approvedRevision`: the plan revision you approved, every plan being gated until the plan's Task 2.
    static func run(_ profile: OperatorProfile = profile(), projects: [Project], state: OperatorRunState = .planning,
                    planRevision: Int = 0, approvedRevision: Int? = nil, id: UUID = UUID()) -> OperatorRun {
        OperatorRun(id: id, name: "Sprint 42", profile: profile, projectIds: projects.map(\.id), prompt: "Implement the sprint.",
                    state: state, planRevision: planRevision, approvedRevision: approvedRevision, createdAt: Date(timeIntervalSince1970: 0))
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

    static func question(_ key: String = "q1", at date: Date = Date(timeIntervalSince1970: 0)) -> OperatorQuestion {
        OperatorQuestion(id: key, text: "Which locale is the default?", task: nil, askedAt: date)
    }
}

/// Notifications posted, in order, instead of macOS's: a test host has no notification centre.
@MainActor
final class RecordingNotifications: OperatorNotifications {
    private(set) var posted: [OperatorNote] = []
    private(set) var authorizationRequests = 0
    var onOpen: (@MainActor (OperatorNote.Target) -> Void)?
    func requestAuthorization() { authorizationRequests += 1 }
    func post(_ note: OperatorNote) { posted.append(note) }
}

/// A wall clock a test moves by hand.
@MainActor
final class StepClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

extension OperatorPorts {
    /// Ports that reach nothing real: a fresh temporary folder as the home — run folders and the agents'
    /// conversations under it — notifications recorded,
    /// hermetic git, wake lines with no wait, one agent at a time.
    @MainActor static func scratch(notifications: RecordingNotifications = RecordingNotifications(),
                                   git: any GitRunning = GitRunner.hermetic()) -> OperatorPorts {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-operators-\(UUID().uuidString)")
        var ports = OperatorPorts(home: home, git: git, notifications: notifications, wakeCoalesce: .zero)
        // One agent at a time, whatever the test host's defaults hold; a test of the cap sets its own.
        ports.agentsAtOnce = { 1 }
        // Nothing is published but through a test's own fake host, and no merge watch waits for real.
        ports.publisher = { _ in throw MergeRequestSearch.Unavailable.notConnected(.gitLab) }
        ports.mergeSleep = { _ in throw CancellationError() }
        return ports
    }
}

extension WorkspaceStore {
    /// A loaded workspace holding `state`, saved to a file nothing else uses: an operation's start
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

    /// iTerm2's tabs as a connected snapshot reports them.
    func show(_ sessions: [SessionInfo]) {
        live.sessions = sessions
        controller.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: sessions, usage: .empty)))
    }
}

/// Jira as `jira_search` sees it: the tickets it answers with, and every search it was asked for.
final class FakeJira: OperatorJira {
    let tickets: [JiraTicket]
    private let seen = Mutex<[(jql: String, projects: [String])]>([])
    init(tickets: [JiraTicket]) { self.tickets = tickets }
    var searches: [(jql: String, projects: [String])] { seen.withLock { $0 } }
    func search(jql: String, in projects: [JiraProjectRef]) async throws -> [JiraTicket] {
        seen.withLock { $0.append((jql, projects.map(\.key))) }
        return tickets
    }
}

extension OperatorWorld {
    /// One tool call, as the daemon would forward it for `run`.
    func call(_ run: UUID, _ tool: String, _ arguments: JSONValue = [:]) async -> ToolAnswer {
        await controller.tools.answer(OperatorRequest(requestId: UUID().uuidString, runId: run.uuidString, tool: tool, arguments: arguments))
    }
}

extension SecondOpinionRunner {
    /// A second opinion that answers `critique` after `delay`, as Claude's JSON result.
    static func answering(_ critique: String, after delay: Duration = .zero) -> SecondOpinionRunner {
        SecondOpinionRunner(locate: { "/opt/bin/\($0)" }, run: { _, _, _, _, _ in
            try? await Task.sleep(for: delay)
            let json = String(decoding: try JSONEncoder().encode(["result": critique]), as: UTF8.self)
            return ProcessOutput(status: 0, stdout: json, stderr: "", timedOut: false)
        })
    }
}
