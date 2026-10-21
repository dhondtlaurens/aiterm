import Foundation

/// The broadcast's group under the OPERATOR heading (decided 21 Oct 2026): a header that folds as a project's
/// does, the Operator's own row first under it, then every task the broadcast holds, moved out of its project,
/// the queued ones last. Its own section of the sidebar, beside the projects' `entries`, and drawn above them.
public struct BroadcastSection: Equatable, Identifiable, Sendable {
    public var header: BroadcastRow
    public var operatorRow: OperatorRow
    /// The broadcast's tasks in the plan's order, the queued ones (`TaskRow.queued`) last.
    public var tasks: [TaskRow]
    /// Folded to its header, as you left it (`AppState.foldedRuns`).
    public var folded: Bool

    /// The run's: the header's id, and its tag in the list.
    public var id: UUID { header.id }

    /// What needs you in it, in the order it is drawn: the Operator's row, then its tasks. Only what is amber:
    /// the group's routine, a turn ended or a task done, stays inside it.
    public var needingAttention: [RowID] {
        (operatorRow.status == .needsInput ? [RowID.operation(header.id)] : [])
            + tasks.filter { $0.status == .needsInput }.map { RowID.task($0.id) }
    }

    public var needsAttention: Bool { !needingAttention.isEmpty }

    /// The folded header's chips: what needs you, said once, as one amber count. Nothing else of what it hides.
    public var attention: [StatusCount] {
        let count = needingAttention.count
        return count > 0 ? [StatusCount(status: .needsInput, count: count)] : []
    }

    /// The first row of the group that needs you: where its amber chip goes.
    public var firstNeedingAttention: RowID? { needingAttention.first }
}

/// The broadcast's header, a value (spec §3, §13): its name, its progress, `2 of 8`, and `paused · 2 of 8`
/// while paused, its projects in the tooltip with its whole status line, which the board's band says too.
public struct BroadcastRow: Equatable, Identifiable, Sendable {
    /// The run's id.
    public var id: UUID
    public var title: String
    /// `2 of 8`, finished of planned; nil until the first plan is in Todo.
    public var progress: String?
    /// Every project, as a sentence lists them: the header's tooltip.
    public var projectsHelp: String
    /// The broadcast's status line (`OperatorLine.broadcast`), as its board's band says it: the header's tooltip.
    public var line: OperatorLine
    /// Paused by you, or its Operator's window closed: its menu offers Resume Broadcast.
    public var isPaused: Bool
    /// Every task done (`.complete`), its summary written or not: its menu offers neither Pause nor Resume.
    public var isDone: Bool
    /// Done, and its summary settled (`RunSummary.isSettled`): written, or not coming.
    public var isComplete: Bool

    /// What the header says after its name: the progress, and `paused` before it while the broadcast is paused.
    public var headerProgress: String? {
        guard isPaused else { return progress }
        return (["paused"] + [progress].compactMap { $0 }).joined(separator: " · ")
    }
}

/// The Operator's own row, first in the broadcast's group: a task row's grid, Claude's mark as its avatar, the
/// title `Operator`, and a line and a mark from its own session alone: its act, what it does between turns,
/// that it asks you in its window, or that its window is closed. Never a task's request: those are the
/// tasks' rows'. Its id is its own (`id(of:)`), so the list, which keys a row by one UUID, tells it from
/// the header, which has the run's.
public struct OperatorRow: Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The broadcast it runs: what its selection (`.operation`) names.
    public var runId: UUID
    /// Claude Code, the only agent it runs on (spec §13).
    public var agent: SessionAgent
    public var line: OperatorLine
    public var status: TaskStatus

    /// The title it is drawn with.
    public static let title = "Operator"

    /// The row's id for the broadcast `run`: stable, and never the run's own.
    public static func id(of run: UUID) -> UUID {
        var bytes = run.uuid
        bytes.0 ^= 0xFF; bytes.7 ^= 0xFF; bytes.15 ^= 0xFF
        return UUID(uuid: bytes)
    }
}

public extension TaskItem {
    /// Planned by the Operator and not started: it has no window yet, and choosing its row opens nothing.
    var isQueuedByOperator: Bool { operated.map { $0.state == .planned || $0.state == .queued } ?? false }
}

public extension ProjectSection {
    /// The header's tooltip and a line of Remove Project's question while the live broadcast holds worktrees
    /// in the project: its tasks are drawn under the broadcast, so the header says they are there.
    static func operatorHelp(worktrees: Int) -> String {
        "The Operator holds \(worktrees) \(worktrees == 1 ? "worktree" : "worktrees") in this project."
    }

    /// `operatorHelp(worktrees:)` for this project, nil while the Operator holds none of its worktrees.
    var operatorHelp: String? { operatorWorktrees > 0 ? Self.operatorHelp(worktrees: operatorWorktrees) : nil }
}

public extension AppState {
    /// Folds or opens the broadcast's group, as `Project.collapsed` does a project's.
    mutating func setFolded(run id: UUID, _ folded: Bool) {
        if folded { foldedRuns.insert(id) } else { foldedRuns.remove(id) }
    }
}

