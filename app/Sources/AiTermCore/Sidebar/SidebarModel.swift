import Foundation
import Synchronization

/// A row's status: its tabs' states, aggregated (`SidebarModel.aggregate`) — the four a tab has, and
/// `background`, which no tab reports: a turn that ended with work it left running, which wakes the agent again
/// (proposal Background work on your own tasks B, 22 Oct 2026).
public enum TaskStatus: Equatable, Hashable, Sendable, CaseIterable {
    /// `waiting`: a task the Operator drives that waits on a turn, the Operator or a person: its worker's turn ended
    /// and the Operator is to read it, or its done condition is someone else's to meet. Only `TaskRow.presentingOperator` sets it;
    /// a tab never does.
    case idle, working, needsInput, background, waiting, done

    /// A tab's state as a row's.
    public init(_ state: SessionState) {
        switch state {
        case .idle: self = .idle
        case .working: self = .working
        case .needsInput: self = .needsInput
        case .done: self = .done
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs input"
        case .background: return "In background"
        case .waiting: return "Waiting"
        case .done: return "Done"
        }
    }

    /// The two statuses that make a task of your own or a terminal wait on you (`TaskRow.needsYou`). Not `background`:
    /// the agent takes its turn up again by itself. Not `waiting`: the Operator or someone else moves next.
    public var needsAttention: Bool { self == .done || self == .needsInput }
}

public extension SessionInfo {
    /// The tab without the context fill and conversation id that no row draws.
    var rowRelevant: SessionInfo {
        var row = self
        row.contextPercent = nil
        row.conversationId = nil
        return row
    }
}

/// A row's marks: up to `SidebarModel.avatarMax`, the last becoming `+n`. A task the Operator drives
/// draws its own agents, as any task does: the Operator speaks on its line (`OperatorLine`).
public struct AvatarGroup: Equatable, Sendable {
    public var marks: [SessionAgent]; public var overflow: Int
    /// Whether the marks stand for no running agent: a task a signal started with no agent listed draws its agent's mark
    /// faded (`SidebarModel.mutedAvatars`), so the signals disc rests on an avatar rather than on nothing.
    public var muted = false
    public init(marks: [SessionAgent], overflow: Int, muted: Bool = false) {
        self.marks = marks; self.overflow = overflow; self.muted = muted
    }
}
/// A row's branch line (design canvas, "Branch awareness · 17 Sep"): the branch of the tab you are
/// looking at, how many *other* branches the same window has open, and whether that branch is not
/// the one the row is bound to. `detail` is the hover text; it is empty when there is nothing to
/// explain.
public struct BranchLabel: Equatable, Sendable {
    public var name: String, extra: Int, drifted: Bool, detail: String
    public init(name: String, extra: Int, drifted: Bool, detail: String) {
        self.name = name; self.extra = extra; self.drifted = drifted; self.detail = detail
    }
    public static let none = BranchLabel(name: "", extra: 0, drifted: false, detail: "")
}
/// `jiraKey` and `mr` are carried separately from the branch because the sidebar draws each as its
/// own chip. A task has at most a ticket; a review has at most a merge request. `diff` is what the
/// VS Code badge extends to; `nil` draws the plain mark.
public struct TaskRow: Equatable, Identifiable, Sendable {
    public var id: UUID, title: String, jiraKey: String?, jiraUrl: String?, mr: MergeRequestRef?
    public var branch: BranchLabel, avatars: AvatarGroup, status: TaskStatus
    public var diff: BaseDiff? = nil
    /// Whether the ticket is a GitLab issue (`#53`) rather than a Jira ticket: its mark, and on a
    /// review whose merge request is GitLab's too, one badge for both.
    public var ticketIsGitLabIssue = false
    /// The status line of a task the Operator drives (`OperatorLine.task`), its row's third line; nil for a
    /// task you made yourself or took over. That line is the Operator's alone: a test run on a task of your own is
    /// not drawn as one (29 Oct 2026); it shows only as background work, on the row's mark and its card.
    public var operatorLine: OperatorLine? = nil
    /// The existing mark's work card, also available while working or asking. Display facts do
    /// not change the row's status or its Operator line (`SidebarModel.displayJobs`).
    public var background: [BackgroundJob] = []
    /// The trailing mark: its status's, or for a driven task the check once the Operator's work ended or the pause
    /// sign during your pause. The view draws the spinner over it while the row is being removed or archived.
    public var mark: TaskRowMark = .status(.idle)
    /// Whether the row waits on you: a task of your own done or needing input, a driven task only needing input.
    /// What the Dock badge, Focus View and a folded heading count.
    public var needsYou = false
    /// Whether the Operator's work on it is through: a folded heading counts it in
    /// its green finished chip, apart from the statuses. Only `TaskRow.presentingOperator` sets it, from `SignalTask.isFinished`.
    public var finished = false
    /// Whether a folded heading counts it in the finished chip: finished and drawing the finished mark. A finished task
    /// you continue (its Then kept it) is counted by what its row draws while its worker asks or works.
    public var countsAsFinished: Bool { finished && mark == .ended }
    /// The signal that started the task or runs it now, by name, for a task a signal started (`TaskItem.signalOrigin`)
    /// or the Operator holds (`signalTask`): its live name, or "<saved name> (removed)" once the signal is gone. Its
    /// avatar wears the signals disc and VoiceOver says "Started by …"; nil for a task you made.
    public var startedBySignal: String? = nil
    /// "Task" or "Review", as its menu names it.
    public var kindName = "Task"
    public var worktreePath = ""
    /// The task's own branch, which VoiceOver reads after the title; `branch` is the one its tabs are on now.
    public var savedBranch = ""
    /// Whether the task has a window, which choosing it focuses rather than opens.
    public var windowOpen = false
    /// Whether the Operator drives it (`TaskItem.isUnderOperator`): its menu offers Take Over.
    public var underOperator = false
    /// Project-local movement within the task or review group, excluding Operator-owned rows.
    /// Derived with the list, so a menu does not observe the whole workspace.
    public var canMoveUp = false, canMoveDown = false
    public func canMove(_ step: MoveStep) -> Bool { step == .up ? canMoveUp : canMoveDown }
}
/// A task row's trailing mark: its status's `StatusMark`, the check once the Operator's work on the task ended, or
/// the pause sign while paused. A session in use (working, asking, background work) keeps its own mark.
public enum TaskRowMark: Equatable, Sendable {
    case status(TaskStatus), ended, pauseSign

