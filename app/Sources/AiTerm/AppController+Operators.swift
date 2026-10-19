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
    /// OPERATORS' "+", or the Operator header's: New Operation…, started on Settings › Operator's
    /// profile. Started, the broadcast's row is selected; its window comes forward by the operator
    /// controller's own start.
    func presentNewOperation() {
        guard canChangeWorkspace else { return }
        let controller = operatorController
        sheets.presentNewOperation { [weak self] profile, prompt, done in
            let id = try await controller.startOperation(profile: profile, prompt: prompt, done: done)
            self?.focus.browse(.operation(id))
            return id
        }
    }
}

extension AppController {
    /// An operation's caption chips, its Overview…, ⌘I, or a notification's click: its overview, over
    /// whatever sheet is up.
    func presentOverview(run id: UUID) {
        guard state.runs.contains(where: { $0.id == id && $0.state != .stopped }) else { return }
        sheets.present(operatorSheet: .operationOverview(id))
    }

    /// The overview a notification's click asked for (D7 sets `OperatorController.presentOverview`),
    /// held behind an editing sheet, then presented and cleared so it opens once.
    func presentRequestedOverview() {
        guard let id = operatorController.presentOverview else { return }
        if let sheet {
            guard case .operationOverview = sheet else { return }
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

    /// An operation row's menu.
    func perform(_ item: OperatorMenuItem, on run: OperatorRun) {
        switch item {
        case .overview: presentOverview(run: run.id)
        case .rename: presentRename(run: run)
        case .pause: pause(run)
        case .resume: resume(run)
        case .interruptAgents: interruptAgents(run)
        case .endOperation: Task { await confirmEnd(run) }
        default: break
        }
    }

    /// Rename…: the `NameSheet`, on the operation's name.
    func presentRename(run: OperatorRun) { sheets.presentRename(run: run) }

    /// The name sheet's answer. An emptied field keeps the name, as a renamed task's does.
    func rename(run: OperatorRun, to name: String) {
        guard !name.isEmpty, name != run.name else { return }
        let controller = operatorController
        attempt("Couldn’t rename “\(run.name)”") { try controller.rename(run: run.id, to: name) }
    }

    /// Interrupt Agents: each agent at work in the operation gets its own interrupt key — on your click
    /// only, never the operator's (spec §9).
    func interruptAgents(_ run: OperatorRun) {
        let controller = operatorController
        attempt("Couldn’t interrupt the agents of “\(run.name)”") { try await controller.interruptWorkers(run: run.id) }
    }

    /// End Operation…: asks first, then stops the operator for good; its tasks stay. Says whether it ended.
    @discardableResult
    func confirmEnd(_ run: OperatorRun) async -> Bool {
        guard await prompter.ask(OperatorAlerts.endOperation(run)).confirmed else { return false }
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

    /// The operation's chat — its operator's window — brought forward, or back. A refusal to reopen it is
    /// the operator controller's own to report.
    func focusOperatorWindow(_ run: OperatorRun) {
        let controller = operatorController
        focus.browse(.operation(run.id))
        Task { await controller.focusOperatorWindow(run: run.id) }
    }

    /// The overview's buttons, each closing the sheet when it sends you elsewhere. Give It More is the
    /// operator's chat: a finished operation's operator is still there to be given more to do.
    func overviewActions(for run: OperatorRun, dismiss: @escaping @MainActor () -> Void) -> OverviewActions {
        OverviewActions(
            pause: { [weak self] in self?.pause(run) },
            resume: { [weak self] in self?.resume(run) },
            end: { [weak self] confirming in
                guard let self else { return }
                if confirming { Task { if await self.confirmEnd(run) { dismiss() } } } else { self.end(run); dismiss() }
            },
            giveItMore: { [weak self] in self?.focusOperatorWindow(run); dismiss() },
            openTask: { [weak self] id in dismiss(); self?.focus.select(.task(id)) },
            answerInWindow: { [weak self] in self?.focusOperatorWindow(run); dismiss() })
    }
}

extension AppController {
    /// An operator header's chevron.
    func toggleCollapsed(operator handle: String) { rows.toggleCollapsed(operator: handle) }
}

extension AppController {
    /// ⌘I on the list: the selected operation's overview. Says whether there was one.
    @discardableResult
    func showOverviewOfSelection() -> Bool {
        guard let id = focus.selectedOperationId else { return false }
        presentOverview(run: id)
        return sheet != nil
    }
}
