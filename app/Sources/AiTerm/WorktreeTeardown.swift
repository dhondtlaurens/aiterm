import Foundation
import AiTermCore

/// The part of taking a task's worktree down that Remove and Archive share: the question about its
/// uncommitted work, and its window closed — and confirmed closed — before git deletes anything. A
/// process still running in the window — a dev server's watcher — writes files back into a checkout
/// being deleted, and git then gives up halfway. What follows — a branch, the row — is each owner's.
@MainActor
struct WorktreeTeardown {
    /// The action the questions are worded for.
    enum Verb {
        case remove, archive

        var deleteDetail: String {
            switch self {
            case .remove: "Removing this worktree permanently deletes its uncommitted changes and untracked files."
            case .archive: "Archiving deletes its uncommitted changes and untracked files. The branch is kept."
            }
        }

        var deleteButton: String {
            switch self {
            case .remove: "Delete Changes and Remove"
            case .archive: "Delete Changes and Archive"
            }
        }
    }

    let workspace: WorkspaceStore
    let work: WorkInFlight
    let prompter: Prompter
    let daemon: @MainActor () -> (any DaemonCommands)?

    /// Whether deleting the task's unsaved work is agreed to. Keeping is the default, on ↩ and ⎋
    /// both; deleting is the plain grey button beside it, never marked red — the red default is for
    /// a button ↩ can press. False too when the workspace locked while the question was up.
    func confirmDeletingUnsavedWork(of task: TaskItem, verb: Verb) async -> Bool {
        let answer = await prompter.ask(AlertPrompt(
            message: "The worktree has uncommitted changes",
            detail: verb.deleteDetail,
            buttons: [task.kind == .review ? "Keep Review" : "Keep Task", verb.deleteButton], escape: 0))
        return answer.button == 1 && workspace.canChangeWorkspace
    }

    /// Closes the window the task has now. The row drops it first, so the window's own
    /// `window.closed` finds it windowless already and asks nothing, and `operation(true)` tells the
    /// window plan the window is this work's to settle. A window that will not close is given back,
    /// and nothing is deleted. A row with no window has nothing to close; one whose window cannot be
    /// reached without a daemon is left open — or, `requiringDaemon`, stops the teardown.
    func closeWindow(of task: TaskItem, holding token: WorkInFlight.Token, requiringDaemon: Bool,
                     operation: @escaping (_ windowLetGo: Bool) -> TaskOperation) async throws {
        guard let i = workspace.state.tasks.firstIndex(where: { $0.id == task.id }),
              let wid = workspace.state.tasks[i].windowId else { return }
        guard let daemon = daemon() else {
            if requiringDaemon { throw TeardownStop.noDaemon }
            return
        }
        work.update(token, to: operation(true))
        // Windowless at once, so the window's own `window.closed` finds it so and asks nothing; a
        // snapshot no longer drops a row, so this need not be on disk before the window closes.
        workspace.mutate { $0.tasks[i].windowId = nil }
        do { try await daemon.closeWindowIfOpen(wid) }
        catch {
            work.update(token, to: operation(false))
            if let j = workspace.state.tasks.firstIndex(where: { $0.id == task.id }), workspace.state.tasks[j].windowId == nil {
                workspace.mutate { $0.tasks[j].windowId = wid }
            }
            throw TeardownStop.windowStayedOpen(ActionUnavailable("Its iTerm2 window did not close, so nothing was deleted. "
                                                                  + OperationIssue.reason(of: error)))
        }
    }
}

/// Why a teardown stopped before git deleted anything, told apart from git's refusals so the row can
/// say which it was.
enum TeardownStop: Error {
    /// The window would not close, so nothing was deleted.
    case windowStayedOpen(ActionUnavailable)
    /// An archive found no daemon to close the window with, so nothing was deleted.
    case noDaemon
}
