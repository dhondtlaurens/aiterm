import Foundation

/// What Backpack Mode pushes to the iPhone paired with iTerm2 (iTerm2 Buddy) while the lid is shut:
/// the Backpack sheet's Notifies, remembered (`BackpackSettings.pushes`).
public enum BackpackPushes: String, CaseIterable, Sendable {
    /// A row that moves to Needs input: the default.
    case needsInput
    /// That, and a row that moves to Done.
    case needsInputOrDone
    case never

    /// The row statuses that push.
    public var statuses: Set<TaskStatus> {
        switch self {
        case .needsInput: [.needsInput]
        case .needsInputOrDone: [.needsInput, .done]
        case .never: []
        }
    }
}

/// A task or terminal row as a push reads it: which row, its status as the sidebar draws it, and
/// the agent a push names it by.
public struct PushRow: Equatable, Sendable {
    /// A sidebar row a push can be about: a task's or a terminal's, as `RowID` names them, or the
    /// broadcast's, by its run.
    public enum ID: Hashable, Sendable { case task(UUID), terminal(UUID), broadcast(UUID) }

    public var id: ID
    public var status: TaskStatus
    /// The agent of the row's first tab, by tab order, in `status`; nil when none is known.
    public var agent: AgentKind?

    public init(id: ID, status: TaskStatus, agent: AgentKind?) {
        self.id = id
        self.status = status
        self.agent = agent
    }

    /// The rows the Dock badge counts — each project's terminals, then its tasks, less the tasks on
    /// their way out — with their tabs matched as `SidebarModel` matches them: a task's by its tag, a
    /// terminal's by its window (`terminalWindows`, by terminal id).
    public static func rows(sections: [ProjectSection], sessions: [SessionInfo], terminalWindows: [UUID: String],
                            skippingTasks: Set<UUID>) -> [PushRow] {
        let byTask = Dictionary(grouping: sessions, by: \.taskUUID)
        let byWindow = Dictionary(grouping: sessions, by: \.windowId)
        return sections.flatMap { section in
            section.terminals.map { row(.terminal($0.id), $0.status, terminalWindows[$0.id].flatMap { byWindow[$0] } ?? []) }
                + section.tasks.filter { !skippingTasks.contains($0.id) }.map { row(.task($0.id), $0.status, byTask[$0.id] ?? []) }
        }
    }

    /// The broadcast's row, nil while none runs. It needs you only for what moves no task row — the
    /// Operator's own question, a blocked task, a task with a problem — as a worker's prompt is its task
    /// row's to push; it is done once its debrief is ready, and named by the Operator's agent.
    public static func broadcast(state: AppState) -> PushRow? {
        guard let run = state.activeRun else { return nil }
        let asks = OperatorRequests.open(run: run, state: state, prompts: [:]).contains { $0.kind != .permission }
        return PushRow(id: .broadcast(run.id), status: asks ? .needsInput : run.state == .complete ? .done : .idle,
                       agent: .claude)
    }

    private static func row(_ id: ID, _ status: TaskStatus, _ tabs: [SessionInfo]) -> PushRow {
        PushRow(id: id, status: status, agent: tabs.filter { $0.state == status }.min { $0.tabIndex < $1.tabIndex }?.agent.agentKind)
    }
}

/// One push: a title and one or two sentences naming the agents that need you, or finished, and
/// nothing else — never a project, a task, a branch, a path or what an agent asks. It lands on a lock
/// screen, and iTerm2 hands it to its push relay and to Apple as plain text.
public struct BackpackPush: Equatable, Sendable {
    public static let title = "AiTerm"
    public var title: String
    public var body: String

    /// One agent per row: those of the rows that need input, and of those that finished.
    public init(needsInput: [AgentKind?], done: [AgentKind?]) {
        title = Self.title
        body = [Self.sentence(needsInput, one: "needs your input", several: "need your input"),
                Self.sentence(done, one: "finished", several: "finished")].compactMap { $0 }.joined(separator: " ")
    }

    /// A row by its agent's name; several by their number alone.
    private static func sentence(_ agents: [AgentKind?], one: String, several: String) -> String? {
        switch agents.count {
        case 0: nil
        case 1: "\(agents[0]?.displayName ?? "An agent") \(one)."
        default: "\(agents.count) agents \(several)."
        }
    }
}

