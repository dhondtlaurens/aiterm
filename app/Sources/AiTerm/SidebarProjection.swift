import Foundation
import AiTermCore

/// The two sections of the sidebar that fold into each other: the Operator's and the projects'.
enum SidebarSection { case `operator`, projects }

/// What the OPERATOR or PROJECTS heading draws of the fold between them: whether there is one — only
/// while the Operator has something to show, a signal or its row — and whether its section is the folded
/// one. Folded, PROJECTS counts its rows by status, as a folded project's header counts its own; OPERATOR
/// draws the Operator's own chip and how many of its tasks are finished.
/// Its own value, so a status change elsewhere redraws neither heading.
struct SectionFold: Equatable {
    var folds = false
    var folded = false
    var counts: [StatusCount] = []
    var operatorChip: OperatorChip? = nil
    var finished = 0
}

/// The folded OPERATOR heading's own chip: the Operator's most urgent state, as a row's trailing mark draws it, and
/// how many unfinished tasks it holds (the workload its row's title counts), none for a question with no task.
struct OperatorChip: Equatable {
    var mark: TaskRowMark
    var tasks: Int

    /// What VoiceOver and the tooltip say: "3 tasks, working", or "needs you" alone.
    var label: String {
        let state: String
        switch mark {
        case .status(.needsInput): state = "needs you"
        case .status(.working), .status(.background): state = "working"
        case .status(.waiting): state = "waiting"
        case .pauseSign: state = "paused"
        case .ended, .status: state = "idle"
        }
        guard tasks > 0 else { return state }
        return "\(tasks) \(tasks == 1 ? "task" : "tasks"), " + state
    }
}

/// One chip on a folded heading, which its click opens the section at: a status's first row, the row the
/// Operator chip's mark comes from, or the first finished task.
enum ChipTarget: Hashable {
    case status(TaskStatus), operatorState, finished
}

