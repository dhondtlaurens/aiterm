import Foundation
import AiTermCore

/// The two sections of the sidebar that fold into each other: the Operator's and the projects'.
enum SidebarSection { case `operator`, projects }

/// What the OPERATOR or PROJECTS heading draws of the fold between them: whether there is one — only
/// while the Operator has something to show, a task it runs or its row — and whether its section is the folded
/// one. Folded, PROJECTS counts its rows by status, as a folded project's header counts its own; OPERATOR
/// draws the Operator's own chip and how many of its tasks are finished.
/// Its own value, so a status change elsewhere redraws neither heading. It also carries the section's signals icon:
/// how many signals the section has, and the first of their issues, which turns the icon amber.
struct SectionFold: Equatable {
    var folds = false
    var folded = false
    var counts: [StatusCount] = []
    var operatorChip: OperatorChip? = nil
    var finished = 0
    /// The section's signals, which its heading's signals icon counts; none draws no icon.
    var signals = 0
    /// The sentence naming the section's first failing signal or skipped item; nil while none.
    var signalIssue: String? = nil
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

/// Focus View's or List View's folds, one map per section, each by project id: whether the project folds.
struct ViewLayout: Equatable {
    var projects: [UUID: Bool]
    var `operator`: [UUID: Bool] = [:]
    var isEmpty: Bool { projects.isEmpty && `operator`.isEmpty }
}

/// Shared row derivation; equal inputs and equal projected values produce no observation writes.
@Observable @MainActor final class SidebarProjection {
    private(set) var signalOperator = SignalOperatorRowValue.empty
    /// What the Operator's section draws under its row (`SignalSidebar.operatorEntries`): each project with a task the
    /// Operator runs, and the projects' dividers between them.
    private(set) var operatorEntries: [SidebarEntry] = []
    /// The projects among `operatorEntries`, which make the section's arrow path, as `sections` make the projects'.
    private(set) var operatorSections: [ProjectSection] = []
    private(set) var entries: [SidebarEntry] = []
    private(set) var sections: [ProjectSection] = []
    /// Each task's saved agent, which the footer names while its window is closed (`usageRow(for:)`).
    private(set) var taskAgents: [UUID: AgentKind] = [:]
    /// The signal card of each task a signal started or the Operator holds, by task: what its avatar's disc opens. Apart
    /// from the rows, so a card's chain or current line changing redraws no row; only the open card reads it.
    private(set) var signalCards: [UUID: SignalCard] = [:]
    private(set) var terminals: [UUID: TerminalItem] = [:]
    /// Whether the Operator's section is the open one, the projects folded: the person's choice
    /// (`AppState.operatorOpen`) while there is anything to fold, never otherwise.
    private(set) var operatorOpen = false
    private(set) var operatorPaused = false
    private(set) var operatorHeading = SectionFold()
    private(set) var projectsHeading = SectionFold()
    @ObservationIgnored private(set) var derivations = 0
    @ObservationIgnored var operatorIssue: () -> String? = { nil }
    /// Each signal's failing source reads (`SignalOperatorController.readIssues`): a failing one turns its section's
    /// signals icon amber.
    @ObservationIgnored var readIssues: () -> SignalReadIssues = { SignalReadIssues() }
    @ObservationIgnored var operatorActivity: () -> OperatorActivity? = { nil }
    /// The acts the Operator runs on tasks now: each task's, and the most recent for its own row.
    @ObservationIgnored var operatorActs: () -> (byTask: [UUID: String], latest: OperatorAct?) = { ([:], nil) }
    /// The tasks whose wake marches up their stretch of the status line now (`OperatorActivityTracker.waking`).
    @ObservationIgnored var operatorWaking: () -> Set<UUID> = { [] }
    /// The tasks on their way out (`TaskTeardown.leaving`): their windows are closing, so none waits on you.
    @ObservationIgnored var leaving: () -> Set<UUID> = { [] }
    /// Each row's piece of the Operator's status line (`StatusLine`), in a cell of its own that only the row's
    /// `StatusLineCell` reads: a piece changing redraws no row. Nil for a row off the line.
    @ObservationIgnored let statusLine: PerRow<StatusLinePiece?>
    /// The rows given a piece last time, whose cells go back to nil once they leave the line.
    @ObservationIgnored private var lineRows: Set<UUID> = []
    private let workspace: WorkspaceStore, live: LiveSessions, checkouts: CheckoutMonitor
    /// The tasks the Operator holds (`AppState.operatorWorkTasks`), which its folded heading's chip counts.
    @ObservationIgnored private var operatorWorkload: Set<UUID> = []
    private struct Inputs: Equatable {
        /// Each signal's skipped items, the first of which a section's amber signals icon can say.
        var skipped: [UUID: [String]]
        /// The signals whose source reads fail, from `readIssues`: what turns a section's signals icon amber.
        var failures: Set<UUID>
        var operatorRow: SignalOperatorRowValue
        var acts: [UUID: String]
        /// The tasks whose wake marches their stretch of the status line up.
        var waking: Set<UUID>
        var signals: [Signal]
        var operatorOpen: Bool
        /// The projects folded in the Operator's section.
        var operatorFolded: Set<UUID>
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
        /// Only for a task a signal started that is not the Operator's: what its disc and card draw of its origin.
        var origin: Origin?
        struct Origin: Equatable {
            var signal: UUID, name: String, startedAt: Date, earlier: [SignalStep]?
            /// Whether a prompt is still owed to its worker, and why its delivery or launch is held, if it is.
            var owed: Bool, held: String?
            var doneAt: Date?, thenNote: String?
        }
        struct Driven: Equatable {
            /// The stage's signal, its saved name, when it started and the chain before it: the disc and the card's.
            var signal: UUID, name: String, startedAt: Date, earlier: [SignalStep]?
            var phase: TaskPhase, waitingOn: SignalWaitFacts?, blockedReason: String?
            var choosableRows: Int?, candidateProjects: Int?
            /// Its window closed with its worker's conversation saved, which its line says.
            var windowClosedWithWorker: Bool
            /// The text of its first current question for you.
            var question: String?
            /// Its work through (`SignalTask.isFinished`), which a phase alone does not say: done waits on its closeout.
            var finished: Bool
        }

