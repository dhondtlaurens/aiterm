import Foundation
import AiTermCore

/// The sidebar's rows, derived once for everyone who reads them: the list draws `entries`, and the
/// Dock badge, Focus View and List View read `sections`. They are derived again only when what
/// they are made of changes — the workspace's projects, dividers, tasks and terminals, the tabs as
/// the rows read them (`LiveSessions.rowSessions`), the branches and diffs on disk, and while the board
/// shows what its tasks' Claude workers run now — and each property is written only when its value differs.
///
/// So what no row draws redraws nothing: a sidebar move or a remembered agent and model is a
/// change to the workspace, but not to its rows, and a context fill or a spinner title is a session
/// event, but not a change to `rowSessions`. Each of those used to derive the rows again for the
/// badge, and the first two to redraw the list.
@MainActor
@Observable
final class SidebarProjection {
    /// The list's top level, in the order it is drawn: projects with their rows, and dividers.
    private(set) var entries: [SidebarEntry] = []
    /// The projects of `entries`.
    private(set) var sections: [ProjectSection] = []
    /// Each task and terminal by id: the saved item a drawn row also reads, a task without its remembered conversations.
    private(set) var tasks: [UUID: TaskItem] = [:]
    private(set) var terminals: [UUID: TerminalItem] = [:]
    /// The broadcast's group under the OPERATOR heading, above the projects: the Operator's row and the tasks it
    /// holds, which `entries` leaves out; nil while no broadcast exists.
    private(set) var broadcast: BroadcastSection?
    /// Each live or ended run by id: what the broadcast's menu reads.
    private(set) var runs: [UUID: OperatorRun] = [:]
    /// The broadcast's board, what its sheet draws (`BroadcastBoardHost`); nil while no broadcast exists, and while its
    /// sheet is not showing (`boardShown`), since nothing else reads it. Derived with the rows and written only when it
    /// differs, so a change it draws nothing of (another project's task, the sidebar's frame) redraws no board.
    private(set) var board: BroadcastBoard?
    /// What the Operator is doing now, to each task and each broadcast, as `actingSource` last said.
    private(set) var acting: OperatorActs = .none
    /// What the Operator is doing, read on every derivation. The app points it at its
    /// `OperatorController`; a test or a snapshot at values of its own.
    @ObservationIgnored var actingSource: @MainActor () -> OperatorActs = { .none }
    /// Whether the board's sheet is showing, read on every derivation: the app points it at its sheet slot; a test or
    /// a snapshot that reads `board` alone leaves it true.
    @ObservationIgnored var boardShown: @MainActor () -> Bool = { true }
    /// Whether a sheet that names models without the live board is showing, the Shelf's, read on every derivation: the
    /// labels are read as it opens, and no board is derived for it.
    @ObservationIgnored var labelsWanted: @MainActor () -> Bool = { false }
    /// Reads the agents' model labels, as Settings › Agents lists them, which the board's cards name a model by, live or
    /// on the Shelf: blocking, so run off the main actor each time either sheet opens. The app points it at its model catalogue; nil reads
    /// nothing, and a card names a model by its id.
    @ObservationIgnored var modelLabelSource: (@Sendable () -> BroadcastBoard.ModelLabels)?
    /// The labels last read, or set by a snapshot; a change derives the board again, and redraws the Shelf's, which
    /// reads them.
    var modelLabels: BroadcastBoard.ModelLabels = [:] {
        didSet { if modelLabels != oldValue { refresh() } }
    }
    /// The latest read of the labels, for a test to await.
    @ObservationIgnored private(set) var labelLoad: Task<Void, Never>?

    /// Whether the sidebar has a project, as `AppState.hasProjects` says: every project is a section.
    var hasProjects: Bool { !sections.isEmpty }

    /// The projects' rows that need you, in the order they are drawn: what the folded PROJECTS heading's amber chip
    /// counts and opens. Only what is amber, as the folded OPERATOR heading's (`BroadcastSection.needingAttention`).
    var projectsNeedingAttention: [RowID] {
        sections.flatMap { section in
            section.terminals.filter { $0.status == .needsInput }.map { RowID.terminal($0.id) }
                + section.tasks.filter { $0.status == .needsInput }.map { RowID.task($0.id) }
        }
    }

    /// Whether the projects are folded to their heading: while a broadcast runs and its section is open.
    var projectsFolded: Bool { broadcast.map { !$0.folded } ?? false }

    /// How many times the rows have been derived; the tests count them.
    @ObservationIgnored private(set) var derivations = 0
    /// What the rows were last derived from.
    @ObservationIgnored private var inputs: Inputs?

    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let checkouts: CheckoutMonitor

    init(workspace: WorkspaceStore, live: LiveSessions, checkouts: CheckoutMonitor) {
        self.workspace = workspace
        self.live = live
        self.checkouts = checkouts
        refresh()
    }

