import Foundation
import AiTermCore

/// What the OPERATOR or PROJECTS heading draws of the fold between them: whether there is one — only
/// while the Operator has something to show, a signal or its row — whether its section is the folded
/// one, and, folded, how many of its rows need you. Its own value, so a status change elsewhere
/// redraws neither heading.
struct SectionFold: Equatable {
    var folds = false
    var folded = false
    var attention = 0
}

/// Shared row derivation; equal inputs and equal projected values produce no observation writes.
@Observable @MainActor final class SidebarProjection {
    private(set) var signalOperator = SignalOperatorRowValue.empty
    private(set) var signalSections: [SignalSection] = []
    private(set) var entries: [SidebarEntry] = []
    private(set) var sections: [ProjectSection] = []
    private(set) var tasks: [UUID: TaskItem] = [:]
    private(set) var terminals: [UUID: TerminalItem] = [:]
    /// Whether the Operator's section is the open one, the projects folded: the person's choice
    /// (`AppState.operatorOpen`) while there is anything to fold, never otherwise.
    private(set) var operatorOpen = false
    private(set) var operatorPaused = false
    private(set) var operatorHeading = SectionFold()
    private(set) var projectsHeading = SectionFold()
    @ObservationIgnored private(set) var derivations = 0
    @ObservationIgnored var operatorIssue: () -> String? = { nil }
    @ObservationIgnored var operatorActivity: () -> OperatorActivity? = { nil }
    private let workspace: WorkspaceStore, live: LiveSessions, checkouts: CheckoutMonitor
    private struct Inputs: Equatable {
        var skipped: [UUID: [String]]
        var failures: [String: String]
        var operatorRow: SignalOperatorRowValue
        var signals: [Signal]
        var operatorOpen: Bool
        var items: [SidebarItem], tasks: [TaskItem], terminals: [TerminalItem], sessions: [SessionInfo]
        var branches: [String: String], projectBranches: [UUID: String], diffs: [UUID: DiffStat]
    }
    @ObservationIgnored private var inputs: Inputs?
    init(workspace: WorkspaceStore, live: LiveSessions, checkouts: CheckoutMonitor) {
        self.workspace = workspace; self.live = live; self.checkouts = checkouts; refresh()
    }
    var hasProjects: Bool { !sections.isEmpty }
    /// Every row waiting on you, the Operator's section first: what the Dock badge counts and Focus View steps through.
    var projectsNeedingAttention: [RowID] { operatorNeedingAttention + projectSectionsNeedingAttention }
    /// The attention rows with tasks on their way out passed over.
    func needingAttention(skipping: Set<UUID>) -> [RowID] {
        projectsNeedingAttention.filter { row in
            if case .task(let id) = row { return !skipping.contains(id) }
            return true
        }
    }
    /// The rows under OPERATOR waiting on you: its own row, then its signals' tasks.
    var operatorNeedingAttention: [RowID] {
        (signalOperator.shown && signalOperator.status == .needsInput ? [.operatorChat] : [])
            + signalSections.flatMap { $0.tasks.filter { $0.status == .needsInput }.map { RowID.task($0.id) } }
    }
    /// The rows under PROJECTS waiting on you.
    var projectSectionsNeedingAttention: [RowID] {
        sections.flatMap { section in
            section.terminals.filter { $0.status.needsAttention }.map { RowID.terminal($0.id) }
                + section.tasks.filter { $0.status.needsAttention }.map { RowID.task($0.id) }
        }
    }
    /// The rows under OPERATOR in the order the arrow keys walk them: its row, then each signal's heading
    /// and, unfolded, its tasks. Worked out whether or not the section is open.
    var operatorPath: [RowSelection] {
        (signalOperator.shown ? [.operatorChat] : [])
            + signalSections.flatMap { section in [.signal(section.id)] + (section.collapsed ? [] : section.tasks.map { .task($0.id) }) }
    }
    /// Where an arrow key crosses the fold between the sections: ↓ on the Operator's last row reaches the first
    /// project, ↑ on the first project the Operator's last row. Nil anywhere else, where the list moves on its own,
    /// and while there is no fold.
    func crossing(from row: RowSelection, down: Bool) -> RowSelection? {
        guard operatorHeading.folds, let first = sections.first.map({ RowSelection.project($0.project.id) }) else { return nil }
        if down, operatorOpen, row == operatorPath.last { return first }
        if !down, !operatorOpen, row == first { return operatorPath.last }
        return nil
    }
    @discardableResult func refresh() -> Bool {
        let state = workspace.state
        let drawn = state.tasks.map { task in
            var value = task
            value.conversations = []
            if let record = task.signalTask {
                if !record.takenOver && task.windowId == nil && task.firstWorkerConversation != nil {
                    value.conversations = [.init(agent: task.agent, id: "saved")]
                }
                var visible = SignalTask(signal: record.signal, item: .unknown(.null), startedAt: .distantPast)
                visible.phase = record.phase; visible.stage = record.stage; visible.ownership = record.ownership
                visible.takenOver = record.takenOver; visible.currentAct = record.currentAct; visible.blockedReason = record.blockedReason
                visible.waitingOn = record.waitingOn
                if state.signal(id: record.signal) == nil { visible.configuration = record.configuration }
                value.signalTask = visible
            }
            return value
        }
        let skipped = Dictionary(grouping: state.signalSeen.filter { $0.disposition == .skipped && $0.isMatching }, by: \.signal)
            .mapValues { $0.map { ($0.item.identity ?? "Item") + ": " + ($0.reason ?? "No project") }.sorted() }
        let next = Inputs(skipped: skipped, failures: state.operatorSession?.sourceFailures ?? [:], operatorRow: .make(state: state, sessions: live.rowSessions, issue: operatorIssue(), activity: operatorActivity()), signals: state.signals,
            operatorOpen: state.operatorOpen,
            items: state.items, tasks: drawn, terminals: state.terminals, sessions: live.rowSessions,
            branches: checkouts.branchByCwd, projectBranches: checkouts.projectBranch, diffs: checkouts.diffByTask)
        guard next != inputs else { return false }
        inputs = next; derivations += 1
        let all = SidebarModel.entries(state: state, sessions: next.sessions, branchByCwd: next.branches,
                                       projectBranch: next.projectBranches, diffByTask: next.diffs)
        let sidebar = SignalSidebar(state: state, entries: all)
        var changed = signalOperator != next.operatorRow || signalSections != sidebar.signals || entries != sidebar.projects
        if operatorPaused != next.operatorRow.paused { operatorPaused = next.operatorRow.paused; changed = true }
        if signalOperator != next.operatorRow { signalOperator = next.operatorRow }
        if signalSections != sidebar.signals { signalSections = sidebar.signals }
        if entries != sidebar.projects { entries = sidebar.projects }
        let sections = entries.compactMap { if case .project(let section) = $0 { return section }; return nil }
        if self.sections != sections { self.sections = sections }
        let tasks = Dictionary(drawn.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if self.tasks != tasks { self.tasks = tasks }
        let terminals = Dictionary(next.terminals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if self.terminals != terminals { self.terminals = terminals }
        let folds = signalOperator.shown || !signalSections.isEmpty, open = folds && next.operatorOpen
        if operatorOpen != open { operatorOpen = open; changed = true }
        let operatorFold = SectionFold(folds: folds, folded: folds && !open, attention: folds && !open ? operatorNeedingAttention.count : 0)
        let projectsFold = SectionFold(folds: folds, folded: open, attention: open ? projectSectionsNeedingAttention.count : 0)
        if operatorHeading != operatorFold { operatorHeading = operatorFold }
        if projectsHeading != projectsFold { projectsHeading = projectsFold }
        return changed
    }

    func usageRow(for row: RowSelection?) -> UsageTaskRow? {
        let contexts = live.contextPercents(for: row)
        switch row {
        case .task(let id):
            guard let task = tasks[id] else { return nil }
            return SidebarModel.usageTaskRow(taskId: id, agent: task.agent, sessions: live.rowSessions, contexts: contexts)
        case .terminal(let id):
            guard let terminal = terminals[id] else { return nil }
            return SidebarModel.usageTerminalRow(windowId: terminal.windowId, sessions: live.rowSessions, contexts: contexts)
        case .operatorChat:
            guard let session = workspace.state.operatorSession else { return nil }
            return SidebarModel.usageTaskRow(taskId: session.id, agent: .claude, sessions: live.rowSessions, contexts: contexts)
        case .project, .signal, nil: return nil
        }
    }
}