        init(_ task: TaskItem, state: AppState, questions: [UUID: String]) {
            id = task.id; project = task.projectId; kind = task.kind; title = task.title; ticket = task.jira; mr = task.mr
            branch = task.branch; baseBranch = task.baseBranch; worktreePath = task.worktreePath; agent = task.agent
            windowOpen = task.windowId != nil
            origin = task.signalTask != nil ? nil : task.signalOrigin.map { origin in
                let held = origin.owed == nil ? nil : state.signalSeen.first {
                    $0.signal == origin.signal && $0.item.identity == origin.item.identity && $0.disposition == .skipped
                }?.reason
                return Origin(signal: origin.signal, name: origin.name, startedAt: origin.startedAt, earlier: origin.earlier,
                              owed: origin.owed != nil, held: held, doneAt: origin.doneAt, thenNote: origin.thenNote)
            }
            driven = task.signalTask.map { record in
                Driven(signal: record.current.signal, name: record.current.configuration.name, startedAt: record.startedAt,
                       earlier: record.earlier, phase: record.phase, waitingOn: record.waitingOn, blockedReason: record.blockedReason,
                       choosableRows: record.choosableRows?.count, candidateProjects: record.candidateProjects?.count,
                       windowClosedWithWorker: task.windowId == nil && task.firstWorkerConversation != nil,
                       question: questions[task.id], finished: record.isFinished)
            }
        }
    }
    @ObservationIgnored private var inputs: Inputs?
    init(workspace: WorkspaceStore, live: LiveSessions, checkouts: CheckoutMonitor) {
        self.workspace = workspace; self.live = live; self.checkouts = checkouts
        statusLine = PerRow(default: nil, workspace: workspace)
        refresh()
    }
    var hasProjects: Bool { !sections.isEmpty }
    /// Every row waiting on you, the Operator's section first: what the Dock badge counts and Focus View steps through.
    /// A task on its way out waits on no one.
    var projectsNeedingAttention: [RowID] { operatorNeedingAttention + projectSectionsNeedingAttention }
    /// The rows under OPERATOR waiting on you: its own row, then the tasks it runs, project by project.
    var operatorNeedingAttention: [RowID] {
        let leaving = inputs?.leaving ?? []
        return (signalOperator.shown && signalOperator.needsYou ? [.operatorChat] : [])
            + operatorSections.flatMap {
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
    /// Every row under a section, whether its project is folded, in the order the list draws them, each with
    /// the status its folded heading counts it under: OPERATOR's own row, then its projects' tasks; each project's
    /// terminals, then its tasks. A task on its way out is left out, as it is of what needs you.
    func rowStatuses(in section: SidebarSection) -> [(row: RowID, status: TaskStatus)] {
        let leaving = inputs?.leaving ?? []
        let rows: [(row: RowID, status: TaskStatus)]
        switch section {
        case .operator:
            rows = (signalOperator.shown ? [(RowID.operatorChat, signalOperator.status)] : [])
                + operatorSections.flatMap { $0.tasks.filter { !leaving.contains($0.id) }.map { (RowID.task($0.id), $0.status) } }
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
        return operatorSections.flatMap(\.tasks).filter { $0.countsAsFinished && !leaving.contains($0.id) }
    }
    /// The folded OPERATOR heading's own chip and the row its click opens, the Operator's most urgent state: needs you
    /// (its own row, then any task under it, a finished one you continue included), paused while it holds work, working
    /// (its own row, then any task's worker, in the background too, a continued finished one included), waiting, idle.
    /// Its count is the workload (`AppState.operatorWorkTasks`). No chip without workload unless a row needs you or
    /// works, so a global question draws the amber mark alone.
    func operatorChip() -> (chip: OperatorChip, row: RowID?)? {
        let leaving = inputs?.leaving ?? []
        let own = signalOperator.shown ? signalOperator : nil
        let rows = operatorSections.flatMap(\.tasks).filter { !leaving.contains($0.id) }
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
    /// The rows under OPERATOR in the order the arrow keys walk them: its row, then each project's heading
    /// and, unfolded, its tasks. Worked out whether or not the section is open.
    var operatorPath: [RowSelection] {
        (signalOperator.shown ? [.operatorChat] : [])
            + operatorSections.flatMap { section in
                [.operatorProject(section.project.id)] + (section.collapsed ? [] : section.tasks.map { .task($0.id) })
            }
    }
    /// Whether the last derivation draws this selection in the open section and an unfolded parent.
    func isDrawn(_ row: RowSelection) -> Bool {
        switch row {
        case .operatorChat: operatorOpen && signalOperator.shown
        case .operatorProject(let id): operatorOpen && operatorSections.contains { $0.project.id == id }
        case .project(let id): !operatorOpen && sections.contains { $0.project.id == id }
        case .task(let id):
            if operatorOpen {
                operatorSections.contains { !$0.collapsed && $0.tasks.contains { $0.id == id } }
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
            return (operatorOpen ? operatorSections.flatMap(\.tasks) : sections.flatMap(\.tasks))
                .first { $0.id == id }?.background
        case .terminal(let id): return sections.flatMap(\.terminals).first { $0.id == id }?.background
        default: return nil
        }
    }

    /// The signal card a task's disc opens, only while its row is drawn, as `backgroundJobs(for:)` resolves the jobs.
    func signalCard(for row: RowSelection) -> SignalCard? {
        guard isDrawn(row), case .task(let id) = row else { return nil }
        return signalCards[id]
    }

    /// A child's heading, only while that heading is drawn. Headings and the Operator row have none.
    func visibleHeading(for row: RowSelection) -> RowSelection? {
        switch row {
        case .task(let id):
            if operatorOpen {
                return operatorSections.first { $0.tasks.contains { $0.id == id } }.map { .operatorProject($0.project.id) }
            }
            return sections.first { $0.tasks.contains { $0.id == id } }.map { .project($0.project.id) }
        case .terminal(let id):
            guard !operatorOpen else { return nil }
            return sections.first { $0.terminals.contains { $0.id == id } }.map { .project($0.project.id) }
        case .operatorChat, .project, .operatorProject: return nil
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
        let next = Inputs(skipped: skipped, failures: Set(readIssues().current.map(\.signal)),
            operatorRow: .make(state: state, sessions: live.rowSessions, issue: operatorIssue(), activity: operatorActivity(), latestAct: acts.latest),
            acts: acts.byTask, waking: operatorWaking(), signals: state.signals, operatorOpen: state.operatorOpen, operatorFolded: state.operatorFolded,
            items: state.items, tasks: drawn, terminals: state.terminals, sessions: live.rowSessions,
            branches: checkouts.branchByCwd, projectBranches: checkouts.projectBranch, diffs: checkouts.diffByTask,
            leaving: leaving())
        guard next != inputs else { return false }
        let leavingMoved = next.leaving != inputs?.leaving
        inputs = next; derivations += 1
        let all = SidebarModel.entries(state: state, sessions: next.sessions, branchByCwd: next.branches,
                                       projectBranch: next.projectBranches, diffByTask: next.diffs)
        let sidebar = SignalSidebar(state: state, entries: all, acts: next.acts)
        var changed = leavingMoved || signalOperator != next.operatorRow
            || entries != sidebar.projects || operatorEntries != sidebar.operatorEntries
        if operatorPaused != next.operatorRow.paused { operatorPaused = next.operatorRow.paused; changed = true }
        if signalOperator != next.operatorRow { signalOperator = next.operatorRow }
        if operatorEntries != sidebar.operatorEntries { operatorEntries = sidebar.operatorEntries }
        if entries != sidebar.projects { entries = sidebar.projects }
        let operatorSections = sidebar.operatorSections
        if self.operatorSections != operatorSections { self.operatorSections = operatorSections }
        let sections = entries.compactMap { if case .project(let section) = $0 { return section }; return nil }
        if self.sections != sections { self.sections = sections }
        let drawnRows = Dictionary((operatorSections.flatMap(\.tasks) + sections.flatMap(\.tasks)).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var cards: [UUID: SignalCard] = [:]
        for task in state.tasks where task.signalTask != nil || task.signalOrigin != nil {
            if let row = drawnRows[task.id], let card = SignalCard.make(task: task, row: row, state: state) { cards[task.id] = card }
        }
        if signalCards != cards { signalCards = cards }
        let agents = Dictionary(drawn.map { ($0.id, $0.agent) }, uniquingKeysWith: { first, _ in first })
        if taskAgents != agents { taskAgents = agents }
        let terminals = Dictionary(next.terminals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if self.terminals != terminals { self.terminals = terminals }
        // A divider is an entry only before a project of the Operator's, so an entry means a task it runs.
        let folds = signalOperator.shown || !operatorEntries.isEmpty, open = folds && next.operatorOpen
        if operatorOpen != open { operatorOpen = open; changed = true }
        operatorWorkload = Set(state.operatorWorkTasks.map(\.id))
        let operatorFold = SectionFold(folds: folds, folded: folds && !open, operatorChip: folds && !open ? operatorChip()?.chip : nil,
                                       finished: folds && !open ? finishedTasks.count : 0,
                                       signals: next.signals.filter { !$0.isProject }.count,
                                       signalIssue: Self.signalIssue(next.signals.filter { !$0.isProject }, failures: next.failures,
                                                                     skipped: next.skipped))
        let projectsFold = SectionFold(folds: folds, folded: open,
                                       counts: open ? SidebarModel.statusCounts(rowStatuses(in: .projects).map(\.status)) : [],
                                       signals: next.signals.filter(\.isProject).count,
                                       signalIssue: Self.signalIssue(next.signals.filter(\.isProject), failures: next.failures,
                                                                     skipped: next.skipped))
        if operatorHeading != operatorFold { operatorHeading = operatorFold }
        if projectsHeading != projectsFold { projectsHeading = projectsFold }
        writeStatusLine(questions: Set(questions.keys), inputs: next)
        return changed
    }

    /// The open Operator section's rows as the line sees them, in drawn order: its row, then each entry's divider, or
    /// heading and, unfolded, its tasks.
    private var statusLineRows: [StatusLine.Row] {
        guard operatorOpen else { return [] }
        return (signalOperator.shown ? [.operatorRow] : []) + operatorEntries.flatMap { entry -> [StatusLine.Row] in
            switch entry {
            case .divider(let divider): return [.divider(divider.divider.id)]
            case .project(let section):
                return [.heading(OperatorSession.projectRowID(section.project.id), folded: section.collapsed, tasks: section.tasks.map(\.id))]
                    + (section.collapsed ? [] : section.tasks.map { .task($0.id) })
            }
        }
    }

    /// Writes each row's piece of the status line into its cell, only where it changed, and clears the cells of the
    /// rows that left the line.
    private func writeStatusLine(questions: Set<UUID>, inputs: Inputs) {
        let pieces = StatusLine.pieces(rows: statusLineRows, workload: operatorWorkload, acting: Set(inputs.acts.keys),
                                       waking: inputs.waking, asking: questions)
        for id in lineRows where pieces[id] == nil { statusLine[id] = nil }
        for (id, piece) in pieces { statusLine[id] = piece }
        lineRows = Set(pieces.keys)
    }

    /// What a section's signals icon says on hover while it is amber: the first of `signals` (one section's, in its
    /// sheet's order) whose source fails, "“Reviews for me” can’t read GitLab.", else the first skipped item,
    /// "“Reviews for me” skipped !12: Several projects match."; nil while none.
    static func signalIssue(_ signals: [Signal], failures: Set<UUID>, skipped: [UUID: [String]]) -> String? {
        if let failing = signals.first(where: { failures.contains($0.id) }) {
            return SignalReadIssues.sentence(name: failing.name, source: failing.start.source.label)
        }
        for signal in signals { if let item = skipped[signal.id]?.first { return "“" + signal.name + "” skipped " + item } }
        return nil
    }

    /// Focus View's (`focus`) or List View's fold of every project with a row, in each section apart: `projects` by
    /// project id for `Project.collapsed`, `operator` by project id for `AppState.operatorFolded`. List View opens each,
    /// Focus View only those with a row waiting on you. A task on its way out counts as no row, so a heading left with
    /// only such tasks is left as it is.
    func viewLayout(focus: Bool) -> ViewLayout {
        let leaving = inputs?.leaving ?? []
        let projects = sections.map { section in
            var section = section
            section.tasks.removeAll { leaving.contains($0.id) }
            return section
        }
        var layout = ViewLayout(projects: focus ? SidebarModel.focusView(projects) : SidebarModel.listView(projects))
        for section in operatorSections {
            let tasks = section.tasks.filter { !leaving.contains($0.id) }
            guard !tasks.isEmpty else { continue }
            layout.operator[section.project.id] = focus && !tasks.contains(where: \.needsYou)
        }
        return layout
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
        case .project, .operatorProject, nil: return nil
        }
    }
}