    /// Everything the rows are made of. Not the whole workspace: `sidebarFrame`, the last-used agents and models, and
    /// each task's remembered conversations are saved with the rows but drawn by none of them.
    private struct Inputs: Equatable {
        var items: [SidebarItem], tasks: [TaskItem], terminals: [TerminalItem]
        var sessions: [SessionInfo]
        /// What each of the board's tasks' Claude workers runs now, which `sessions` leaves out: read from every tab only
        /// while the board shows, since nothing else draws it.
        var liveModels: [UUID: BroadcastBoard.LiveModel]
        /// What the board's cards name each model by, read only while the board shows.
        var modelLabels: BroadcastBoard.ModelLabels
        var branchByCwd: [String: String], projectBranch: [UUID: String], diffByTask: [UUID: DiffStat]
        var runs: [OperatorRun], acting: OperatorActs, folded: Set<UUID>, boardShown: Bool, labelsWanted: Bool
    }

    /// The labels read again, off the main actor, as the board's sheet or the Shelf's opens: a model added in Settings › Agents since
    /// is named the next time it opens.
    private func readModelLabels() {
        guard let source = modelLabelSource else { return }
        labelLoad = Task { [weak self] in
            let labels = await BackgroundWork.run(source)
            // Written only when they differ: an equal write would still redraw what reads them.
            if let self, labels != modelLabels { modelLabels = labels }
        }
    }

    /// `task` as the rows read it: without the conversations its window last showed, which no row draws.
    private static func drawn(_ task: TaskItem) -> TaskItem {
        guard !task.conversations.isEmpty else { return task }
        var task = task
        task.conversations = []
        return task
    }

    /// Derives the rows again if what they are made of changed since they last were. Run by
    /// whoever changes one of those: the workspace's every change, a change to `rowSessions`, a
    /// checkout pass that moved a branch or a diff, and while the board shows any session event, which may have
    /// moved what a worker runs. Says whether `sections` or the broadcast's group changed: what the Dock badge counts.
    @discardableResult
    func refresh() -> Bool {
        let state = workspace.state, shown = boardShown()
        let liveModels = shown ? state.activeRun.map { BroadcastBoard.liveModels(of: $0, state: state, sessions: live.sessions) } : nil
        let next = Inputs(items: state.items, tasks: state.tasks.map(Self.drawn), terminals: state.terminals, sessions: live.rowSessions,
                          liveModels: liveModels ?? [:], modelLabels: shown ? modelLabels : [:],
                          branchByCwd: checkouts.branchByCwd, projectBranch: checkouts.projectBranch,
                          diffByTask: checkouts.diffByTask,
                          runs: state.runs, acting: actingSource(), folded: state.foldedRuns, boardShown: shown,
                          labelsWanted: labelsWanted())
        guard next != inputs else { return false }
        let previous = inputs
        inputs = next
        derivations += 1
        if (shown && previous?.boardShown != true) || (next.labelsWanted && previous?.labelsWanted != true) { readModelLabels() }
        if next.acting != acting { acting = next.acting }
        if next.runs != previous?.runs {
            let runs = Dictionary(next.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if runs != self.runs { self.runs = runs }
        }
        let broadcast = SidebarModel.broadcastSection(state: state, sessions: next.sessions, branchByCwd: next.branchByCwd,
                                                      diffByTask: next.diffByTask, acting: next.acting)
        let broadcastChanged = broadcast != self.broadcast
        if broadcastChanged { self.broadcast = broadcast }
        let board = !next.boardShown ? nil : state.activeRun.map { run in
            BroadcastBoard.make(run: run, state: state, acting: next.acting,
                                requests: OperatorRequests.open(run: run, state: state), sessions: next.sessions,
                                liveModels: next.liveModels, modelLabels: next.modelLabels)
        }
        if board != self.board { self.board = board }
        let entries = SidebarModel.entries(state: state, sessions: next.sessions, branchByCwd: next.branchByCwd,
                                           projectBranch: next.projectBranch, diffByTask: next.diffByTask, acting: next.acting.tasks)
        // Rebuilt only when their own list changed, since most derivations are for a status; and
        // written only when the lookup differs, which a reordered list leaves as it was.
        if next.tasks != previous?.tasks {
            let tasks = Dictionary(next.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if tasks != self.tasks { self.tasks = tasks }
        }
        if next.terminals != previous?.terminals {
            let terminals = Dictionary(next.terminals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if terminals != self.terminals { self.terminals = terminals }
        }
        guard entries != self.entries else { return broadcastChanged }
        self.entries = entries
        let sections = entries.compactMap { if case .project(let section) = $0 { section } else { nil } }
        guard sections != self.sections else { return broadcastChanged }
        self.sections = sections
        return true
    }

    /// The footer's context row, under SYSTEM, for `row`: what runs in the task's or terminal's
    /// active tab and its last-known `ctx`. With nothing selected there is no such row at all.
    /// Read from the rows' tabs and context fills, so a fill redraws the footer alone.
    func usageRow(for row: RowSelection?) -> UsageTaskRow? {
        let contexts = live.contextPercents(for: row)
        switch row {
        case .task(let id):
            guard let task = tasks[id] else { return nil }
            return SidebarModel.usageTaskRow(taskId: id, agent: task.agent, sessions: live.rowSessions, contexts: contexts)
        case .terminal(let id):
            guard let terminal = terminals[id] else { return nil }
            return SidebarModel.usageTerminalRow(windowId: terminal.windowId, sessions: live.rowSessions, contexts: contexts)
        case .project, .operation, nil: return nil
        }
    }
}
