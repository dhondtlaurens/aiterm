import Foundation
@testable import AiTermCore

/// The one place tests build `Project`, `TaskItem` and `SessionInfo`, so a new field gets its default here.
/// A suite's own fixture family says only what its tests care about and passes it on to these builders.
enum Build {
    /// When everything a test builds was made, unless it says otherwise.
    static let epoch = Date(timeIntervalSince1970: 0)

    /// Agents rows: Claude on Opus, Codex on Astra.
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
                     mr: MergeRequestRef? = nil,
                     agent: AgentKind = .claude, model: String = "m", reasoning: String? = nil, firstPrompt: String? = nil,
                     appendTicket: Bool = false, createdAt: Date = Build.epoch, windowId: String? = nil,
                     conversations: [TaskConversation] = []) -> TaskItem {
        TaskItem(id: id, projectId: project, title: title, branch: branch, worktreePath: worktreePath, baseBranch: baseBranch,
                 jira: jira, kind: kind, mr: mr, agent: agent, model: model, reasoning: reasoning, firstPrompt: firstPrompt,
                 appendTicket: appendTicket, createdAt: createdAt, windowId: windowId, conversations: conversations)
    }
}

extension Signal {
    /// A Jira signal that plans tickets on `agents` and is done when its ticket reaches Done.
    static func make(id: UUID = UUID(), name: String = "Plan tickets", createdAt: Date = Build.epoch,
                     agents: [AgentChoice] = Build.agents) -> Signal {
        Signal(id: id, name: name, createdAt: createdAt, start: SignalTrigger(source: .jira, query: "labels = operator"),
               done: SignalTrigger(source: .jira, query: "status = Done"), work: SignalWork(prompt: "/psg:plan"),
               agents: agents, finish: SignalFinish(then: .keep))
    }
}

extension SignalTask {
    /// A driven task's record whose current stage runs `signal`'s configuration on `item`.
    static func make(signal: Signal = .make(), item: ItemRef, startedAt: Date = Build.epoch) -> SignalTask {
        SignalTask(current: SignalStage(signal: signal.id, item: item, matchedAt: startedAt, configuration: signal), startedAt: startedAt)
    }
}

extension OperatorSession {
    /// The Operator's chat open in `window` since `createdAt`, with its conversation when given.
    static func open(id: UUID = UUID(), createdAt: Date = Build.epoch, window: String? = "operator-window",
                     conversation: String? = nil, wake: Lifecycle.Wake? = nil) -> OperatorSession {
        var session = OperatorSession(id: id, createdAt: createdAt)
        session.window = window; session.conversation = conversation
        session.lifecycle = .open(since: createdAt, wake: wake)
        return session
    }
}

extension SessionInfo {
    /// A tab as the daemon lists it, tagged with `task` when it belongs to a task.
    static func make(_ sessionId: String = "s", window: String = "w1", tabIndex: Int = 0, task: UUID? = nil,
                     project: UUID? = nil, agent: SessionAgent = .claude,
                     state: SessionState = .idle, cwd: String = "/", conversation: String? = nil,
                     tabKey: String? = nil, active: Bool = false) -> SessionInfo {
        var session = SessionInfo(sessionId: sessionId, windowId: window, tabIndex: tabIndex, taskId: task?.uuidString,
                                  projectId: project?.uuidString, agent: agent, state: state, cwd: cwd, active: active,
                                  tabKey: tabKey)
        session.conversationId = conversation
        return session
    }
}
