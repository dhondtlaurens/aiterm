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
    /// Each task's saved agent, which the footer names while its window is closed (`usageRow(for:)`).
    private(set) var taskAgents: [UUID: AgentKind] = [:]
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
    /// The acts the Operator runs on tasks now: each task's, and the most recent for its own row.
    @ObservationIgnored var operatorActs: () -> (byTask: [UUID: String], latest: OperatorAct?) = { ([:], nil) }
    /// The tasks on their way out (`TaskTeardown.leaving`): their windows are closing, so none waits on you.
    @ObservationIgnored var leaving: () -> Set<UUID> = { [] }
    private let workspace: WorkspaceStore, live: LiveSessions, checkouts: CheckoutMonitor
    @ObservationIgnored private var foldedRemovedSignals: Set<UUID> = []
    private struct Inputs: Equatable {
        var foldedRemovedSignals: Set<UUID>
        var skipped: [UUID: [String]]
        var failures: [String: String]
        var operatorRow: SignalOperatorRowValue
        var acts: [UUID: String]
        var signals: [Signal]
        var operatorOpen: Bool
        var items: [SidebarItem], tasks: [DrawnTask], terminals: [TerminalItem], sessions: [SessionInfo]
        var branches: [String: String], projectBranches: [UUID: String], diffs: [UUID: DiffStat]
        var leaving: Set<UUID>
    }
    /// What a task's row is derived from and nothing else, so a write to a journal, a reply marker, a launch attempt,
    /// a conversation id or a ledger entry derives nothing: what `SidebarModel.taskRow`, `SignalSidebar` and
    /// `TaskRow.presentingOperator` read of it.
    private struct DrawnTask: Equatable {
        var id: UUID, project: UUID, kind: TaskKind, title: String, ticket: JiraRef?, mr: MergeRequestRef?
        var branch: String, baseBranch: String, worktreePath: String, agent: AgentKind, windowOpen: Bool
        /// Only for a task under the Operator.
        var driven: Driven?
        struct Driven: Equatable {
            var signal: UUID, phase: TaskPhase, waitingOn: SignalWaitFacts?, blockedReason: String?
            var choosableRows: Int?, candidateProjects: Int?
            /// Its window closed with its worker's conversation saved, which its line says.
            var windowClosedWithWorker: Bool
            /// The saved configuration, only once its signal was removed: its heading is drawn from it.
            var removedSignal: Signal?
            /// The text of its first current question for you.
            var question: String?
        }

        init(_ task: TaskItem, state: AppState, questions: [UUID: String]) {
            id = task.id; project = task.projectId; kind = task.kind; title = task.title; ticket = task.jira; mr = task.mr
            branch = task.branch; baseBranch = task.baseBranch; worktreePath = task.worktreePath; agent = task.agent
            windowOpen = task.windowId != nil
            driven = task.signalTask.map { record in
                Driven(signal: record.current.signal, phase: record.phase, waitingOn: record.waitingOn, blockedReason: record.blockedReason,
                       choosableRows: record.choosableRows?.count, candidateProjects: record.candidateProjects?.count,
                       windowClosedWithWorker: task.windowId == nil && task.firstWorkerConversation != nil,
                       removedSignal: state.signal(id: record.current.signal) == nil ? record.current.configuration : nil,
                       question: questions[task.id])
            }
        }
    }
    @ObservationIgnored private var inputs: Inputs?
    init(workspace: WorkspaceStore, live: LiveSessions, checkouts: CheckoutMonitor) {
        self.workspace = workspace; self.live = live; self.checkouts = checkouts; refresh()
    }
    var hasProjects: Bool { !sections.isEmpty }
    /// Every row waiting on you, the Operator's section first: what the Dock badge counts and Focus View steps through.
    /// A task on its way out waits on no one.
    var projectsNeedingAttention: [RowID] { operatorNeedingAttention + projectSectionsNeedingAttention }
    /// The rows under OPERATOR waiting on you: its own row, then its signals' tasks.
    var operatorNeedingAttention: [RowID] {
        let leaving = inputs?.leaving ?? []
        return (signalOperator.shown && signalOperator.needsYou ? [.operatorChat] : [])
            + signalSections.flatMap {
                $0.tasks.filter { $0.needsYou && !leaving.contains($0.id) }.map { RowID.task($0.id) }
            }
    }
    /// The rows under PROJECTS waiting on you.
    var projectSectionsNeedingAttention: [RowID] {
        let leaving = inputs?.leaving ?? []
        return sections.flatMap { section in
            section.terminals.filter(\.needsYou).map { RowID.terminal($0.id) }
                + section.tasks.filter { $0.needsYou && !leaving.contains($0.id) }.map { RowID.task($0.id) }
        }
    }
    /// The rows under OPERATOR in the order the arrow keys walk them: its row, then each signal's heading
    /// and, unfolded, its tasks. Worked out whether or not the section is open.
    var operatorPath: [RowSelection] {
        (signalOperator.shown ? [.operatorChat] : [])
            + signalSections.flatMap { section in [.signal(section.id)] + (section.collapsed ? [] : section.tasks.map { .task($0.id) }) }
    }
    /// Whether the last derivation draws this selection in the open section and an unfolded parent.
    func isDrawn(_ row: RowSelection) -> Bool {
        switch row {
        case .operatorChat: operatorOpen && signalOperator.shown
        case .signal(let id): operatorOpen && signalSections.contains { $0.id == id }
        case .project(let id): !operatorOpen && sections.contains { $0.project.id == id }
        case .task(let id):
            if operatorOpen {
                signalSections.contains { !$0.collapsed && $0.tasks.contains { $0.id == id } }
            } else {
                sections.contains { !$0.collapsed && $0.tasks.contains { $0.id == id } }
            }
        case .terminal(let id):
            !operatorOpen && sections.contains { !$0.collapsed && $0.terminals.contains { $0.id == id } }
        }
    }

    /// A child's heading, only while that heading is drawn. Headings and the Operator row have none.
    func visibleHeading(for row: RowSelection) -> RowSelection? {
        switch row {
        case .task(let id):
            if operatorOpen {
                return signalSections.first { $0.tasks.contains { $0.id == id } }.map { .signal($0.id) }
            }
            return sections.first { $0.tasks.contains { $0.id == id } }.map { .project($0.project.id) }
        case .terminal(let id):
            guard !operatorOpen else { return nil }
            return sections.first { $0.terminals.contains { $0.id == id } }.map { .project($0.project.id) }
        case .operatorChat, .project, .signal: return nil
        }
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
        var questions: [UUID: String] = [:]
        for question in state.currentOperatorQuestions { if let task = question.task, questions[task] == nil { questions[task] = question.text } }
        let drawn = state.tasks.map { DrawnTask($0, state: state, questions: questions) }
        let skipped = SignalSidebar.skipped(in: state)
        let acts = operatorActs()
        let next = Inputs(foldedRemovedSignals: foldedRemovedSignals, skipped: skipped, failures: state.operatorSession?.sourceFailures ?? [:],
            operatorRow: .make(state: state, sessions: live.rowSessions, issue: operatorIssue(), activity: operatorActivity(), latestAct: acts.latest),
            acts: acts.byTask, signals: state.signals,
            operatorOpen: state.operatorOpen,
            items: state.items, tasks: drawn, terminals: state.terminals, sessions: live.rowSessions,
            branches: checkouts.branchByCwd, projectBranches: checkouts.projectBranch, diffs: checkouts.diffByTask,
            leaving: leaving())
        guard next != inputs else { return false }
        let leavingMoved = next.leaving != inputs?.leaving
        inputs = next; derivations += 1
        let all = SidebarModel.entries(state: state, sessions: next.sessions, branchByCwd: next.branches,
                                       projectBranch: next.projectBranches, diffByTask: next.diffs)
        let sidebar = SignalSidebar(state: state, entries: all, acts: next.acts, skipped: next.skipped, foldedRemovedSignals: next.foldedRemovedSignals)
        var changed = leavingMoved || signalOperator != next.operatorRow || signalSections != sidebar.signals
            || entries != sidebar.projects
        if operatorPaused != next.operatorRow.paused { operatorPaused = next.operatorRow.paused; changed = true }
        if signalOperator != next.operatorRow { signalOperator = next.operatorRow }
        if signalSections != sidebar.signals { signalSections = sidebar.signals }
        if entries != sidebar.projects { entries = sidebar.projects }
        let sections = entries.compactMap { if case .project(let section) = $0 { return section }; return nil }
        if self.sections != sections { self.sections = sections }
        let agents = Dictionary(drawn.map { ($0.id, $0.agent) }, uniquingKeysWith: { first, _ in first })
        if taskAgents != agents { taskAgents = agents }
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

    /// Removed signals keep their fold only for this projection's lifetime.
    func toggleRemovedSignal(_ id: UUID) {
        if !foldedRemovedSignals.insert(id).inserted { foldedRemovedSignals.remove(id) }
    }

    func openRemovedSignal(_ id: UUID) {
        foldedRemovedSignals.remove(id)
    }

    func usageRow(for row: RowSelection?) -> UsageTaskRow? {
        let contexts = live.contextPercents(for: row)
        switch row {
        case .task(let id):
            guard let agent = taskAgents[id] else { return nil }
            return SidebarModel.usageTaskRow(taskId: id, agent: agent, sessions: live.rowSessions, contexts: contexts)
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
