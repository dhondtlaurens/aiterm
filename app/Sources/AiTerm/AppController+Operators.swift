import Foundation
import Observation
import AiTermCore

/// What the operator views ask of the app, forwarded to the operator controller (Part D). A refusal
/// lands in the banner, as every other action's does, named after what it was for.
extension AppController {
    /// A driven task row's Take Over, Hand Back or Stop Task….
    func perform(_ item: OperatorMenuItem, on task: TaskItem) {
        let controller = operatorController
        switch item {
        case .takeOver:
            attempt("Couldn’t take over “\(task.title)”") { try await controller.takeOver(task: task.id) }
        case .handBack:
            attempt("Couldn’t hand “\(task.title)” back") { try await controller.handBack(task: task.id) }
        case .stopTask:
            Task { await confirmStop(task) }
        default:
            break
        }
    }

    /// Stop Task…: asks first, then the task ends `stopped` for its operator — its dependents wait for
    /// you; its window, branch and any agent at work stay. Says whether it was stopped.
    @discardableResult
    func confirmStop(_ task: TaskItem) async -> Bool {
        guard await prompter.ask(OperatorAlerts.stopTask(task)).confirmed else { return false }
        let controller = operatorController
        attempt("Couldn’t stop “\(task.title)”") { try controller.stop(task: task.id) }
        return true
    }

    /// Runs `work` and reports what it threw as `title`.
    func attempt(_ title: String, _ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await work() } catch { report(OperationIssue(title: title + ".", error: error)) }
        }
    }
}

extension AppController {
    /// The OPERATOR heading's "+": New Broadcast…, its help following Settings › Operator's slices as
    /// they are now, the profile the broadcast freezes as it starts. Started, the broadcast's row is
    /// selected; its window comes forward by the operator controller's own start.
    func presentNewBroadcast() {
        guard canChangeWorkspace else { return }
        let controller = operatorController
        let slices = controller.ports.profile?().slices ?? .none
        sheets.presentNewBroadcast(slices: slices, loadJiraProjects: { [weak self] in try await self?.loadJiraProjects() ?? [] }) { [weak self] request in
            let id = try await controller.startBroadcast(name: request.name, jiraProjectKeys: request.jiraProjectKeys,
                                                         projectIds: request.projectIds, prompt: request.prompt,
                                                         review: request.review, done: request.done)
            self?.focus.browse(.operation(id))
            return id
        }
    }
}

extension AppController {
    /// The broadcast row's click or ↩ (`openBroadcast`), or a notification's click: its board, over
    /// whatever sheet is up.
    func presentOverview(run id: UUID) {
        guard state.activeRun?.id == id else { return }
        sheets.present(operatorSheet: .broadcastBoard(id))
    }

    /// The board a notification's click asked for (D7 sets `OperatorController.presentOverview`),
    /// held behind an editing sheet, then presented and cleared so it opens once.
    func presentRequestedOverview() {
        guard let id = operatorController.presentOverview else { return }
        if let sheet {
            guard case .broadcastBoard = sheet else { return }
        }
        operatorController.presentOverview = nil
        presentOverview(run: id)
    }

