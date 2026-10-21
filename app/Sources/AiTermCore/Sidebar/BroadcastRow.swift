import Foundation

/// The broadcast under the OPERATOR heading, ready to draw on a task row's grid (spec §3, §13): the
/// Operator's agent as its avatar, the title over its status line with `· 2 of 8 done` after it, as its
/// board's band reads, its projects in the tooltip, and its `StatusMark` trailing. The mark is the broadcast's, never the Operator session's:
/// amber while any request is open, spinning while something works, the idle ring while paused or only
/// waiting on people or on the Operator to accept, and the accent dot once the debrief is ready.
public struct BroadcastRow: Equatable, Identifiable, Sendable {
    /// The run's id.
    public var id: UUID
    public var title: String
    /// The Operator's agent: Claude Code, the only one it runs on (spec §13).
    public var agent: SessionAgent
    /// `2 of 8 done`, after the status line; nil until the first plan is in Todo.
    public var progress: String?
    /// Every project, as a sentence lists them: the row's tooltip.
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
    /// what the Operator is doing now, as `OperatorController.acting` says it; `sessions` the tabs as
    /// iTerm2 lists them, which tell a task whose workers are done (`readyForAcceptance`).
    static func broadcastRow(state: AppState, acting: OperatorActs = .none, sessions: [SessionInfo] = []) -> BroadcastRow? {
        guard let run = state.activeRun else { return nil }
        let tasks = state.tasks.filter { $0.operated?.runId == run.id }
        let requests = OperatorRequests.open(run: run, state: state, prompts: [:])
        let act = acting.broadcast(run.id)
        let ready = readyForAcceptance(tasks, sessions: sessions)
        let line = OperatorLine.broadcast(run, tasks: tasks, acting: act, requests: requests, ready: ready)
        let projects = run.projectIds.compactMap(state.project(id:))
        let paused = run.state == .paused || run.state == .operatorOffline || run.intent == .paused
        return BroadcastRow(id: run.id, title: run.name, agent: AgentKind.claude.session,
                            progress: BroadcastBoard.progress(of: run, tasks: tasks),
                            projectsHelp: OperatorLine.list(projects.map(\.name)),
                            line: line, status: broadcastStatus(run, tasks: tasks, ready: ready, line: line, acting: act != nil, paused: paused),
                            isPaused: paused, isComplete: run.state == .complete)
    }

    /// The tasks of `tasks` whose workers, as `sessions` list them, all ended their turn: each waits for the
    /// Operator to accept it.
    static func readyForAcceptance(_ tasks: [TaskItem], sessions: [SessionInfo]) -> Set<UUID> {
        guard !sessions.isEmpty else { return [] }
        return Set(tasks.filter { $0.isReadyForAcceptance(in: sessions) }.map(\.id))
    }

    /// The row's mark: a request outranks everything, as on its line. A task waiting to be accepted is not at work.
    private static func broadcastStatus(_ run: OperatorRun, tasks: [TaskItem], ready: Set<UUID>, line: OperatorLine, acting: Bool,
                                        paused: Bool) -> TaskStatus {
        if line.look == .needsYou { return .needsInput }
        if run.state == .complete { return .done }
        if paused { return .idle }
        if run.state == .planning || acting { return .working }
        let working = tasks.contains { task in
            !ready.contains(task.id) && (task.operated.map { !$0.takenOver && $0.state == .working } ?? false)
        }
        return working ? .working : .idle
    }
}
