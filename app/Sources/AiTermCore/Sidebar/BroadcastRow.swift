import Foundation

/// The broadcast under the OPERATOR heading, ready to draw on a task row's grid (spec §3, §13): the
/// Operator's agent as its avatar, the title, then `2 of 8 done`, the first project and `+n`, then its
/// status line, and its `StatusMark` trailing. The mark is the broadcast's, never the Operator session's:
/// amber while any request is open, spinning while something works, the idle ring while paused or only
/// waiting on people, and the accent dot once the debrief is ready.
public struct BroadcastRow: Equatable, Identifiable, Sendable {
    /// A project as the row's second line names it: its name after its host's mark.
    public struct ProjectMark: Equatable, Sendable {
        public var name: String
        public var provider: Provider
        public init(name: String, provider: Provider) { self.name = name; self.provider = provider }
    }

    /// The run's id.
    public var id: UUID
    public var title: String
    /// The Operator's agent: Claude Code, the only one it runs on (spec §13).
    public var agent: SessionAgent
    /// `2 of 8 done`; nil until the first plan is in Todo.
    public var progress: String?
    public var firstProject: ProjectMark?
    /// The projects after the first: the `+n`.
    public var moreProjects: Int
    /// Every project, as a sentence lists them: the project's tooltip.
    public var projectsHelp: String
    public var line: OperatorLine
    public var status: TaskStatus
    /// Paused by you, or its Operator's window closed: its menu offers Resume Broadcast.
    public var isPaused: Bool
    /// Done, the debrief ready: its menu offers neither Pause nor Resume.
    public var isComplete: Bool
}

public extension SidebarModel {
    /// The broadcast's row: `AppState.activeRun`'s, or nil while there is none. `acting` is
    /// what the Operator is doing now, as `OperatorController.acting` says it.
    static func broadcastRow(state: AppState, acting: OperatorActs = .none) -> BroadcastRow? {
        guard let run = state.activeRun else { return nil }
        let tasks = state.tasks.filter { $0.operated?.runId == run.id }
        let requests = OperatorRequests.open(run: run, state: state, prompts: [:])
        let act = acting.broadcast(run.id)
        let line = OperatorLine.broadcast(run, tasks: tasks, acting: act, requests: requests)
        let projects = run.projectIds.compactMap(state.project(id:))
        let paused = run.state == .paused || run.state == .operatorOffline || run.intent == .paused
        return BroadcastRow(id: run.id, title: run.name, agent: AgentKind.claude.session,
                            progress: BroadcastBoard.progress(of: run, tasks: tasks),
                            firstProject: projects.first.map { BroadcastRow.ProjectMark(name: $0.name, provider: $0.provider) },
                            moreProjects: max(projects.count - 1, 0), projectsHelp: OperatorLine.list(projects.map(\.name)),
                            line: line, status: broadcastStatus(run, tasks: tasks, line: line, acting: act != nil, paused: paused),
                            isPaused: paused, isComplete: run.state == .complete)
    }

    /// The row's mark: a request outranks everything, as on its line.
    private static func broadcastStatus(_ run: OperatorRun, tasks: [TaskItem], line: OperatorLine, acting: Bool,
                                        paused: Bool) -> TaskStatus {
        if line.look == .needsYou { return .needsInput }
        if run.state == .complete { return .done }
        if paused { return .idle }
        if run.state == .planning || acting { return .working }
        let working = tasks.contains { ($0.operated).map { !$0.takenOver && $0.state == .working } ?? false }
        return working ? .working : .idle
    }
}
