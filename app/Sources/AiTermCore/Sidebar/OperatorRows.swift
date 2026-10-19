import Foundation

/// The operator's mark in a task's avatar group: first, while the operator drives the task, and
/// wearing the breathing accent ring while it acts on it — a message on its way, a reply being read
/// (spec §10.4). Nil when the operator has let go: the task is done, stopped or taken over.
public enum OperatorPresence: Equatable, Sendable { case driving, acting }

/// The line under a driven task's badges: where it is in its workflow and what it waits on —
/// `queued · builds on PLUTO-231`, `waiting on you · Codex asks to run npm install`, `done · 4f2a91c`.
/// `warns` draws it amber, off the accent, as `RowCaption(warns:)` does.
public struct OperatedCaption: Equatable, Sendable {
    public var text: String
    public var warns: Bool
    public init(_ text: String, warns: Bool = false) { self.text = text; self.warns = warns }
}

public extension SidebarModel {
    /// The ends a task reaches by being done: accepted, no change needed, or published (M3).
    static func isFinished(_ state: OperatedState) -> Bool {
        state == .accepted || state == .noChange || state == .published
    }

    /// An agent as a caption names it: its vendor's short name, not its CLI's display name.
    static func agentName(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .pi: "PI"
        }
    }

    /// How a caption names the task another depends on: its ticket's key, or its title.
    static func dependencyLabel(_ id: UUID, tasks: [UUID: TaskItem]) -> String {
        guard let task = tasks[id] else { return "another task" }
        return task.jira?.key ?? task.title
    }

    /// Whether the operator's mark leads `task`'s avatars: while its operation runs and the task is
    /// neither done, stopped nor taken over — and breathing while the operator acts on it.
    static func operatorPresence(task: TaskItem, run: OperatorRun?, acting: Bool) -> OperatorPresence? {
        guard let operated = task.operated, let run, run.state != .stopped, !operated.takenOver,
              !isFinished(operated.state), operated.state != .stopped else { return nil }
        return acting ? .acting : .driving
    }

    /// The workflow line under a driven task's badges; nil for a task you made yourself. `tasks` names
    /// the tasks it depends on; `run`'s open questions say what one waiting on you is asked.
    static func operatedCaption(task: TaskItem, run: OperatorRun?, tasks: [UUID: TaskItem], acting: Bool) -> OperatedCaption? {
        guard let operated = task.operated else { return nil }
        // Taken over only while the task is still going: a stopped, failed or finished one says so,
        // as `operatorPresence` lets go of it either way.
        if operated.takenOver, operated.state.isOpen, operated.state != .failed { return OperatedCaption("taken over") }
        let agent = agentName(task.agent)
        if operated.flags.contains(.waitingOnYou), !isFinished(operated.state), operated.state != .stopped {
            let asked = run?.questions.first { $0.task == task.id && $0.resolution == nil }?.text
            return OperatedCaption("waiting on you · " + (asked ?? operated.blockedReason ?? "\(agent) needs you"), warns: true)
        }
        let sha = String((operated.acceptance?.resultSHA ?? "").prefix(7))
        switch operated.state {
        case .planned:
            return OperatedCaption("planned")
        case .queued:
            if let parent = operated.stackedOn ?? operated.dependsOn.first(where: { $0.kind == .code })?.task {
                return OperatedCaption("queued · builds on " + dependencyLabel(parent, tasks: tasks))
            }
            if let first = operated.dependsOn.first {
                return OperatedCaption("queued · after " + dependencyLabel(first.task, tasks: tasks))
            }
            return OperatedCaption("queued")
        case .working:
            if operated.flags.contains(.possiblyStalled) { return OperatedCaption("working · possibly stalled", warns: true) }
            if let review = operated.agentReview, review.isRunning { return OperatedCaption("reviewing with " + agentName(review.agent)) }
            return OperatedCaption(acting ? "working · the operator is answering \(agent)" : "working")
        case .inReview:
            return OperatedCaption("in review")
        case .blocked:
            return OperatedCaption("blocked · " + (operated.blockedReason ?? "waiting on you"), warns: true)
        case .failed:
            return OperatedCaption("failed" + (operated.blockedReason.map { " · " + $0 } ?? ""), warns: true)
        case .accepted:
            return OperatedCaption("done · " + sha)
        case .noChange:
            return OperatedCaption("done · no change")
        case .published:
            switch operated.end {
            case .merge, .mergeLocal: return OperatedCaption("merged · " + sha)
            case .draftMR: return OperatedCaption("draft MR · " + sha)
            case .commit: return OperatedCaption("done · " + sha)
            }
        case .stopped:
            return OperatedCaption("stopped")
        }
    }
}

/// One operation under its operator, ready to draw on a task row's grid: the agents at work in it,
/// its name, its caption — its progress, `1 of 4 done`, or its state when that says more:
/// `paused · 2 workers still running`, `operator offline`, `done · 4 of 4` —
/// what waits on you, and the operation's state as a status mark (spec §10.3).
public struct OperationRow: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var avatars: AvatarGroup
    public var caption: String
    /// The caption in amber, off the accent: an operator gone offline.
    public var captionWarns: Bool
    /// Whether `caption` is the progress, drawn as a quiet `Badge` with the attention count beside it;
    /// otherwise it is a plain caption and the count is not drawn.
    public var showsProgress: Bool
    /// What waits on you: the open questions, and the driven tasks waiting on you or blocked that no
    /// open question already names.
    public var attention: Int
    public var status: TaskStatus
}

