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
                     createdAt: Date = Build.epoch, windowId: String? = nil) -> TaskItem {
        TaskItem(id: id, projectId: project, title: title, branch: branch, worktreePath: worktreePath, baseBranch: baseBranch,
                 jira: jira, kind: kind, agent: agent, model: model, reasoning: reasoning, firstPrompt: firstPrompt,
                 appendTicket: false, createdAt: createdAt, windowId: windowId)
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