    public init(status: TaskStatus, line: OperatorLine?, paused: Bool = false) {
        if paused { self = .pauseSign }
        else if line?.look == .ended, ![.working, .needsInput, .background].contains(status) { self = .ended }
        else { self = .status(status) }
    }
}
/// How far a task's checkout has moved from the branch it started at — a task's base, a review's
/// merge-request target. The VS Code badge draws only the counts, `+12 −3`; the base it measures
/// against is named in `help`, so the badge spends no width on it.
public struct BaseDiff: Equatable, Sendable {
    public var base: String, stat: DiffStat
    public init(base: String, stat: DiffStat) { self.base = base; self.stat = stat }

    public var help: String {
        let counts = (stat.added > 0 ? ["\(stat.added) added"] : []) + (stat.removed > 0 ? ["\(stat.removed) removed"] : [])
        return "Open in VS Code \u{2014} " + counts.joined(separator: ", ") + " against " + base
    }
}
/// A terminal row is as live as a task row: the avatars are the agents running in its iTerm2
/// window and the status is aggregated over them, so starting Claude in a terminal shows up here.
public struct TerminalRow: Equatable, Identifiable, Sendable {
    public var id: UUID, name: String, branch: BranchLabel, avatars: AvatarGroup, status: TaskStatus
    /// The same work card as a task row's (`SidebarModel.displayJobs`).
    public var background: [BackgroundJob] = []
    /// Whether the terminal waits on you: done or needing input, as a task of your own.
    public var needsYou = false
}
/// How many of a project's rows sit in one status — the chips a collapsed project header draws
/// in place of the task and terminal rows it is hiding.
public struct StatusCount: Equatable, Sendable {
    public var status: TaskStatus, count: Int
    public init(status: TaskStatus, count: Int) { self.status = status; self.count = count }
}
/// `canMoveUp` and `canMoveDown` say whether "Move up" and "Move down" would do anything — the first
/// item has no "up", the last no "down" — worked out with the list rather than asked of the workspace
/// by each row, whose menu would then redraw on every change to it. A locked workspace moves nothing,
/// which the row adds.
public struct ProjectSection: Equatable, Identifiable, Sendable {
    public var id: UUID { project.id }; public var project: Project, tasks: [TaskRow], terminals: [TerminalRow]
    public var canMoveUp = false, canMoveDown = false
    /// No task and no terminal of its own: nothing to disclose. A project left with only the Operator's
    /// tasks is empty too: they are drawn under their signals.
    public var isEmpty: Bool { tasks.isEmpty && terminals.isEmpty }
    /// Whether the section draws collapsed. An empty project always does, whatever it stored, and
    /// returns to its stored state once a row lands in it — so nothing is written for it.
    public var collapsed: Bool { project.collapsed || isEmpty }
    /// Whether a row in it is waiting on you: finished (blue) or asking (orange).
    public var needsAttention: Bool { tasks.contains(where: \.needsYou) || terminals.contains(where: \.needsYou) }
    public func canMove(_ step: MoveStep) -> Bool { step == .up ? canMoveUp : canMoveDown }
}
/// A divider as the sidebar draws it: the rule, and which way it can move, as ``ProjectSection``.
public struct DividerEntry: Equatable, Identifiable, Sendable {
    public var divider: SidebarDivider
    public var canMoveUp: Bool, canMoveDown: Bool
    public var id: UUID { divider.id }
    public init(divider: SidebarDivider, canMoveUp: Bool, canMoveDown: Bool) {
        self.divider = divider; self.canMoveUp = canMoveUp; self.canMoveDown = canMoveDown
    }
    public func canMove(_ step: MoveStep) -> Bool { step == .up ? canMoveUp : canMoveDown }
}
/// One row of the sidebar's top level, ready to draw: a project with its rows, or a divider.
public enum SidebarEntry: Equatable, Identifiable, Sendable {
    case project(ProjectSection)
    case divider(DividerEntry)
    public var id: UUID {
        switch self {
        case .project(let s): return s.id
        case .divider(let d): return d.id
        }
    }
}
/// One reading, a half of a footer row: `wk ◔ 84% Mon 21:00`. The ring beside the number is drawn from
/// `percent`, so there is no rendered bar to carry. `reset` is nil for a reading that never clears —
/// the context fill, which is emptied by compaction rather than by the clock, and the Mac's own
/// readings, which are now. `resetInFull` is the same time with its weekday spelt out, for `help`.
public struct UsageLine: Equatable, Sendable {
    /// What a segment measures: a conversation's context fill, one of a vendor's account windows, or
    /// one of the Mac's readings (`MachineReadings`). The footer prints `shortLabel`; the tooltip
    /// and VoiceOver say `name`.
    public enum Window: Equatable, Sendable, CaseIterable {
        case context, weekly, fiveHour
        case cpu, ram, battery

