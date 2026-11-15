import Foundation
import AiTermCore

/// Shared row derivation; equal inputs and equal projected values produce no observation writes.
@Observable @MainActor final class SidebarProjection {
    private(set) var signalOperator = SignalOperatorRowValue.empty
    private(set) var signalSections: [SignalSection] = []
    private(set) var entries: [SidebarEntry] = []
    private(set) var sections: [ProjectSection] = []
    private(set) var tasks: [UUID: TaskItem] = [:]
    private(set) var terminals: [UUID: TerminalItem] = [:]
    @ObservationIgnored private(set) var derivations = 0
    @ObservationIgnored var operatorIssue: () -> String? = { nil }
    private let workspace: WorkspaceStore, live: LiveSessions, checkouts: CheckoutMonitor
    private struct Inputs: Equatable {
        var skipped: [UUID: [String]]
        var failures: [String: String]
        var operatorRow: SignalOperatorRowValue
        var signals: [Signal]
        var items: [SidebarItem], tasks: [TaskItem], terminals: [TerminalItem], sessions: [SessionInfo]
        var branches: [String: String], projectBranches: [UUID: String], diffs: [UUID: DiffStat]
    }
    @ObservationIgnored private var inputs: Inputs?
    init(workspace: WorkspaceStore, live: LiveSessions, checkouts: CheckoutMonitor) {
        self.workspace = workspace; self.live = live; self.checkouts = checkouts; refresh()
    }
    var hasProjects: Bool { !sections.isEmpty }
    var projectsNeedingAttention: [RowID] {
        (signalOperator.status == .needsInput ? [.operation(OperatorSession.rowID)] : [])
            + signalSections.flatMap { $0.tasks.filter { $0.status == .needsInput }.map { RowID.task($0.id) } }
            + sections.flatMap { section in
            section.terminals.filter { $0.status.needsAttention }.map { RowID.terminal($0.id) }
                + section.tasks.filter { $0.status.needsAttention }.map { RowID.task($0.id) }
        }
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
                if state.signal(id: record.signal) == nil { visible.configuration = record.configuration }
                value.signalTask = visible
            }
            return value
        }
        let skipped = Dictionary(grouping: state.signalSeen.filter { $0.disposition == .skipped && $0.isMatching }, by: \.signal)
            .mapValues { $0.map { ($0.item.identity ?? "Item") + ": " + ($0.reason ?? "No project") }.sorted() }
        let next = Inputs(skipped: skipped, failures: state.operatorSession?.sourceFailures ?? [:], operatorRow: .make(state: state, sessions: live.rowSessions, issue: operatorIssue()), signals: state.signals,
            items: state.items, tasks: drawn, terminals: state.terminals, sessions: live.rowSessions,
            branches: checkouts.branchByCwd, projectBranches: checkouts.projectBranch, diffs: checkouts.diffByTask)
        guard next != inputs else { return false }
        inputs = next; derivations += 1
        let all = SidebarModel.entries(state: state, sessions: next.sessions, branchByCwd: next.branches,
                                       projectBranch: next.projectBranches, diffByTask: next.diffs)
        let sidebar = SignalSidebar(state: state, entries: all)
        let changed = signalOperator != next.operatorRow || signalSections != sidebar.signals || entries != sidebar.projects
        if signalOperator != next.operatorRow { signalOperator = next.operatorRow }
        if signalSections != sidebar.signals { signalSections = sidebar.signals }
        if entries != sidebar.projects { entries = sidebar.projects }
        let sections = entries.compactMap { if case .project(let section) = $0 { return section }; return nil }
        if self.sections != sections { self.sections = sections }
        let tasks = Dictionary(drawn.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if self.tasks != tasks { self.tasks = tasks }
        let terminals = Dictionary(next.terminals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if self.terminals != terminals { self.terminals = terminals }
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
        case .operation(let id):
            guard id == OperatorSession.rowID, let session = workspace.state.operatorSession else { return nil }
            return SidebarModel.usageTaskRow(taskId: session.id, agent: .claude, sessions: live.rowSessions, contexts: contexts)
        case .project, .signal, nil: return nil
        }
    }
}
