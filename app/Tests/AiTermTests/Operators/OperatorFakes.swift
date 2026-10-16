import Foundation
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The persona, projects, runs, tasks and tabs the operator service tests start from, through Part C's
/// initialisers. Named apart from part E's `OperatorUIFixtures` and Core's `OperatorFixtures`.
enum OperatorServiceFixtures {
    static func persona(autonomy: Autonomy = .routine, level: SecondOpinionLevel = .noSelfDoubt, retries: Int = 2) -> OperatorPersona {
        OperatorPersona(name: "Senior engineer", handle: "senior", model: "claude-opus-5-5", effort: "high",
                        secondOpinion: SecondOpinion(level: level, agent: .codex, model: "gpt-6-astra", effort: "medium"),
                        autonomy: autonomy, limits: OperatorLimits(retries: retries, runtimeMinutes: 90), persona: "You are careful.")
    }

    static func project(path: String = "/tmp/aiterm-operators-none", name: String = "Shop", jira: [JiraProjectRef] = []) -> Project {
        Project(id: UUID(), name: name, path: path, provider: .git, remoteUrl: nil, addedAt: Date(timeIntervalSince1970: 0),
                collapsed: false, jiraProjects: jira)
    }

    static func run(_ persona: OperatorPersona = persona(), projects: [Project], state: OperatorRunState = .planning,
                    planRevision: Int = 0, id: UUID = UUID()) -> OperatorRun {
        OperatorRun(id: id, name: "Sprint 42", persona: persona, projectIds: projects.map(\.id), brief: "Implement the sprint.", doneWhen: nil,
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