public extension SidebarModel {
    /// The broadcast's group: `AppState.activeRun`'s, or nil while there is none. Its tasks' rows are made as a
    /// project's are (`taskRow`), from the same tabs, branches and diffs. `acting` is what the Operator is doing
    /// now, as `OperatorController.acting` says it; `sessions` the tabs as iTerm2 lists them.
    static func broadcastSection(state: AppState, sessions: [SessionInfo], branchByCwd: [String: String] = [:],
                                 diffByTask: [UUID: DiffStat] = [:], acting: OperatorActs = .none) -> BroadcastSection? {
        guard let run = state.activeRun, let header = broadcastRow(state: state, acting: acting, sessions: sessions) else { return nil }
        let tasks = state.tasks(inRun: run.id)
        let tabs = Tabs(sessions), operated = OperatedLookup(state: state, acting: acting.tasks)
        let rows = tasks.map { taskRow($0, tabs: tabs, operated: operated, branchByCwd: branchByCwd, diffByTask: diffByTask) }
        let requests = OperatorRequests.open(run: run, state: state, prompts: [:])
        return BroadcastSection(header: header,
                                operatorRow: operatorRow(run, tasks: tasks, acting: acting, requests: requests, sessions: sessions),
                                tasks: rows.filter { !$0.queued } + rows.filter(\.queued),
                                folded: state.foldedRuns.contains(run.id))
    }

    /// The broadcast's header: `AppState.activeRun`'s, or nil while there is none. `sessions` tell a task whose
    /// workers are done (`readyForAcceptance`), which its line reads.
    static func broadcastRow(state: AppState, acting: OperatorActs = .none, sessions: [SessionInfo] = []) -> BroadcastRow? {
        guard let run = state.activeRun else { return nil }
        let tasks = state.tasks.filter { $0.operated?.runId == run.id }
        let requests = OperatorRequests.open(run: run, state: state, prompts: [:])
        let line = OperatorLine.broadcast(run, tasks: tasks, acting: acting.broadcast(run.id), requests: requests,
                                          ready: readyForAcceptance(tasks, sessions: sessions))
        let projects = run.projectIds.compactMap(state.project(id:))
        return BroadcastRow(id: run.id, title: run.name, progress: BroadcastBoard.count(of: run, tasks: tasks),
                            projectsHelp: OperatorLine.list(projects.map(\.name)), line: line,
                            isPaused: run.state == .paused || run.state == .operatorOffline || run.intent == .paused,
                            isDone: run.state == .complete, isComplete: OperatorLine.summary(of: run)?.isSettled == true)
    }

    /// The Operator's row: its own session's line (`OperatorLine.session`), nothing of its tasks, which the
    /// header's tooltip, the board's band and the tasks' own rows say. It asks you while its tab waits on input
    /// or one of its own questions, the broadcast's and no task's, is open; its window is closed while the run
    /// is `operatorOffline`; else paused, `writing the summary` once every task is done and `done · summary ready`
    /// once it is written (`done` if AiTerm gave up on it), its act, `working` while its session works, and `waiting
    /// for its tasks` between turns. Its mark follows the line: amber when it asks, spinning while it acts, works or
    /// writes the summary, the accent dot once the summary is settled, else the idle ring: a turn ended is routine.
    static func operatorRow(_ run: OperatorRun, tasks: [TaskItem], acting: OperatorActs, requests: [BroadcastRequest],
                            sessions: [SessionInfo]) -> OperatorRow {
        let tab = run.operatorSessionId.flatMap { id in sessions.first { $0.sessionId == id } } ?? operatorTab(of: run.id, in: sessions)
        let asks = requests.contains { $0.runId == run.id && $0.taskId == nil }
        let summary = OperatorLine.summary(of: run)
        let line = OperatorLine.session(acting: acting.broadcast(run.id), working: tab?.state == .working,
                                        asking: asks || tab?.state == .needsInput, windowClosed: run.state == .operatorOffline,
                                        paused: run.state == .paused || run.intent == .paused,
                                        summary: summary ?? .notYet, tasks: tasks)
        let status: TaskStatus = switch line.look {
        case .needsYou: .needsInput
        case .acting: .working
        case .quiet, .ended: summary?.isSettled == true ? .done : .idle
        }
        return OperatorRow(id: OperatorRow.id(of: run.id), runId: run.id, agent: AgentKind.claude.session, line: line, status: status)
    }

    /// The Operator's tab: the first tab tagged with the run, by its place in the window.
    static func operatorTab(of run: UUID, in sessions: [SessionInfo]) -> SessionInfo? {
        sessions.filter { $0.taskUUID == run }.min { ($0.tabIndex, $0.sessionId) < ($1.tabIndex, $1.sessionId) }
    }

    /// The tasks of `tasks` whose workers, as `sessions` list them, all ended their turn: each waits for the
    /// Operator to accept it.
    static func readyForAcceptance(_ tasks: [TaskItem], sessions: [SessionInfo]) -> Set<UUID> {
        guard !sessions.isEmpty else { return [] }
        return Set(tasks.filter { $0.isReadyForAcceptance(in: sessions) }.map(\.id))
    }
}
