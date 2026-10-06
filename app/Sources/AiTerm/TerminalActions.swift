import Foundation
import AiTermCore

/// A project's terminals: a new one's window, a window reopened for a row that lost its own, and a
/// terminal closed. A terminal is a shell in the project folder with nothing on disk behind it, so
/// each of these is a window and a row, and nothing else.
@MainActor
final class TerminalActions {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let notices: Notices
    private let checkouts: CheckoutMonitor
    private let focus: RowFocus
    private let tiling: SidebarTiling
    private let daemon: @MainActor () -> (any DaemonCommands)?
    /// Brings iTerm2 forward once a new terminal's window is frontmost in it: the daemon raises the
    /// window inside iTerm2 but leaves the app behind AiTerm.
    private let activateIterm: @MainActor () -> Void

    init(workspace: WorkspaceStore, work: WorkInFlight, notices: Notices, checkouts: CheckoutMonitor, focus: RowFocus,
         tiling: SidebarTiling, daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         activateIterm: @escaping @MainActor () -> Void) {
        self.workspace = workspace
        self.work = work
        self.notices = notices
        self.checkouts = checkouts
        self.focus = focus
        self.tiling = tiling
        self.daemon = daemon
        self.activateIterm = activateIterm
    }

    /// A new terminal named `name`, or the next free name when it is empty, in a window of its own
    /// in the project folder.
    @discardableResult
    func newTerminal(project: Project, name: String) -> Task<Void, Never>? {
        guard workspace.canChangeWorkspace else { return nil }
        guard let daemon = daemon() else { notices.report(.disconnected("creating the terminal")); return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? workspace.state.suggestedTerminalName(in: project.id) : trimmed
        let opening = work.begin(.openingTerminal, onProject: project.id)
        // Selected like a new task, and — unlike one — brought forward: an empty shell is only
        // useful once typed into. Neither if another row was chosen meanwhile.
        let generation = focus.generation
        return Task {
            defer { if let opening { work.end(opening) } }
            guard workspace.canChangeWorkspace else { return }
            do {
                let wid = try await daemon.createTerminalWindow(projectId: project.id.uuidString, cwd: project.path, title: name,
                                                                frame: tiling.taskFrame())
                // The project's removal waits for this window (`.openingTerminal`), so the project
                // should still be here; should it not be, a row whose project is gone would fail
                // every save, so the window is closed, not adopted.
                guard workspace.state.project(id: project.id) != nil else {
                    try? await daemon.closeWindowIfOpen(wid)
                    return
                }
                let item = TerminalItem(id: UUID(), projectId: project.id, name: name, windowId: wid, createdAt: Date())
                workspace.mutate { $0.terminals.append(item) }
                checkouts.refresh()
                guard generation == focus.generation else { return }
                focus.browse(.terminal(item.id))
                activateIterm()
            } catch { notices.report(OperationIssue(title: "Couldn’t open the terminal.", error: error)) }
        }
    }

    /// The terminal twin of `TaskLauncher.reopen(task:)`: a new window in the project's own
    /// directory, adopted by the row that lost its window.
    @discardableResult
    func reopen(terminal: TerminalItem, project: Project) -> Task<Void, Never>? {
        guard workspace.canChangeWorkspace else { return nil }
        guard let current = workspace.state.terminal(id: terminal.id), current.windowId == nil else { return nil }
        guard let daemon = daemon() else { notices.report(.disconnected("Reopen Window again")); return nil }
        guard let reopening = work.begin(.reopening, onTerminal: terminal.id) else { return nil }
        return Task {
            defer { work.end(reopening) }
            guard workspace.canChangeWorkspace else { return }
            do {
                let wid = try await daemon.createTerminalWindow(projectId: project.id.uuidString, cwd: project.path, title: current.name,
                                                                frame: tiling.taskFrame())
                // As for a task's window: a row that went meanwhile cannot adopt it.
                guard let i = workspace.state.terminals.firstIndex(where: { $0.id == terminal.id }) else {
                    try? await daemon.closeWindowIfOpen(wid)
                    return
                }
                workspace.mutate { $0.terminals[i].windowId = wid }
            } catch { notices.report(OperationIssue(title: "Couldn’t reopen the window.", error: error)) }
        }
    }

    /// Closing a terminal touches nothing on disk — there is no worktree behind it — so it needs no
    /// confirmation, unlike removing a task. The row's copy is as old as the click, so the window
    /// closed is the one the terminal has when the close runs: a reopen can have given it one since.
    /// A close while the window is still reopening says so rather than racing it.
    @discardableResult
    func close(terminal: TerminalItem) -> Task<Void, Never>? {
        guard workspace.canChangeWorkspace, let current = workspace.state.terminal(id: terminal.id) else { return nil }
        switch work.operation(onTerminal: terminal.id) {
        case .closing: return nil // the Remove already in flight
        case .reopening:
            notices.report("“\(current.name)” is still reopening its window. Try Remove Terminal again once it has.")
            return nil
        case nil: break
        }
        guard let closing = work.begin(.closing, onTerminal: terminal.id) else { return nil }
        return Task {
            defer { work.end(closing) }
            guard workspace.canChangeWorkspace else { return }
            if let wid = workspace.state.terminal(id: terminal.id)?.windowId {
                guard let daemon = daemon() else { notices.report(.disconnected("Remove Terminal again")); return }
                do { try await daemon.closeWindowIfOpen(wid) }
                catch { notices.report(OperationIssue(title: "Couldn’t close the terminal.", error: error)); return }
            }
            workspace.mutate { $0.terminals.removeAll { $0.id == terminal.id } }
        }
    }
}

extension AppState {
    /// The name New Terminal suggests for the project's next terminal, and the one an emptied name
    /// field falls back to.
    func suggestedTerminalName(in projectId: UUID) -> String {
        TerminalItem.suggestedName(existing: terminals.filter { $0.projectId == projectId })
    }
}
