import Foundation

/// When each working task last showed a sign of life, on a clock of its own (spec §8, *possibly
/// stalled*). A sign of life is any change the daemon reports for one of the task's sessions —
/// its status, title, context fill or conversation — or one noted from elsewhere (a hook
/// event, a delivered message). With several tasks at work, one busy worker never keeps a silent
/// one from being noticed, and a silent one never makes a busy one look stalled.
///
/// Not judged: a task waiting on you (that time is yours — and answering it changes the session,
/// which restarts its clock), one you took over, and one not launched yet. A session that closes
/// is no sign: reconciliation deals with a worker that went away.
///
/// Each tick, in this order: `observe` the daemon's sessions, `settle` against the state, then ask
/// `flagChanges`. `settle` restarts the clock of every task not being judged, so one that comes back
/// to work — resumed, answered, no longer taken over — counts from that tick, not from a sign
/// before it. Only a tab that runs an agent is a sign; a plain shell in the task's window is not.
///
/// A task with extra worker tabs (`open_tab`) has a clock for each, its first worker's being the task's own: one
/// busy tab never hides a silent one either. A tab at work (`WorkerTab.status`) that is quiet for `after` stalls its
/// task; one whose turn ended is not judged while another tab works, and once none does, the latest sign of any counts.
public struct StallWatch: Equatable, Sendable {
    public struct Changes: Equatable, Sendable {
        public var flag: [UUID], clear: [UUID]
        public init(flag: [UUID], clear: [UUID]) { self.flag = flag; self.clear = clear }
    }

    /// One extra tab: its task, and its key there.
    private struct Tab: Hashable, Sendable {
        let task: UUID
        let key: String
    }

    /// Each task's first worker's clock, which noted signs restart too.
    private var lastSign: [UUID: Date] = [:]
    /// Each extra tab's clock.
    private var tabSign: [Tab: Date] = [:]
    private var lastSeen: [String: SessionInfo] = [:]
    /// Every tab of the last `observe`: which of a task's tabs are at work.
    private var listed: [SessionInfo] = []

    public init() {}

    /// The daemon's sessions as they are at `now`: every task one of whose agent tabs is new or
    /// changed since the last call has shown a sign of life, on that tab's clock.
    public mutating func observe(_ sessions: [SessionInfo], at now: Date) {
        var seen: [String: SessionInfo] = [:]
        for session in sessions where Self.runsAgent(session) {
            seen[session.sessionId] = session
            guard let task = session.taskUUID, lastSeen[session.sessionId] != session else { continue }
            if let key = session.tabKey { noteSign(of: Tab(task: task, key: key), at: now) } else { noteSign(of: task, at: now) }
        }
        lastSeen = seen
        listed = sessions
    }

    /// Restarts the clock of every task that is not being judged at `now` (not working, taken over, or
    /// waiting on you), and forgets the ones no longer in `state`. Call after `observe`, before `stalled`.
    public mutating func settle(in state: AppState, at now: Date) {
        var operated = Set<UUID>()
        for task in state.tasks {
            guard let work = task.operated else { continue }
            operated.insert(task.id)
            guard !Self.isJudged(work) else { continue }
            noteSign(of: task.id, at: now)
            for tab in work.extraTabs { noteSign(of: Tab(task: task.id, key: tab.key), at: now) }
        }
        lastSign = lastSign.filter { operated.contains($0.key) }
        tabSign = tabSign.filter { operated.contains($0.key.task) }
    }

    public mutating func noteSign(of task: UUID, at now: Date) {
        lastSign[task] = max(lastSign[task] ?? now, now)
    }

    private mutating func noteSign(of tab: Tab, at now: Date) {
        tabSign[tab] = max(tabSign[tab] ?? now, now)
    }

    /// The working tasks with no sign of life for `after`, each tab counted from its last sign or its
    /// launch, whichever is later. A task id held twice is judged once, by its first copy.
    public func stalled(in state: AppState, now: Date, after: TimeInterval = OperatorTiming.stallAfter) -> Set<UUID> {
        var stalled = Set<UUID>(), judged = Set<UUID>()
        for task in state.tasks where judged.insert(task.id).inserted {
            guard let operated = task.operated, Self.isJudged(operated),
                  let since = [lastSign[task.id], operated.launch?.requestedAt].compactMap({ $0 }).max() else { continue }
            let tabs = task.workerTabs(in: listed)
            var clocks = [(busy: tabs[0].status == .working, since: since)]
            for tab in tabs.dropFirst() where tab.status != nil {
                guard let key = tab.key, let launch = operated.extraTabs.first(where: { $0.key == key })?.launch else { continue }
                clocks.append((tab.status == .working, max(tabSign[Tab(task: task.id, key: key)] ?? launch.requestedAt, launch.requestedAt)))
            }
            let busy = clocks.filter(\.busy).map(\.since)
            guard let quietSince = busy.isEmpty ? clocks.map(\.since).max() : busy.min() else { continue }
            if now.timeIntervalSince(quietSince) >= after { stalled.insert(task.id) }
        }
        return stalled
    }

    /// The tasks to flag *possibly stalled* now, and those whose flag a sign of life has cleared.
    public func flagChanges(in state: AppState, now: Date, after: TimeInterval = OperatorTiming.stallAfter) -> Changes {
        let stalled = stalled(in: state, now: now, after: after)
        var changes = Changes(flag: [], clear: []), seen = Set<UUID>()
        for task in state.tasks where seen.insert(task.id).inserted {
            guard let operated = task.operated else { continue }
            let flagged = operated.flags.contains(.possiblyStalled)
            if stalled.contains(task.id) && !flagged { changes.flag.append(task.id) }
            if !stalled.contains(task.id) && flagged { changes.clear.append(task.id) }
        }
        return changes
    }

    private static func isJudged(_ task: OperatedTask) -> Bool {
        task.state == .working && !task.takenOver && !task.flags.contains(.waitingOnYou)
    }

    /// The rule of `WorkerStarter.isWorkerTab` (the app's target, out of Core's reach): a tab that
    /// runs an agent, not a plain shell. Keep the two alike.
    private static func runsAgent(_ session: SessionInfo) -> Bool { session.agent.agentKind != nil }

    public static func apply(_ changes: Changes, to state: inout AppState) {
        for index in state.tasks.indices {
            let id = state.tasks[index].id
            if changes.flag.contains(id) { state.tasks[index].operated?.flags.insert(.possiblyStalled) }
            if changes.clear.contains(id) { state.tasks[index].operated?.flags.remove(.possiblyStalled) }
        }
    }
}