/// When a push goes (spec 2026-10-20). Fed each 5 s check while Backpack Mode is on, it pushes a row
/// that moves into a chosen status while the person is away, and holds pushes back so that a few
/// carry the news:
///
/// - the first row waiting holds `hold`, so a prompt something else answers never buzzes and rows
///   moving seconds apart fold into one push, which carries every row still waiting when it goes;
/// - one push per `spacing` at most: the rows that come due meanwhile ride on the next;
/// - a row is not pushed for the same status again within `rowRepeat` of its last push. One asking
///   again sooner waits for that to pass and, still waiting then, goes: no question is lost.
///
/// Not away — the lid open, or Never chosen — it pushes nothing and starts over, keeping only the
/// rows' statuses: what was waiting when the person looked is theirs, so a row already waiting when
/// the lid shuts is never pushed. Offline — the Mac off the hotspot — it follows the rows but sends
/// nothing: what comes due meanwhile goes with the first check back online. A row the sidebar no
/// longer has is forgotten.
public struct BackpackPushQueue: Sendable {
    public static let hold: TimeInterval = 30
    public static let spacing: TimeInterval = 300
    public static let rowRepeat: TimeInterval = 900

    private struct Waiting: Sendable {
        var status: TaskStatus
        var since: Date
    }

    /// Each row's status at the last check; nil until a check has seen the rows, so the first one
    /// only takes them in.
    private var seen: [PushRow.ID: TaskStatus]?
    private var waiting: [PushRow.ID: Waiting] = [:]
    /// When each row was last pushed, by status.
    private var pushed: [PushRow.ID: [TaskStatus: Date]] = [:]
    private var lastPush: Date?

    public init() {}

    /// One check: the push to send now, if one is due. `online` is whether one could go out.
    public mutating func check(_ rows: [PushRow], away: Bool, pushes: BackpackPushes, online: Bool = true,
                               at now: Date) -> BackpackPush? {
        guard away, pushes != .never else {
            reset()
            seen = Self.statuses(of: rows)
            return nil
        }
        note(rows, pushing: pushes.statuses, at: now)
        guard online, waiting.contains(where: { readyAt($0.key, $0.value) <= now }),
              lastPush.map({ $0.addingTimeInterval(Self.spacing) <= now }) ?? true else { return nil }
        return send(waiting.filter { !isRepeat($0.key, $0.value.status, at: now) }, rows: rows, at: now)
    }

    /// The mode ended itself and the Mac is about to sleep: the rows as they stand now, what moved
    /// since the last check among them, and every row still waiting goes at once, hold and spacing
    /// aside. The queue starts over. Only for a person away, with the Mac online: the caller decides.
    public mutating func flush(_ rows: [PushRow], pushes: BackpackPushes, at now: Date) -> BackpackPush? {
        defer { reset() }
        note(rows, pushing: pushes.statuses, at: now)
        return send(waiting.filter { !isRepeat($0.key, $0.value.status, at: now) }, rows: rows, at: now)
    }

    /// The mode is off: nothing waits, nothing was pushed, and the next check only takes the rows in.
    public mutating func reset() {
        seen = nil
        waiting = [:]
        pushed = [:]
        lastPush = nil
    }

    /// A row that moved into a status that pushes starts waiting; one that left the status it waits
    /// in, or the sidebar, stops.
    private mutating func note(_ rows: [PushRow], pushing statuses: Set<TaskStatus>, at now: Date) {
        let current = Self.statuses(of: rows)
        if let seen {
            for row in rows where statuses.contains(row.status) && seen[row.id] != row.status {
                waiting[row.id] = Waiting(status: row.status, since: now)
            }
        }
        waiting = waiting.filter { current[$0.key] == $0.value.status }
        pushed = pushed.filter { current[$0.key] != nil }
        seen = current
    }

    /// Held long enough, and past its repeat.
    private func readyAt(_ id: PushRow.ID, _ waiting: Waiting) -> Date {
        max(waiting.since.addingTimeInterval(Self.hold), repeatEnds(id, waiting.status) ?? .distantPast)
    }

    private func isRepeat(_ id: PushRow.ID, _ status: TaskStatus, at now: Date) -> Bool {
        repeatEnds(id, status).map { $0 > now } ?? false
    }

    private func repeatEnds(_ id: PushRow.ID, _ status: TaskStatus) -> Date? {
        pushed[id]?[status]?.addingTimeInterval(Self.rowRepeat)
    }

    private mutating func send(_ due: [PushRow.ID: Waiting], rows: [PushRow], at now: Date) -> BackpackPush? {
        guard !due.isEmpty else { return nil }
        let agentOf = Dictionary(rows.map { ($0.id, $0.agent) }, uniquingKeysWith: { first, _ in first })
        func agents(in status: TaskStatus) -> [AgentKind?] {
            due.filter { $0.value.status == status }.map { agentOf[$0.key] ?? nil }
        }
        let push = BackpackPush(needsInput: agents(in: .needsInput), done: agents(in: .done))
        for (id, row) in due {
            pushed[id, default: [:]][row.status] = now
            waiting[id] = nil
        }
        lastPush = now
        return push
    }

    private static func statuses(of rows: [PushRow]) -> [PushRow.ID: TaskStatus] {
        Dictionary(rows.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
    }
}
