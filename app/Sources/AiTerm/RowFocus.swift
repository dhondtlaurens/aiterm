import Foundation
import AiTermCore

/// The one sidebar row that is selected: a project header, a task (or review) or a terminal. A
/// header has no window: selecting it shows nothing and raises nothing.
enum RowSelection: Equatable {
    case project(UUID), task(UUID), terminal(UUID)

    var id: UUID {
        switch self {
        case .project(let id), .task(let id), .terminal(let id): return id
        }
    }
}

/// Which sidebar row is selected, and bringing its window forward. Browsing — an arrow key, a new
/// row, a notification raising a window — changes the selection only; an activation owns a
/// cancelable request that checks, after each suspension, that it still serves the latest
/// selection, so a slow request for an earlier row can never take focus from a later one.
///
/// Every activation returns its `Task`, so a caller — a test above all — awaits it rather than
/// waiting out a delay.
@MainActor
@Observable
final class RowFocus {
    /// Written only by `setSelection(_:)`, through `browse` or an activation.
    private(set) var selection: RowSelection?
    /// The request bringing the selected row's window forward, while one is in flight.
    @ObservationIgnored private(set) var activation: Task<Void, Never>?
    /// Moves on with every selection write, so work that started for an older one can tell.
    @ObservationIgnored private(set) var generation = 0
    /// The window this app last asked iTerm2 to raise. Its `window.activated` is that request's echo,
    /// not news, and can arrive after the arrows have moved on to a row with no window.
    @ObservationIgnored private var selfRaised: String?

    /// How long a peek waits before moving a window: long enough that arrowing past rows shows only
    /// the one the arrows stop on.
    let peekDelay: Duration
    private let workspace: @MainActor () -> AppState
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let taskFrame: @MainActor () -> Frame
    /// Brings iTerm2 forward once a chosen row's window is frontmost in it: the daemon raises the
    /// window inside iTerm2 but leaves the app behind AiTerm.
    private let activateIterm: @MainActor () -> Void
    /// Whether a task is on its way out. Its row can be selected, but its window — closing, or
    /// gone — is never raised.
    private let isRemoving: @MainActor (UUID) -> Bool
    /// A window a request found already gone.
    private let onWindowGone: @MainActor (String) -> Void
    /// Where a window that would not come forward is reported.
    private let notices: Notices

    init(peekDelay: Duration = .milliseconds(120),
         workspace: @escaping @MainActor () -> AppState,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         taskFrame: @escaping @MainActor () -> Frame,
         activateIterm: @escaping @MainActor () -> Void,
         isRemoving: @escaping @MainActor (UUID) -> Bool,
         onWindowGone: @escaping @MainActor (String) -> Void,
         notices: Notices) {
        self.peekDelay = peekDelay
        self.workspace = workspace
        self.daemon = daemon
        self.taskFrame = taskFrame
        self.activateIterm = activateIterm
        self.isRemoving = isRemoving
        self.onWindowGone = onWindowGone
        self.notices = notices
    }

    var selectedTaskId: UUID? {
        if case .task(let id) = selection { return id }
        return nil
    }

    var selectedTerminalId: UUID? {
        if case .terminal(let id) = selection { return id }
        return nil
    }

    var selectedProjectId: UUID? {
        if case .project(let id) = selection { return id }
        return nil
    }

    /// The row with this id, whichever kind it is — what the list's own selection hands over.
    func row(id: UUID) -> RowSelection? {
        let state = workspace()
        if state.task(id: id) != nil { return .task(id) }
        if state.terminal(id: id) != nil { return .terminal(id) }
        if state.project(id: id) != nil { return .project(id) }
        return nil
    }

    /// Changes the selection only: nothing is raised.
    func browse(_ row: RowSelection?) {
        guard row != selection else { return }
        setSelection(row)
    }

    /// Every selection write: it makes whatever activation was in flight for the old one stale.
    private func setSelection(_ row: RowSelection?) {
        generation += 1
        activation?.cancel()
        activation = nil
        selection = row
    }

    /// A click or Return: selects the row, brings its window forward and iTerm2 with it, and marks a
    /// task seen. A project header is only selected: it has no window.
    @discardableResult
    func select(_ row: RowSelection) -> Task<Void, Never>? {
        switch row {
        case .project:
            browse(row)
            return nil
        case .task(let id):
            return activate(row, failure: "Couldn’t activate the window") { daemon in
                _ = try? await daemon.markSeen(taskId: id.uuidString)
            }
        case .terminal:
            return activate(row, failure: "Couldn’t activate the terminal")
        }
    }