    /// Watches `OperatorController.presentOverview` for as long as the app runs: each request is
    /// presented on the main actor's next turn — Observation reports a change before it is stored —
    /// and the watch re-armed.
    func watchOverviewRequests() {
        withObservationTracking {
            _ = operatorController.presentOverview
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                presentRequestedOverview()
                watchOverviewRequests()
            }
        }
    }

    /// The broadcast row's menu and its VoiceOver actions, on the broadcast as it is now.
    func perform(_ item: OperatorMenuItem, onBroadcast id: UUID) {
        guard let run = state.activeRun, run.id == id else { return }
        perform(item, on: run)
    }

    /// The broadcast row's menu.
    func perform(_ item: OperatorMenuItem, on run: OperatorRun) {
        switch item {
        case .rename: presentRename(run: run)
        case .pause: pause(run)
        case .resume: resume(run)
        case .endBroadcast: Task { await confirmEnd(run) }
        default: break
        }
    }

    /// A click or ↩ on the broadcast row (spec §3, §9): its board opens over the sidebar and the row is
    /// selected; the sheet is what comes forward. With the Operator's window closed — no tab of it listed,
    /// whatever window id was recorded — the window is asked back from the operator controller behind the
    /// board (`RowFocus.reopenOperatorBehind`), resuming the broadcast. Until iTerm2's tabs are known (a
    /// launch, a reconnect) the recorded window id is all there is to go by. Returns the reopening, if one
    /// started.
    @discardableResult
    func openBroadcast(_ id: UUID) -> Task<Void, Never>? {
        guard let run = state.activeRun, run.id == id else { return nil }
        let operators = operatorController
        let closed = operators.tabsKnown ? operators.operatorTab(of: id) == nil : run.operatorWindowId == nil
        focus.browse(.operation(id))
        let reopening = closed ? focus.reopenOperatorBehind(id) : nil
        presentOverview(run: id)
        return reopening
    }

    /// Rename…: the `NameSheet`, on the broadcast's name.
    func presentRename(run: OperatorRun) { sheets.presentRename(run: run) }

    /// The name sheet's answer. An emptied field keeps the name, as a renamed task's does.
    func rename(run: OperatorRun, to name: String) {
        guard !name.isEmpty, name != run.name else { return }
        let controller = operatorController
        attempt("Couldn’t rename “\(run.name)”") { try controller.rename(run: run.id, to: name) }
    }

    /// End Broadcast…: asks first, saying what happens to its tasks (`OperatorController.endPrompt`), then
    /// ends it. Says whether it ended.
    @discardableResult
    func confirmEnd(_ run: OperatorRun) async -> Bool {
        guard await prompter.ask(operatorController.endPrompt(run: run)).confirmed else { return false }
        end(run)
        return true
    }

    func pause(_ run: OperatorRun) {
        let controller = operatorController
        attempt("Couldn’t pause “\(run.name)”") { try controller.pause(run: run.id) }
    }

    func resume(_ run: OperatorRun) {
        let controller = operatorController
        attempt("Couldn’t resume “\(run.name)”") { try await controller.resume(run: run.id) }
    }

    func end(_ run: OperatorRun) {
        let controller = operatorController
        attempt("Couldn’t end “\(run.name)”") { try await controller.end(run: run.id) }
    }

    /// The broadcast's chat — its Operator's window — brought forward as its row's click brings it: raised
    /// when it is open, reopened when it is closed (`OperatorController.reopenOperator`, which reports a refusal).
    func openOperatorWindow(_ run: OperatorRun) {
        focus.select(.operation(run.id))
    }

    /// The board's buttons, each on the broadcast as it is when pressed, and nothing once it is no longer
    /// the active one. End Broadcast… asks first and closes the board once it ended; the debrief's End
    /// Broadcast asks nothing. Start Fresh keeps the board up, its footer back to the moment's.
    func boardActions(for id: UUID, dismiss: @escaping @MainActor () -> Void) -> BoardActions {
        BoardActions(
            open: { [weak self] opens in self?.open(opens, run: id) },
            pause: { [weak self] in self?.onActiveRun(id) { self?.pause($0) } },
            resume: { [weak self] in self?.onActiveRun(id) { self?.resume($0) } },
            end: { [weak self] confirming in
                self?.onActiveRun(id) { run in
                    guard let self else { return }
                    if confirming { Task { if await self.confirmEnd(run) { dismiss() } } } else { self.end(run); dismiss() }
                }
            },
            startFresh: { [weak self] in self?.onActiveRun(id) { self?.startFresh($0) } })
    }

    /// `work` on the broadcast with this id, as it is now, while it is the active one.
    private func onActiveRun(_ id: UUID, _ work: (OperatorRun) -> Void) {
        guard let run = state.activeRun, run.id == id else { return }
        work(run)
    }

    /// What a card's click opens, the board already closed (spec §4, §13): the task's window, or the
    /// Operator's — raised when it is open, reopened in front when it is closed. A problem AiTerm hit is the
    /// sidebar banner's, which already shows it with its recovery: nothing else comes forward. Nothing at all
    /// once the broadcast is no longer the active one: a card never acts on an ended broadcast.
    func open(_ opens: BroadcastBoard.Opens, run id: UUID) {
        guard let run = state.activeRun, run.id == id else { return }
        switch opens {
        case .taskWindow(let task): focus.select(.task(task))
        case .operatorWindow: openOperatorWindow(run)
        case .sidebarBanner, .nothing: break
        }
    }

    /// Start Fresh, from the board's footer when the Operator's conversation can't be resumed.
    func startFresh(_ run: OperatorRun) {
        let controller = operatorController
        attempt("Couldn’t start a fresh Operator for “\(run.name)”") { try await controller.startFresh(run: run.id) }
    }
}
