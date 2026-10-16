import Foundation

/// When each working task last showed a sign of life, on a clock of its own (spec §8, *possibly
/// stalled*). A sign of life is any change the daemon reports for one of the task's sessions —
/// its status, title, tokens, context fill or conversation — or one noted from elsewhere (a hook
/// event, a delivered message). With several tasks at work, one busy worker never keeps a silent
/// one from being noticed, and a silent one never makes a busy one look stalled.
///
/// Not judged: a task waiting on you (that time is yours — and answering it changes the session,
/// which restarts its clock), one you took over, and one not launched yet. A session that closes
/// is no sign: reconciliation deals with a worker that went away.
public struct StallWatch: Equatable, Sendable {
    public struct Changes: Equatable, Sendable {
        public var flag: [UUID], clear: [UUID]
        public init(flag: [UUID], clear: [UUID]) { self.flag = flag; self.clear = clear }
    }

    private var lastSign: [UUID: Date] = [:]
    private var lastSeen: [String: SessionInfo] = [:]

    public init() {}

    /// The daemon's sessions as they are at `now`: every task one of whose sessions is new or
    /// changed since the last call has shown a sign of life.
    public mutating func observe(_ sessions: [SessionInfo], at now: Date) {
        var seen: [String: SessionInfo] = [:]
        for session in sessions {
            seen[session.sessionId] = session
            guard let task = session.taskUUID, lastSeen[session.sessionId] != session else { continue }
            noteSign(of: task, at: now)
        }
        lastSeen = seen
    }

    public mutating func noteSign(of task: UUID, at now: Date) {
        lastSign[task] = max(lastSign[task] ?? now, now)
    }

    /// The working tasks with no sign of life for `after`, counted from their last sign or, before
    /// any, from their launch. A task id held twice is judged once, by its first copy.
    public func stalled(in state: AppState, now: Date, after: TimeInterval = OperatorTiming.stallAfter) -> Set<UUID> {
        var stalled = Set<UUID>(), judged = Set<UUID>()
        for task in state.tasks where judged.insert(task.id).inserted {
            guard let operated = task.operated, operated.state == .working, !operated.takenOver,
                  !operated.flags.contains(.waitingOnYou),
                  let since = lastSign[task.id] ?? operated.launch?.requestedAt else { continue }
            if now.timeIntervalSince(since) >= after { stalled.insert(task.id) }
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

    public static func apply(_ changes: Changes, to state: inout AppState) {
        for index in state.tasks.indices {
            let id = state.tasks[index].id
            if changes.flag.contains(id) { state.tasks[index].operated?.flags.insert(.possiblyStalled) }
            if changes.clear.contains(id) { state.tasks[index].operated?.flags.remove(.possiblyStalled) }
        }
    }
}