    /// Return on the list: the selected row, as a click would choose it.
    @discardableResult
    func activateSelection() -> Task<Void, Never>? {
        guard let selection, row(id: selection.id) != nil else { return nil }
        return select(selection)
    }

    /// The arrow keys: selects the row and shows its window — placed beside the sidebar and raised
    /// in iTerm2 — without bringing iTerm2 forward, so the keyboard stays in the sidebar. Looking is
    /// not acting, so a task is not marked seen. Return or a click commits.
    ///
    /// The row already selected is left be, as the list re-reports it, unless `force`: Focus View
    /// shows the first waiting row's window whether or not it was already selected.
    @discardableResult
    func peek(_ row: RowSelection?, force: Bool = false) -> Task<Void, Never>? {
        guard force || row != selection else { return nil }
        guard let row, window(for: row) != nil else { browse(row); return nil }
        return activate(row, failure: "Couldn’t show the window", focus: false)
    }

    /// `peek`, for the list, which knows its rows by id alone.
    @discardableResult
    func peek(id: UUID?) -> Task<Void, Never>? { peek(id.flatMap(row(id:))) }

    /// Selects a row and brings its window forward — re-snapped beside the sidebar, then activated,
    /// then iTerm2 too unless this is a peek — and then runs `then`. Each step checks it still serves
    /// the latest selection. A click on the row already selected starts a new request too,
    /// superseding its last one. A row being removed is selected and nothing more.
    @discardableResult
    private func activate(_ row: RowSelection, failure: String, focus: Bool = true,
                          then: ((any DaemonCommands) async -> Void)? = nil) -> Task<Void, Never>? {
        setSelection(row)
        let window = window(for: row)
        guard !isRemoving(row.id), let daemon = daemon(), window != nil || then != nil else { return nil }
        let generation = generation, delay = focus ? nil : peekDelay
        let isCurrent = { [unowned self] in !Task.isCancelled && generation == self.generation }
        let task = Task {
            defer { if generation == self.generation { activation = nil } }
            if let window {
                do {
                    if let delay { try await Task.sleep(for: delay) }
                    try Task.checkCancellation()
                    try await daemon.setFrame(windowId: window, frame: taskFrame())
                    guard isCurrent() else { return }
                    selfRaised = window
                    try await daemon.activate(windowId: window)
                    guard focus, isCurrent() else { return }
                    activateIterm()
                } catch let error as DaemonError where error.isNotFound {
                    if selfRaised == window { selfRaised = nil }
                    onWindowGone(window)
                } catch is CancellationError { return }
                catch {
                    if selfRaised == window { selfRaised = nil }
                    notices.report(OperationIssue(title: failure + ".", error: error))
                }
            }
            guard let then, isCurrent() else { return }
            await then(daemon)
        }
        activation = task
        return task
    }

    /// Keeps the selection aligned when iTerm2 is activated outside AiTerm — for example, by
    /// clicking a Claude or Codex notification. This deliberately does not `select`: the window is
    /// already frontmost, so re-activating it could steal focus back from an iTerm2 dialog that the
    /// notification opened. The echo of this app's own last raise is dropped once: it can arrive
    /// after the arrows have moved on to a row with no window, and would pull the selection back.
    func windowActivated(_ windowId: String) {
        if windowId == selfRaised { selfRaised = nil; return }
        // A delayed activation event must not overwrite a newer local selection.
        if activation != nil { return }
        let state = workspace()
        if let task = state.tasks.first(where: { $0.windowId == windowId }) {
            browse(.task(task.id))
        } else if let terminal = state.terminals.first(where: { $0.windowId == windowId }) {
            browse(.terminal(terminal.id))
        }
    }

    /// Drops a selection whose row has gone.
    func dropStale() {
        if let selection, row(id: selection.id) == nil { browse(nil) }
    }

    /// Cancels an activation in flight, as the app stops.
    func cancel() {
        activation?.cancel()
    }

    private func window(for row: RowSelection) -> String? {
        let state = workspace()
        return switch row {
        case .project: nil
        case .task(let id): state.task(id: id)?.windowId
        case .terminal(let id): state.terminal(id: id)?.windowId
        }
    }
}
