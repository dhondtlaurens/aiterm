import Foundation
@testable import AiTermCore

/// The one place the tests call the workspace models' initialisers: a field added to `Project`, `TaskItem`,
/// `SessionInfo`, `OperatedTask` or `OperatorRun` is added here, with a default, and nowhere else. A fixture family
/// (`OperatorUIFixtures`, `OperatedWorld`, a suite's own `world`) says only what its tests care about and passes it on;
/// a new test starts here rather than with another local builder.
enum Build {
    /// When everything a test builds was made, unless it says otherwise.
    static let epoch = Date(timeIntervalSince1970: 0)

    /// The Agents rows of a broadcast set up with them: Claude on Opus, Codex on Astra.
    static let agents = [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high"),
                         AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")]
}

extension Project {
    static func make(id: UUID = UUID(), name: String = "Shop", path: String = "/tmp/aiterm-none", provider: Provider = .git,
                     remoteUrl: String? = nil, addedAt: Date = Build.epoch, collapsed: Bool = false,
                     jiraProjects: [JiraProjectRef] = []) -> Project {
        Project(id: id, name: name, path: path, provider: provider, remoteUrl: remoteUrl, addedAt: addedAt,
                collapsed: collapsed, jiraProjects: jiraProjects)
    }
}

extension TaskItem {
    /// A task in `project`, with no checkout on disk unless `worktreePath` names one.
    static func make(id: UUID = UUID(), project: UUID, title: String = "Work", branch: String = "feat/work",
                     worktreePath: String = "", baseBranch: String = "main", jira: JiraRef? = nil, kind: TaskKind = .task,
                     agent: AgentKind = .claude, model: String = "m", reasoning: String? = nil, firstPrompt: String? = nil,
                     createdAt: Date = Build.epoch, windowId: String? = nil, operated: OperatedTask? = nil) -> TaskItem {
        TaskItem(id: id, projectId: project, title: title, branch: branch, worktreePath: worktreePath, baseBranch: baseBranch,
                 jira: jira, kind: kind, agent: agent, model: model, reasoning: reasoning, firstPrompt: firstPrompt,
                 appendTicket: false, createdAt: createdAt, windowId: windowId, operated: operated)
    }
}

extension SessionInfo {
    /// A tab as the daemon lists it, tagged with `task` when it is a task's (or with a run's id, for the Operator's own).
    static func make(_ sessionId: String = "s", window: String = "w1", tabIndex: Int = 0, task: UUID? = nil,
                     agent: SessionAgent = .claude, state: SessionState = .idle, cwd: String = "/", conversation: String? = nil,
                     tabKey: String? = nil, active: Bool = false) -> SessionInfo {
        var session = SessionInfo(sessionId: sessionId, windowId: window, tabIndex: tabIndex, taskId: task?.uuidString,
                                  projectId: nil, agent: agent, model: nil, state: state, title: "", cwd: cwd, active: active,
                                  tabKey: tabKey)
        session.conversationId = conversation
        return session
    }
}

extension OperatedTask {
    /// What an Operator adds to a task of `run`. A `code` dependency stacks it on that parent, and `launched` gives it
    /// the one launch a task past `queued` has had.
    static func make(run: UUID, key: String, state: OperatedState = .queued, end: TaskEnd = .commit, brief: String? = nil,
                     dependsOn: [TaskDependency] = [], revision: Int = 1, acceptance: TaskAcceptance? = nil,
                     takenOver: Bool = false, launched: Bool = false, launchedAt: Date = Build.epoch,
                     blockedReason: String? = nil, flags: Set<OperatedFlag> = []) -> OperatedTask {
        OperatedTask(runId: run, key: key, state: state, end: end, brief: brief ?? "Do \(key).", dependsOn: dependsOn,
                     stackedOn: dependsOn.first { $0.kind == .code }?.task, revision: revision, acceptance: acceptance,
                     takenOver: takenOver, launch: launched ? LaunchAttempt(number: 1, requestedAt: launchedAt) : nil,
                     blockedReason: blockedReason, flags: flags)
    }
}

extension OperatorRun {
    /// A broadcast set up with the Agents, Task and Done steps: every task ends at a commit and none is closed, unless said.
    static func make(id: UUID = UUID(), name: String = "Sprint 42", profile: OperatorProfile, projects: [UUID] = [],
                     prompt: String = "Implement the sprint.", state: OperatorRunState = .active, planRevision: Int = 1,
                     questions: [OperatorQuestion] = [], decisions: [OperatorDecision] = [], windowId: String? = nil,
                     createdAt: Date = Build.epoch, agents: [AgentChoice] = Build.agents,
                     taskSettings: TaskSettings = TaskSettings(review: nil, end: .commit, closeWhenDone: false),
                     goal: BroadcastGoal? = nil) -> OperatorRun {
        OperatorRun(id: id, name: name, profile: profile, projectIds: projects, prompt: prompt, state: state,
                    planRevision: planRevision, questions: questions, decisions: decisions, operatorWindowId: windowId,
                    createdAt: createdAt, agents: agents, taskSettings: taskSettings, goal: goal)
    }
}