        /// The glyphs before the ring: `ctx`, `wk`, `5h`, `cpu`, `ram`, `bat`.
        public var shortLabel: String {
            switch self {
            case .context: "ctx"
            case .weekly: "wk"
            case .fiveHour: "5h"
            case .cpu: "cpu"
            case .ram: "ram"
            case .battery: "bat"
            }
        }

        /// The window in words: "Context", "Weekly limit", "5-hour limit", "CPU", "Memory", "Battery".
        public var name: String {
            switch self {
            case .context: "Context"
            case .weekly: "Weekly limit"
            case .fiveHour: "5-hour limit"
            case .cpu: "CPU"
            case .ram: "Memory"
            case .battery: "Battery"
            }
        }
    }

    public var window: Window; public var percent: Int; public var reset: String?; public var warning: Bool
    public var resetInFull: String? = nil

    public init(window: Window, percent: Int, reset: String? = nil, warning: Bool, resetInFull: String? = nil) {
        self.window = window
        self.percent = percent
        self.reset = reset
        self.warning = warning
        self.resetInFull = resetInFull
    }

    /// The segment in words — its tooltip and its VoiceOver label: "Weekly limit, 61 % used, resets
    /// Friday 23:33", "Context 84 % full", or "CPU 87 % busy, slowed by heat". A Mac reading's
    /// amber names the warning macOS raised, since the number alone does not say why it is amber.
    public var help: String {
        switch window {
        case .context: return "\(window.name) \(percent) % full"
        case .weekly, .fiveHour:
            return "\(window.name), \(percent) % used" + ((resetInFull ?? reset).map { ", resets \($0)" } ?? "")
        case .cpu: return "\(window.name) \(percent) % busy" + (warning ? ", slowed by heat" : "")
        case .ram: return "\(window.name) \(percent) % used" + (warning ? ", under pressure" : "")
        case .battery:
            return "\(window.name) \(percent) %" + (warning ? ", Backpack Mode turns off at \(BackpackSettings.cutoff) %" : "")
        }
    }
}
/// A vendor's single footer row: its ordered windows, or a note when there is nothing to draw.
/// `warning` marks a note that says the feed is broken rather than merely quiet — the footer draws
/// it amber — so the footer never has to recognise a note by its wording.
public struct UsageVendorRow: Equatable, Sendable {
    public var vendor: AgentKind; public var lines: [UsageLine]; public var note: String?
    public var warning = false
}
/// The footer's first row: what runs in the selected task's or terminal's active tab and its `ctx` line,
/// absent for a shell and until the agent has reported it.
public struct UsageTaskRow: Equatable, Sendable {
    public var agent: SessionAgent; public var context: UsageLine?
    public init(agent: SessionAgent, context: UsageLine?) {
        self.agent = agent; self.context = context
    }
}