/// The Operator's header and its broadcasts, as the OPERATORS group draws them, on a project's
/// pattern. There is one Operator, so one section, drawn while a broadcast runs (until the plan's
/// Task 14 replaces the group with the OPERATOR heading and the broadcast row).
public struct OperatorSection: Equatable, Identifiable, Sendable {
    /// The header's name, and the section's id for folding.
    public static let name = "Operator", key = "operator"
    public var operations: [OperationRow]
    /// Folded by the person (`SidebarProjection.foldedOperators`).
    public var folded: Bool
    public var name: String { Self.name }
    public var id: String { Self.key }
    /// No operation: nothing to disclose.
    public var isEmpty: Bool { operations.isEmpty }
    /// An operator with no operation always draws folded, as an empty project does.
    public var collapsed: Bool { folded || isEmpty }
}

public extension SidebarModel {
    /// The OPERATORS group: the Operator with its broadcasts that have not ended, oldest first; none
    /// while no broadcast runs.
    static func operatorSections(state: AppState, acting: Set<UUID> = [], folded: Set<String> = []) -> [OperatorSection] {
        let live = state.runs.filter { $0.state != .stopped }
        guard !live.isEmpty else { return [] }
        let byRun = state.tasks.reduce(into: [UUID: [TaskItem]]()) { grouped, task in
            if let run = task.operated?.runId { grouped[run, default: []].append(task) }
        }
        let rows = live.map { operationRow(run: $0, tasks: byRun[$0.id] ?? [], acting: acting) }
        return [OperatorSection(operations: rows, folded: folded.contains(OperatorSection.key))]
    }

    /// One operation's row, from its run and the tasks it made.
    static func operationRow(run: OperatorRun, tasks: [TaskItem], acting: Set<UUID> = []) -> OperationRow {
        let counted = tasks.filter { ($0.operated?.state).map { $0 != .stopped } ?? false }
        let done = counted.filter { ($0.operated?.state).map(isFinished) ?? false }.count
        let working = counted.filter { $0.operated?.state == .working && $0.operated?.takenOver == false }
        let attention = attentionCount(run: run, tasks: counted)
        var row = OperationRow(id: run.id, name: run.name, avatars: agentsAtWork(working),
                               caption: "\(done) of \(counted.count) done", captionWarns: false, showsProgress: true,
                               attention: attention, status: .idle)
        func says(_ caption: String, warns: Bool = false, status: TaskStatus) -> OperationRow {
            row.caption = caption; row.captionWarns = warns; row.showsProgress = false; row.status = status
            return row
        }
        if run.state == .complete { return says("done · \(done) of \(counted.count)", status: .done) }
        switch run.state {
        case .operatorOffline:
            return says("operator offline", warns: true, status: .needsInput)
        case .paused:
            let n = working.count
            return says(n == 0 ? "paused" : "paused · \(n) \(n == 1 ? "worker" : "workers") still running", status: .idle)
        case .planning:
            return says("planning", status: .working)
        case .active, .complete, .stopped:
            let busy = !working.isEmpty || counted.contains { acting.contains($0.id) }
            row.status = attention > 0 ? .needsInput : busy ? .working : .idle
            return row
        }
    }

    /// The agents at work in an operation, each drawn once in the order its first task was made: the
    /// avatar column's two places, the second becoming `+n` past two.
    static func agentsAtWork(_ tasks: [TaskItem]) -> AvatarGroup {
        var agents: [SessionAgent] = []
        for task in tasks where !agents.contains(task.agent.session) { agents.append(task.agent.session) }
        guard agents.count > avatarMax else { return AvatarGroup(marks: agents, overflow: 0) }
        return AvatarGroup(marks: Array(agents.prefix(avatarMax - 1)), overflow: agents.count - (avatarMax - 1))
    }

    /// A folded operator's chips: its operations by state, in `statusOrder`, empty states left out —
    /// as a folded project counts its rows.
    static func operationStatusCounts(_ operations: [OperationRow]) -> [StatusCount] {
        statusOrder.compactMap { status in
            let n = operations.filter { $0.status == status }.count
            return n > 0 ? StatusCount(status: status, count: n) : nil
        }
    }

    /// Open questions, plus the open tasks waiting on you or blocked that no open question names (a
    /// finished task's leftover flag asks nothing, as `operatedCaption` ignores it).
    private static func attentionCount(run: OperatorRun, tasks: [TaskItem]) -> Int {
        let open = run.questions.filter { $0.resolution == nil }
        let asked = Set(open.compactMap(\.task))
        let waiting = tasks.filter { task in
            guard let operated = task.operated, !operated.takenOver, !isFinished(operated.state),
                  !asked.contains(task.id) else { return false }
            return operated.flags.contains(.waitingOnYou) || operated.state == .blocked
        }
        return open.count + waiting.count
    }
}
