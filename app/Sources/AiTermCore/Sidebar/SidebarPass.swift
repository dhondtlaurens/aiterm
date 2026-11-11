import Foundation

/// What one derivation of the sidebar reads of its broadcasts, derived once and handed to the broadcast's group, the
/// projects' rows and the board: each live run's open requests (`OperatorRequests.open`), and the worker tabs of the tasks
/// it was asked to match, as its sessions list them as of `now` (`TaskItem.workerTabs(in:now:)`).
public struct SidebarPass: Sendable {
    public let now: Date
    private let requests: [UUID: [BroadcastRequest]]
    private let tabs: [UUID: [WorkerTab]]

    /// The pass over `state` and `sessions` at `now`, with the tabs of `matching` matched: the live broadcast's tasks, which
    /// its group and its board read.
    public init(state: AppState, sessions: [SessionInfo], now: Date, matching: [TaskItem]) {
        self.now = now
        // An ended run asks nothing (`OperatorRequests.open`).
        requests = Dictionary(state.runs.filter { !$0.hasEnded }.map { ($0.id, OperatorRequests.open(run: $0, state: state)) },
                              uniquingKeysWith: { first, _ in first })
        let index = WorkerSessions(sessions)
        tabs = Dictionary(matching.map { ($0.id, $0.workerTabs(in: index, now: now)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The pass the sidebar derives: the live broadcast's tasks matched.
    public init(state: AppState, sessions: [SessionInfo], now: Date) {
        self.init(state: state, sessions: sessions, now: now, matching: state.activeRun.map { state.tasks(inRun: $0.id) } ?? [])
    }

    /// The open requests of `run`; none for one that ended.
    public func requests(of run: UUID) -> [BroadcastRequest] { requests[run] ?? [] }

    /// The worker tabs of `task` as of `now`, when it was one matched; nil for another, which its reader matches itself.
    public func tabs(of task: UUID) -> [WorkerTab]? { tabs[task] }
}
