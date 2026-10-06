import Foundation
import AiTermCore

/// The sidebar's rows, derived once for everyone who reads them: the list draws `entries`, and the
/// Dock badge, Focus View and List View read `sections`. They are derived again only when what
/// they are made of changes — the workspace's projects, dividers, tasks and terminals, the tabs as
/// the rows read them (`LiveSessions.rowSessions`), and the branches and diffs on disk — and each
/// property is written only when its value differs.
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
    /// Each task and terminal by id: the saved item a drawn row also reads.
    private(set) var tasks: [UUID: TaskItem] = [:]
    private(set) var terminals: [UUID: TerminalItem] = [:]

    /// Whether the sidebar has a project, as `AppState.hasProjects` says: every project is a section.
    var hasProjects: Bool { !sections.isEmpty }

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

    /// Everything the rows are made of. Not the whole workspace: `sidebarFrame` and the last-used
    /// agents and models are saved with the rows but drawn by none of them.
    private struct Inputs: Equatable {
        var items: [SidebarItem], tasks: [TaskItem], terminals: [TerminalItem]
        var sessions: [SessionInfo]
        var branchByCwd: [String: String], projectBranch: [UUID: String], diffByTask: [UUID: DiffStat]
    }

    /// Derives the rows again if what they are made of changed since they last were. Run by
    /// whoever changes one of those: the workspace's every change, a change to `rowSessions`, and a
    /// checkout pass that moved a branch or a diff. Says whether `sections` changed.
    @discardableResult
    func refresh() -> Bool {
        let state = workspace.state
        let next = Inputs(items: state.items, tasks: state.tasks, terminals: state.terminals, sessions: live.rowSessions,
                          branchByCwd: checkouts.branchByCwd, projectBranch: checkouts.projectBranch,
                          diffByTask: checkouts.diffByTask)
        guard next != inputs else { return false }
        let previous = inputs
        inputs = next
        derivations += 1
        let entries = SidebarModel.entries(state: state, sessions: next.sessions, branchByCwd: next.branchByCwd,
                                           projectBranch: next.projectBranch, diffByTask: next.diffByTask)
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
        guard entries != self.entries else { return false }
        self.entries = entries
        let sections = entries.compactMap { if case .project(let section) = $0 { section } else { nil } }
        guard sections != self.sections else { return false }
        self.sections = sections
        return true
    }

    /// The usage footer's CONTEXT row for `row`: what runs in the task's or terminal's active tab
    /// and its last-known `ctx`. With nothing selected there is no such row at all. Read from the
    /// rows' tabs, so a session event that moved only a fill redraws it through the fill alone.
    func usageRow(for row: RowSelection?) -> UsageTaskRow? {
        let contexts = live.contextPercents(for: row)
        switch row {
        case .task(let id):
            guard let task = tasks[id] else { return nil }
            return SidebarModel.usageTaskRow(taskId: id, agent: task.agent, sessions: live.rowSessions, contexts: contexts)
        case .terminal(let id):
            guard let terminal = terminals[id] else { return nil }
            return SidebarModel.usageTerminalRow(windowId: terminal.windowId, sessions: live.rowSessions, contexts: contexts)
        case .project, nil: return nil
        }
    }
}