/// A sidebar row that can have a window: a task, a terminal, or the Operator's row.
/// Focus View steps through them, and the Dock badge counts them.
public enum RowID: Hashable, Sendable {
    case task(UUID), terminal(UUID), operatorChat

    public var id: UUID {
        switch self {
        case .task(let id), .terminal(let id): id
        case .operatorChat: OperatorSession.rowID
        }
    }
}

public enum SidebarModel {
    /// Two marks, the second becoming `+n` once there are more: `AvatarGroupView` is a fixed column
    /// two marks wide, so every row's title starts at the same x.
    public static let avatarMax = 2
    public static let warningThreshold = 80

    public static func aggregate(_ states: [SessionState]) -> TaskStatus {
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.working) { return .working }
        if states.contains(.done) { return .done }
        return .idle
    }

    /// A row's status from its tabs: as their states say, except that a row whose every tab ended its turn, one of
    /// them with work still running, is `background` — between working, which wins while any tab works, and done.
    public static func aggregate(tabs: [SessionInfo]) -> TaskStatus {
        let status = aggregate(tabs.map(\.state))
        return (status == .done || status == .idle) && !backgroundJobs(of: tabs).isEmpty ? .background : status
    }

    /// What a row's tabs that ended their turn left running that wakes them again (`WorkItem.holdsTurn`), in tab order,
    /// then every tab's active test run: a tab still at work has started a new turn, which waits on nothing yet.
    public static func backgroundJobs(of tabs: [SessionInfo]) -> [BackgroundJob] {
        let ended = tabs.filter(\.state.turnEnded).sorted { $0.tabIndex < $1.tabIndex }
        let jobs = ended.flatMap { $0.work.filter(\.holdsTurn).map(\.job) }
        let tests = tabs.compactMap(\.testActivity).filter(\.isActive)
        return jobs + tests.map { BackgroundJob(kind: .shell, text: $0.detail) }
    }

    /// A row's work card: every tab's whole work list in tab order, whatever holds a turn, each job naming its tab's
    /// vendor, then the active test runs of the tabs that ended their turn, as in `backgroundJobs`.
    public static func displayJobs(of tabs: [SessionInfo]) -> [BackgroundJob] {
        let jobs = tabs.sorted { $0.tabIndex < $1.tabIndex }.flatMap { tab in
            tab.work.map { item in
                var job = item.displayJob
                job.agent = tab.agent
                return job
            }
        }
        let tests = tabs.filter(\.state.turnEnded).compactMap(\.testActivity).filter(\.isActive)
        return jobs + tests.map { BackgroundJob(kind: .shell, text: $0.detail) }
    }

    /// The order the chips are drawn in: a task's life, left to right. Not the urgency order
    /// `aggregate` uses — these sit still on a header, so a stable reading order beats ranking.
    public static let statusOrder: [TaskStatus] = [.idle, .working, .waiting, .needsInput, .done]

    /// Per-status row counts for a collapsed project, empty statuses left out: a project with
    /// nothing waiting on it should draw no chip at all rather than a row of zeroes. A collapsed
    /// project hides terminal rows as well as task rows, so its summary includes both — which also
    /// keeps a coding agent launched in a plain terminal visible after collapse.
    /// A row in the background counts with working: its agent takes the turn up again by itself. A waiting row has
    /// its own count: nothing of it runs.
    public static func statusCounts(tasks: [TaskRow], terminals: [TerminalRow] = []) -> [StatusCount] {
        statusCounts(tasks.map(\.status) + terminals.map(\.status))
    }

    /// The same counts over bare statuses, for a folded OPERATOR or PROJECTS heading, whose rows are not all task
    /// and terminal rows: the Operator's own row is counted with its signals' tasks.
    public static func statusCounts(_ statuses: [TaskStatus]) -> [StatusCount] {
        let statuses = statuses.map(countedStatus)
        return statusOrder.compactMap { status in
            let n = statuses.filter { $0 == status }.count
            return n > 0 ? StatusCount(status: status, count: n) : nil
        }
    }

    /// The status a row is counted under: a row in the background with working, every other as itself.
    public static func countedStatus(_ status: TaskStatus) -> TaskStatus { status == .background ? .working : status }

    /// Focus View (⌘F): open each project with a row that needs attention, fold the others.
    /// Empty projects draw collapsed regardless of their saved state.
    public static func focusView(_ sections: [ProjectSection]) -> [UUID: Bool] {
        collapsedStates(sections) { !$0.needsAttention }
    }

    /// List View (⌘L): open every project with rows. Empty projects are left out, as in `focusView`.
    public static func listView(_ sections: [ProjectSection]) -> [UUID: Bool] {
        collapsedStates(sections) { _ in false }
    }

    private static func collapsedStates(_ sections: [ProjectSection],
                                        _ collapsed: (ProjectSection) -> Bool) -> [UUID: Bool] {
        var states = Dictionary(sections.filter { !$0.isEmpty }.map { ($0.id, collapsed($0)) }, uniquingKeysWith: { first, _ in first })
        return states
    }

    /// The same counts as a sentence, for the row's tooltip and for VoiceOver — the chips
    /// themselves are three glyphs and a digit, which says nothing out loud.
    public static func statusCountsLabel(_ counts: [StatusCount]) -> String {
        counts.map { c in
            switch c.status {
            case .idle: return "\(c.count) idle"
            case .working, .background: return "\(c.count) working"
            case .waiting: return "\(c.count) waiting"
            case .needsInput: return c.count == 1 ? "1 needs input" : "\(c.count) need input"
            case .done: return "\(c.count) done"
            }
        }.joined(separator: ", ")
    }

    public static func avatars(for sessions: [SessionInfo], max: Int = avatarMax) -> AvatarGroup {
        avatars(of: sessions.sorted { $0.tabIndex < $1.tabIndex }.map(\.agent), max: max)
    }

    /// Agents in their order as an avatar group: up to `max` marks, the last becoming `+n` once there are more.
    public static func avatars(of ordered: [SessionAgent], max: Int = avatarMax) -> AvatarGroup {
        guard ordered.count > max else { return AvatarGroup(marks: ordered, overflow: 0) }
        return AvatarGroup(marks: Array(ordered.prefix(max - 1)), overflow: ordered.count - (max - 1))
    }

    /// The branch line for one row.
    ///
    /// `own` is the branch the row is bound to (a task's worktree) — drift is measured against it.
    /// `fallback` is what to show when the row has no window open (the project's own checkout).
    /// The branch shown is the *active* tab's, because that is the tab the keyboard is talking to;
    /// tabs whose directory is not a checkout at all (a shell in `$HOME`) are ignored entirely.
    public static func branchLabel(sessions: [SessionInfo], branchByCwd: [String: String],
                                   own: String?, fallback: String?) -> BranchLabel {
        let ordered = sessions.sorted { $0.tabIndex < $1.tabIndex }
        let named = ordered.compactMap { s in branchByCwd[s.effectiveCwd].map { (session: s, branch: $0) } }
        let primary = named.first { $0.session.active } ?? named.first
        let name = primary?.branch ?? own ?? fallback ?? ""
        guard !name.isEmpty else { return .none }
        let extra = Set(named.map(\.branch)).subtracting([name]).count
        let drifted = own.map { !$0.isEmpty && $0 != name } ?? false
        // Only worth a tooltip when there is something the one line cannot say: several branches
        // in one window, or an agent that is not where its task is.
        var lines: [String] = []
        if drifted, let own { lines.append("task · " + own) }
        if extra > 0 {
            lines += ordered.map { "tab \($0.tabIndex + 1) · \($0.agent.rawValue) · " + (branchByCwd[$0.effectiveCwd] ?? "no branch") }
        }
        return BranchLabel(name: name, extra: extra, drifted: drifted, detail: lines.joined(separator: "\n"))
    }

    /// The per-tab version of the branch label. A live checkout wins; task and project branches
    /// are fallbacks for a shell whose directory cannot currently be resolved. Unmanaged iTerm2
    /// sessions are deliberately omitted. Tags are matched as the ids they name, as rows are.
    public static func sessionTitles(state: AppState, sessions: [SessionInfo],
                                     branchByCwd: [String: String], projectBranch: [UUID: String]) -> [SessionTitle] {
        let taskBranches = Dictionary(state.tasks.map { ($0.id, $0.branch) }, uniquingKeysWith: { first, _ in first })
        return sessions.compactMap { session in
            let fallback = session.taskUUID.flatMap { taskBranches[$0] }
                ?? session.projectId.flatMap(UUID.init(uuidString:)).flatMap { projectBranch[$0] }
            guard session.taskId != nil || session.projectId != nil,
                  let title = branchByCwd[session.effectiveCwd] ?? fallback,
                  !title.isEmpty else { return nil }
            return SessionTitle(sessionId: session.sessionId, title: title)
        }
    }

    public static func entries(state: AppState, sessions: [SessionInfo],
                               branchByCwd: [String: String], projectBranch: [UUID: String],
                               diffByTask: [UUID: DiffStat] = [:]) -> [SidebarEntry] {
        // Grouped once for every row, rather than filtered per task and per terminal — and the
        // rows by project once, rather than filtered again for every project.
        let tabs = Tabs(sessions)
        let rows = Rows(tasks: Dictionary(grouping: state.tasks, by: \.projectId),
                        terminals: Dictionary(grouping: state.terminals, by: \.projectId),
                        signalNames: Dictionary(state.signals.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
        // A row only a newer build can draw is skipped, and does not count as an end to move towards.
        let drawn = state.items.indices.filter { state.items[$0].isDrawn }
        let first = drawn.first ?? 0, last = drawn.last ?? 0
        return state.items.enumerated().compactMap { index, item in
            switch item {
            case .unknown: return nil
            case .divider(let d): return .divider(DividerEntry(divider: d, canMoveUp: index > first, canMoveDown: index < last))
            case .project(let project):
                var section = section(project: project, rows: rows, tabs: tabs,
                                      branchByCwd: branchByCwd, projectBranch: projectBranch, diffByTask: diffByTask)
                section.canMoveUp = index > first; section.canMoveDown = index < last
                return .project(section)
            }
        }
    }

    /// The session list as the rows look it up: a task's tabs by their tag, a terminal's by its window.
    /// Untagged tabs sit under `nil`, which no task asks for.
    struct Tabs {
        var byTask: [UUID?: [SessionInfo]], byWindow: [String: [SessionInfo]]
        init(_ sessions: [SessionInfo]) {
            byTask = Dictionary(grouping: sessions, by: \.taskUUID); byWindow = Dictionary(grouping: sessions, by: \.windowId)
        }
    }
    /// The workspace's tasks and terminals by project, in workspace order.
    /// And each signal's live name, which a task's `startedBySignal` says.
    private struct Rows { var tasks: [UUID: [TaskItem]], terminals: [UUID: [TerminalItem]], signalNames: [UUID: String] }

    /// The project-only view of `entries`, for the callers that never draw a divider.
    public static func sections(state: AppState, sessions: [SessionInfo],
                                branchByCwd: [String: String], projectBranch: [UUID: String],
                                diffByTask: [UUID: DiffStat] = [:]) -> [ProjectSection] {
        entries(state: state, sessions: sessions, branchByCwd: branchByCwd, projectBranch: projectBranch,
                diffByTask: diffByTask)
            .compactMap { if case .project(let s) = $0 { return s } else { return nil } }
    }

    private static func section(project: Project, rows: Rows, tabs: Tabs,
                                branchByCwd: [String: String], projectBranch: [UUID: String],
                                diffByTask: [UUID: DiffStat]) -> ProjectSection {
        let projectTasks = rows.tasks[project.id] ?? []
        // Keep both lanes in saved order, but never let a newly-created task land below reviews.
        // `nil` is the legacy representation of a task, so only an explicit `.review` belongs in
        // the second lane.
        let orderedTasks = projectTasks.filter { $0.kind != .review }
            + projectTasks.filter { $0.kind == .review }
        var tasks = orderedTasks.map {
            taskRow($0, tabs: tabs, branchByCwd: branchByCwd, diffByTask: diffByTask, signalNames: rows.signalNames)
        }
        // SignalSidebar draws Operator-owned rows elsewhere. They do not count towards either
        // edge of a project's group, even while they are still in this intermediate list.
        var previous: Int?
        for index in tasks.indices where !orderedTasks[index].isUnderOperator {
            if let previous, (orderedTasks[previous].kind == .review) == (orderedTasks[index].kind == .review) {
                tasks[previous].canMoveDown = true
                tasks[index].canMoveUp = true
            }
            previous = index
        }
        let terminals = (rows.terminals[project.id] ?? []).map { term -> TerminalRow in
            // Matched on the window, not on `projectId`: every terminal of a project carries the
            // same project id, so only the window tells two of them apart.
            let own = term.windowId.flatMap { tabs.byWindow[$0] } ?? []
            let status = aggregate(tabs: own)
            return TerminalRow(id: term.id, name: term.name,
                               branch: branchLabel(sessions: own, branchByCwd: branchByCwd, own: nil, fallback: projectBranch[project.id]),
                               avatars: own.isEmpty ? AvatarGroup(marks: [.shell], overflow: 0) : avatars(for: own),
                               status: status, background: displayJobs(of: own), needsYou: status.needsAttention)
        }
        return ProjectSection(project: project, tasks: tasks, terminals: terminals)
    }

    /// One task's row: its tabs' agents, branch, status and the mark and "needs you" a task of your own has. A driven
    /// task's line, status, mark and "needs you" are `TaskRow.presentingOperator`'s to set over these.
    static func taskRow(_ task: TaskItem, tabs: Tabs, branchByCwd: [String: String],
                        diffByTask: [UUID: DiffStat], signalNames: [UUID: String] = [:]) -> TaskRow {
        let own = tabs.byTask[task.id] ?? []
        var row = TaskRow(id: task.id, title: task.title, jiraKey: task.jira?.key, jiraUrl: task.jira?.url, mr: task.mr,
                       branch: branchLabel(sessions: own, branchByCwd: branchByCwd, own: task.branch, fallback: nil),
                       avatars: avatars(for: own), status: aggregate(tabs: own),
                       diff: baseDiff(task: task, stat: diffByTask[task.id]),
                       background: displayJobs(of: own))
        row.ticketIsGitLabIssue = task.jira?.isGitLabIssue ?? false
        row.mark = TaskRowMark(status: row.status, line: nil)
        row.needsYou = row.status.needsAttention
        row.kindName = task.kindName; row.worktreePath = task.worktreePath; row.savedBranch = task.branch
        row.windowOpen = task.windowId != nil; row.underOperator = task.isUnderOperator
        row.startedBySignal = startedBySignal(task, names: signalNames)
        if row.startedBySignal != nil, row.avatars.marks.isEmpty, row.avatars.overflow == 0 { row.avatars = mutedAvatars(for: task) }
        return row
    }

    /// The faded mark a task a signal started draws while no agent of its is listed, under its disc: the agent of its
    /// first saved conversation, else its own agent row, which a signal's launch sets to the signal's or the stage's.
    public static func mutedAvatars(for task: TaskItem) -> AvatarGroup {
        AvatarGroup(marks: [(task.conversations.first?.agent ?? task.agent).session], overflow: 0, muted: true)
    }

    /// The name of the signal that runs `task` now (its Operator stage's) or started it (its origin's), as `names` has
    /// it live, else its saved name marked removed; nil for a task no signal started.
    public static func startedBySignal(_ task: TaskItem, names: [UUID: String]) -> String? {
        if let record = task.signalTask { return signalName(record.current.signal, saved: record.current.configuration.name, names: names) }
        if let origin = task.signalOrigin { return signalName(origin.signal, saved: origin.name, names: names) }
        return nil
    }

    /// A signal's live name, or `saved` marked removed once `names` no longer has it.
    public static func signalName(_ id: UUID, saved: String, names: [UUID: String]) -> String {
        names[id] ?? saved + " (removed)"
    }

    /// Only a diff with something in it extends the badge; no base, no answer yet, or nothing
    /// changed all leave the plain mark.
    static func baseDiff(task: TaskItem, stat: DiffStat?) -> BaseDiff? {
        guard !task.baseBranch.isEmpty, let stat, !stat.isEmpty else { return nil }
        return BaseDiff(base: task.baseBranch, stat: stat)
    }

    private static let statusLineMissingNote = "Usage disconnected"

    /// `claudeStatusLineInstalled` is the difference between "the first status line tick has not
    /// arrived yet" and "no tick will ever arrive". Claude Code hands `rate_limits` to the status
    /// line command and to nothing else, so when AiTerm's shim is no longer that command the Claude
    /// row is permanently empty, and saying "No usage data yet" would keep promising data that is not
    /// coming. Codex is unaffected: the daemon reads its rate limits from Codex's own rollout file.
    ///
    /// A window whose `resetsAt` has passed has cleared — whatever percentage it last reported,
    /// that limit is at zero now — so it is dropped rather than drawn. A vendor that has merely
    /// gone quiet keeps its last numbers, drawn like any other: both feeds only move while their
    /// agent runs, so silence is idleness, and the reset clock already says how old a window is.
    ///
    /// `wk` leads every row, then `5h`: Codex often reports only its weekly window, and a shared
    /// first column keeps the two rows aligned.
    ///
    /// Context is not here: it belongs to the selected row and is drawn on ``usageTaskRow``. PI has
    /// no account-quota source AiTerm can read, so it gets no vendor row; it shows `ctx` on the task
    /// row.
    public static func usageVendorRows(_ snap: UsageSnapshot, now: Date, calendar: Calendar,
                                       claudeStatusLineInstalled: Bool = true) -> [UsageVendorRow] {
        [(AgentKind.claude, snap.claude), (.codex, snap.codex)].map { vendor, usage in
            guard let usage else {
                let broken = vendor == .claude && !claudeStatusLineInstalled
                return UsageVendorRow(vendor: vendor, lines: [], note: broken ? statusLineMissingNote : "No usage data yet", warning: broken)
            }
            let epoch = Int(now.timeIntervalSince1970)
            let windows = [(UsageLine.Window.weekly, usage.sevenDay), (.fiveHour, usage.fiveHour)].compactMap { kind, window -> UsageLine? in
                guard let window, (window.resetsAt ?? .max) > epoch else { return nil }
                return UsageLine(window: kind, percent: window.usedPercent,
                                 reset: window.resetsAt.map { fmtReset($0, now: now, calendar: calendar) },
                                 warning: window.usedPercent >= warningThreshold,
                                 resetInFull: window.resetsAt.map { fmtReset($0, now: now, calendar: calendar, inFull: true) })
            }
            return UsageVendorRow(vendor: vendor, lines: windows, note: windows.isEmpty ? "No usage data reported" : nil)
        }
    }

    /// Each agent's weekly usage in percent, for the agents whose seven-day window is still open: a
    /// window whose reset time has passed is left out, as ``usageVendorRows`` leaves it out.
    public static func weeklyUsage(_ snap: UsageSnapshot, now: Date) -> [AgentKind: Int] {
        let epoch = Int(now.timeIntervalSince1970)
        var usage: [AgentKind: Int] = [:]
        for (vendor, window) in [(AgentKind.claude, snap.claude?.sevenDay), (.codex, snap.codex?.sevenDay)] {
            if let window, (window.resetsAt ?? .max) > epoch { usage[vendor] = window.usedPercent }
        }
        return usage
    }

    /// The selected task — or review — as the footer's first row: whatever runs in its active tab,
    /// that provider's last-known fill from `contexts`. A shell tab has no context. A task whose
    /// window is closed shows its own `agent`, with its last fill.
    public static func usageTaskRow(taskId: UUID, agent: AgentKind, sessions: [SessionInfo],
                                    contexts: [AgentKind: Int]) -> UsageTaskRow {
        usageRow(sessions.filter { $0.taskUUID == taskId }, fallback: agent.session, contexts: contexts)
    }

    /// The selected terminal as the footer's first row, on the same rules as ``usageTaskRow``. Its
    /// tabs carry no task tag, so they are matched by window, as its avatars are. A terminal has no
    /// agent of its own: with its window closed it is a shell.
    public static func usageTerminalRow(windowId: String?, sessions: [SessionInfo],
                                        contexts: [AgentKind: Int]) -> UsageTaskRow {
        let own = windowId.map { wid in sessions.filter { $0.windowId == wid } } ?? []
        return usageRow(own, fallback: .shell, contexts: contexts)
    }

    /// Until the daemon has said which tab is current, the first tab stands in for it.
    private static func usageRow(_ own: [SessionInfo], fallback: SessionAgent, contexts: [AgentKind: Int]) -> UsageTaskRow {
        let tab = own.first(where: \.active) ?? own.min { $0.tabIndex < $1.tabIndex }
        let agent = tab?.agent ?? fallback
        return UsageTaskRow(agent: agent, context: agent.agentKind.flatMap { contexts[$0] }.map {
            UsageLine(window: .context, percent: $0, reset: nil, warning: $0 >= warningThreshold)
        })
    }

    /// The statusline's `fmt_reset`: 24-hour local time, with a weekday prefix only across a date
    /// boundary — abbreviated, or `inFull` for the words a tooltip and VoiceOver read.
    static func fmtReset(_ resetsAt: Int, now: Date, calendar: Calendar, inFull: Bool = false) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let format = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : inFull ? "EEEE HH:mm" : "EEE HH:mm"
        return formatReset(date, as: format, calendar: calendar)
    }

    /// Building a `DateFormatter` cost more than the rest of the footer together, and the footer is
    /// drawn on every sidebar render — so one per format and time zone is kept.
    private static let resetFormatters = Mutex<[String: DateFormatter]>([:])

    /// A kept formatter is used inside the lock and never handed out of it: a `DateFormatter` is
    /// mutable, non-`Sendable` state, and two renders on different threads would share it.
    private static func formatReset(_ date: Date, as format: String, calendar: Calendar) -> String {
        let key = "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(format)"
        return resetFormatters.withLock { cache in
            if let cached = cache[key] { return cached.string(from: date) }
            let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_GB")
            f.dateFormat = format
            cache[key] = f
            return f.string(from: date)
        }
    }
}

public extension SidebarModel {
    /// An agent as a caption names it: its vendor's short name, not its CLI's display name.
    static func agentName(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: "Claude"
        case .codex: "Codex"
        case .pi: "PI"
        }
    }
}