/// Shared row derivation; equal inputs and equal projected values produce no observation writes.
@Observable @MainActor final class SidebarProjection {
    private(set) var signalOperator = SignalOperatorRowValue.empty
    private(set) var signalSections: [SignalSection] = []
    /// What the Operator's section draws under its row: `signalSections` with the dividers between them. Off the arrow
    /// path, which `signalSections` makes alone, as a project divider is.
    private(set) var operatorEntries: [OperatorEntry] = []
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
    /// The clock a schedule's next run is read against.
    @ObservationIgnored var now: () -> Date = Date.init
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
    /// The tasks the Operator holds (`AppState.operatorWorkTasks`), which its folded heading's chip counts.
    @ObservationIgnored private var operatorWorkload: Set<UUID> = []
    private struct Inputs: Equatable {
        var foldedRemovedSignals: Set<UUID>
        var skipped: [UUID: [String]]
        var nextRuns: [UUID: Date]
        var failures: [String: String]
        var operatorRow: SignalOperatorRowValue
        var acts: [UUID: String]
        var signals: [Signal]
        var signalDividers: [SignalDivider]
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
            /// Its work through (`SignalTask.isFinished`), which a phase alone does not say: done waits on its closeout.
            var finished: Bool
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
                       question: questions[task.id], finished: record.isFinished)
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
    /// Every row under a section, whether its project or signal is folded, in the order the list draws them, each with
    /// the status its folded heading counts it under: OPERATOR's own row, then its signals' tasks; each project's
    /// terminals, then its tasks. A task on its way out is left out, as it is of what needs you.
    func rowStatuses(in section: SidebarSection) -> [(row: RowID, status: TaskStatus)] {
        let leaving = inputs?.leaving ?? []
        let rows: [(row: RowID, status: TaskStatus)]
        switch section {
        case .operator:
            rows = (signalOperator.shown ? [(RowID.operatorChat, signalOperator.status)] : [])
                + signalSections.flatMap { $0.tasks.filter { !leaving.contains($0.id) }.map { (RowID.task($0.id), $0.status) } }
        case .projects:
            rows = sections.flatMap { section in
                section.terminals.map { (RowID.terminal($0.id), $0.status) }
                    + section.tasks.filter { !leaving.contains($0.id) }.map { (RowID.task($0.id), $0.status) }
            }
        }
        return rows.map { ($0.row, SidebarModel.countedStatus($0.status)) }
    }
    /// The first row under a section its folded heading counts under `status`: where that chip opens it.
    func firstRow(in section: SidebarSection, status: TaskStatus) -> RowID? {
        let status = SidebarModel.countedStatus(status)
        return rowStatuses(in: section).first { $0.status == status }?.row
    }
    /// Where a folded heading's chip opens its section.
    func firstRow(in section: SidebarSection, chip: ChipTarget) -> RowID? {
        switch chip {
        case .status(let status): firstRow(in: section, status: status)
        case .operatorState: section == .operator ? operatorChip()?.row : nil
        case .finished: section == .operator ? finishedTasks.first.map { .task($0.id) } : nil
        }
    }
    /// The tasks under OPERATOR whose work is through, in the order the list draws them; none on its way out.
    private var finishedTasks: [TaskRow] {
        let leaving = inputs?.leaving ?? []
        return signalSections.flatMap(\.tasks).filter { $0.countsAsFinished && !leaving.contains($0.id) }
    }
    /// The folded OPERATOR heading's own chip and the row its click opens, the Operator's most urgent state: needs you
    /// (its own row, then any task under it, a finished one you continue included), paused while it holds work, working
    /// (its own row, then any task's worker, in the background too, a continued finished one included), waiting, idle.
    /// Its count is the workload (`AppState.operatorWorkTasks`). No chip without workload unless a row needs you or
    /// works, so a global question draws the amber mark alone.
    func operatorChip() -> (chip: OperatorChip, row: RowID?)? {
        let leaving = inputs?.leaving ?? []
        let own = signalOperator.shown ? signalOperator : nil
        let rows = signalSections.flatMap(\.tasks).filter { !leaving.contains($0.id) }
        let tasks = rows.filter { operatorWorkload.contains($0.id) }
        let count = operatorWorkload.count
        func first(_ statuses: Set<TaskStatus>) -> RowID? { tasks.first { statuses.contains($0.status) }.map { .task($0.id) } }
        let lead = own != nil ? RowID.operatorChat : tasks.first.map { .task($0.id) }
        if own?.status == .needsInput { return (OperatorChip(mark: .status(.needsInput), tasks: count), .operatorChat) }
        if let row = rows.first(where: \.needsYou) { return (OperatorChip(mark: .status(.needsInput), tasks: count), .task(row.id)) }
        let busy = rows.first { [.working, .background].contains($0.status) }.map { RowID.task($0.id) }
        guard count > 0 || own?.status == .working || busy != nil else { return nil }
        if operatorPaused && count > 0 { return (OperatorChip(mark: .pauseSign, tasks: count), lead) }
        if own?.status == .working { return (OperatorChip(mark: .status(.working), tasks: count), .operatorChat) }
        if let busy { return (OperatorChip(mark: .status(.working), tasks: count), busy) }
        if let row = first([.waiting]) { return (OperatorChip(mark: .status(.waiting), tasks: count), row) }
        return (OperatorChip(mark: .status(.idle), tasks: count), lead)
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

    /// Only the open card resolves jobs here; row bodies already have their projected facts.
    func backgroundJobs(for row: RowSelection) -> [BackgroundJob]? {
        guard isDrawn(row) else { return nil }
        switch row {
        case .task(let id):
            return (operatorOpen ? signalSections.flatMap(\.tasks) : sections.flatMap(\.tasks))
                .first { $0.id == id }?.background
        case .terminal(let id): return sections.flatMap(\.terminals).first { $0.id == id }?.background
        default: return nil
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
        let next = Inputs(foldedRemovedSignals: foldedRemovedSignals, skipped: skipped,
            nextRuns: SignalSidebar.nextRuns(in: state, now: now()), failures: state.operatorSession?.sourceFailures ?? [:],
            operatorRow: .make(state: state, sessions: live.rowSessions, issue: operatorIssue(), activity: operatorActivity(), latestAct: acts.latest),
            acts: acts.byTask, signals: state.signals, signalDividers: state.signalDividers,
            operatorOpen: state.operatorOpen,
            items: state.items, tasks: drawn, terminals: state.terminals, sessions: live.rowSessions,
            branches: checkouts.branchByCwd, projectBranches: checkouts.projectBranch, diffs: checkouts.diffByTask,
            leaving: leaving())
        guard next != inputs else { return false }
        let leavingMoved = next.leaving != inputs?.leaving
        inputs = next; derivations += 1
        let all = SidebarModel.entries(state: state, sessions: next.sessions, branchByCwd: next.branches,
                                       projectBranch: next.projectBranches, diffByTask: next.diffs)
        let sidebar = SignalSidebar(state: state, entries: all, acts: next.acts, skipped: next.skipped, nextRuns: next.nextRuns,
                                    foldedRemovedSignals: next.foldedRemovedSignals)
        var changed = leavingMoved || signalOperator != next.operatorRow || signalSections != sidebar.signals
            || entries != sidebar.projects || operatorEntries != sidebar.entries
        if operatorPaused != next.operatorRow.paused { operatorPaused = next.operatorRow.paused; changed = true }
        if signalOperator != next.operatorRow { signalOperator = next.operatorRow }
        if signalSections != sidebar.signals { signalSections = sidebar.signals }
        if operatorEntries != sidebar.entries { operatorEntries = sidebar.entries }
        if entries != sidebar.projects { entries = sidebar.projects }
        let sections = entries.compactMap { if case .project(let section) = $0 { return section }; return nil }
        if self.sections != sections { self.sections = sections }
        let agents = Dictionary(drawn.map { ($0.id, $0.agent) }, uniquingKeysWith: { first, _ in first })
        if taskAgents != agents { taskAgents = agents }
        let terminals = Dictionary(next.terminals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if self.terminals != terminals { self.terminals = terminals }
        // Dividers alone count too: with the last signal gone, its section still opens so they can be renamed or removed.
        let folds = signalOperator.shown || !operatorEntries.isEmpty, open = folds && next.operatorOpen
        if operatorOpen != open { operatorOpen = open; changed = true }
        operatorWorkload = Set(state.operatorWorkTasks.map(\.id))
        let operatorFold = SectionFold(folds: folds, folded: folds && !open, operatorChip: folds && !open ? operatorChip()?.chip : nil,
                                       finished: folds && !open ? finishedTasks.count : 0)
        let projectsFold = SectionFold(folds: folds, folded: open,
                                       counts: open ? SidebarModel.statusCounts(rowStatuses(in: .projects).map(\.status)) : [])
        if operatorHeading != operatorFold { operatorHeading = operatorFold }
        if projectsHeading != projectsFold { projectsHeading = projectsFold }
        return changed
    }

    /// Focus View's (`focus`) or List View's fold of every project and signal with a row: List View opens each, Focus
    /// View only those with a row waiting on you. A task on its way out counts as no row, so a heading left with only
    /// such tasks is left as it is.
    func viewLayout(focus: Bool) -> [UUID: Bool] {
        let leaving = inputs?.leaving ?? []
        let projects = sections.map { section in
            var section = section
            section.tasks.removeAll { leaving.contains($0.id) }
            return section
        }
        var layout = focus ? SidebarModel.focusView(projects) : SidebarModel.listView(projects)
        for section in signalSections {
            let tasks = section.tasks.filter { !leaving.contains($0.id) }
            guard !tasks.isEmpty else { continue }
            layout[section.id] = focus && !tasks.contains(where: \.needsYou)
        }
        return layout
    }

    /// Removed signals keep their fold only for this projection's lifetime.
    func toggleRemovedSignal(_ id: UUID) {
        if !foldedRemovedSignals.insert(id).inserted { foldedRemovedSignals.remove(id) }
    }

    func openRemovedSignal(_ id: UUID) {
        foldedRemovedSignals.remove(id)
    }

    /// The folds of `layout` that belong to a removed signal's heading, set here, and the rest returned for the
    /// workspace to save.
    func foldRemovedSignals(in layout: [UUID: Bool]) -> [UUID: Bool] {
        let removed = Set(signalSections.filter(\.removed).map(\.id))
        for (id, folded) in layout where removed.contains(id) {
            if folded { foldedRemovedSignals.insert(id) } else { foldedRemovedSignals.remove(id) }
        }
        return layout.filter { !removed.contains($0.key) }
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
