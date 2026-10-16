import Foundation
import AiTermCore

/// What you do to an operation and its tasks (spec §8, §9). Every change is persisted, so a pause or an
/// end survives a restart, and reconciliation never undoes one.
extension OperatorController {
    // -- a task -----------------------------------------------------------------------------------
    /// Take over (spec §8): the task's ownership generation moves on — a send in flight ends partial,
    /// queued ones are dropped — and the operator's tools refuse it until you hand it back. The operator
    /// hears of it, a moment its lessons may come from (spec §4.5). Taken over already, it only sets the
    /// generation on the tabs again, which is what a retry after a failure is.
    func takeOver(task id: UUID) async throws {
        guard let operated = workspace.state.task(id: id)?.operated else { throw ActionUnavailable("That task is no operator’s.") }
        guard !operated.takenOver else { return try await setOwnership(operated.ownership, on: id) }
        let ownership = operated.ownership + 1
        workspace.mutate { $0.updateOperated(id) { $0.takenOver = true; $0.ownership = ownership } }
        waker.say("the person took over \(operated.key)", to: operated.runId)
        try await setOwnership(ownership, on: id)
    }

    /// Hand back: the operator may act on it again, and is told. The generation stays what the takeover
    /// set: the helper never lowers one, and the operator's next send carries this one. A queued task
    /// that was held back by the takeover may start now.
    func handBack(task id: UUID) async throws {
        guard let operated = workspace.state.task(id: id)?.operated, operated.takenOver else { return }
        workspace.mutate { $0.updateOperated(id) { $0.takenOver = false } }
        waker.say("\(operated.key) is handed back", to: operated.runId)
        runChanged(operated.runId)
        try await setOwnership(operated.ownership, on: id)
    }

    /// Stop Task…, in the row's menu (E6, confirmed first): the task ends `stopped`, its dependents
    /// blocked; its worker, if any, runs on. A question about it has nothing left to ask, so it is
    /// resolved — an open one would keep the operation from completing. The operation is then settled and
    /// started the way every other end is: the last open task stopped completes it, and its slot is free.
    func stop(task id: UUID) throws {
        guard let runId = workspace.state.task(id: id)?.operated?.runId else { throw ActionUnavailable("That task is no operator’s.") }
        do {
            try workspace.mutate { state in
                _ = try OperatedTransitions.apply(.stop, toTask: id, in: &state, by: .you)
                state.updateRun(id: runId) { run in
                    for i in run.questions.indices where run.questions[i].task == id && run.questions[i].resolution == nil {
                        run.questions[i].resolution = "Stopped by you."
                    }
                }
            }
        } catch let refused as OperatedTransitionError {
            throw ActionUnavailable(refused.description)
        }
        runChanged(runId)
    }

    /// A worker window you closed, back on your click or ↩ on its row (integration decision 7): its
    /// conversation resumed in a window behind your work under the operation's flags (`WorkerStarter.reopen`),
    /// the row's `windowId` left on that window so the click can raise it — whether it still names the closed
    /// one or not. Never a second worker, and never a fresh launch: a tab still tagged with the task is
    /// brought forward instead, and with iTerm2's tabs not known none is opened. A launch that never showed a window
    /// is left to the reconciler. What stands in the way is said in the banner.
    func reopenWorker(task id: UUID) async {
        guard let task = workspace.state.task(id: id), task.operated != nil else { return }
        if let tab = live.sessions.filter({ $0.taskUUID == id }).min(by: { $0.tabIndex < $1.tabIndex }) {
            try? await daemon()?.activate(windowId: tab.windowId)
            return
        }
        guard !starter.starting.contains(id) else { return }
        // A launch that showed no window is the reconciler's to launch again; a click only asks it to look.
        if task.hasCheckout, let launch = task.operated?.launch, launch.openedAt == nil {
            reconcileTick()
            return
        }
        let reason: String
        if daemon() == nil || !tabsKnown { reason = OperationIssue.disconnected("again").title }
        else if !task.hasCheckout { reason = "It hasn’t started: AiTerm opens its window when it does." }
        else if !task.conversations.contains(where: { $0.agent == task.agent }) { reason = "Its worker left no conversation to resume." }
        else if let opening = starter.reopen(id) {
            await opening.value
            // The starter logs a window that would not open and leaves the row as it was.
            if workspace.state.task(id: id)?.windowId == task.windowId, !live.sessions.contains(where: { $0.taskUUID == id }) {
                notices.report(OperationIssue(title: "Couldn’t reopen \(task.title)’s worker.", reason: "Its window wouldn’t open."))
            }
            return
        } else { return }
        notices.report(OperationIssue(title: "Couldn’t reopen \(task.title)’s worker.", reason: reason))
    }

    /// The task's generation on each of its tabs, every one tried: the first failure is thrown after. With
    /// no helper nothing is lost — the change is saved, and `resendOwnership` sets it once one attaches.
    private func setOwnership(_ ownership: Int, on task: UUID) async throws {
        guard let daemon = daemon() else { return }
        var failure: (any Error)?
        for tab in live.sessions where tab.taskUUID == task {
            do { try await daemon.setOwnership(sessionId: tab.sessionId, ownership: ownership) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    // -- an operation -----------------------------------------------------------------------------
    /// Pause (spec §9): no task starts, no message is delivered, nothing is accepted; workers finish
    /// their turn. Persisted as your intent: a pause that cannot be saved is taken back, so the operation
    /// never reads as paused for what the file would not hold. A delivery already in flight is not
    /// cancelled — the daemon offers no way to — it ends as the daemon's rules end it.
    func pause(run id: UUID) throws {
        guard let run = self.run(id: id), [.planning, .active, .operatorOffline].contains(run.state) else {
            throw ActionUnavailable("Only an operation under way can be paused.")
        }
        let before = snapshot(of: id)
        mutateRun(id) { $0.intent = .paused; $0.state = .paused }
        guard workspace.flush() else {
            restore(before)
            throw ActionUnavailable("The pause couldn’t be saved, so the operation was left as it was.")
        }
    }

    /// Resume (spec §9), from paused or offline: an operator still there is kept and woken; one gone is
    /// reopened — its conversation resumed, or a fresh operator briefed from the run — before anything
    /// changes, so a reopening that fails leaves the operation as it was. Then whatever was held back starts.
    func resume(run id: UUID) async throws {
        guard let run = self.run(id: id), run.state == .paused || run.state == .operatorOffline else { return }
        // A reopening already under way (a second click) is the first one's to finish: it sets the state and wakes.
        if operatorTab(of: id) == nil, try await reopenOperatorWindow(id) == .underway { return }
        // The reopening took a while: it may have been ended meanwhile.
        guard let current = self.run(id: id), current.state != .stopped, current.intent != .stopped else { return }
        if current.state == .paused || current.state == .operatorOffline {
            mutateRun(id) { $0.intent = nil; $0.state = RunReconciler.resumedState(of: $0) }
        }
        waker.say("resumed", to: id)
        runChanged(id)
    }

    /// End operation (spec §9): your stop, persisted first — one that cannot be saved is taken back and
    /// nothing else is done. Its open tasks end `stopped`, its second opinions are cancelled and its
    /// operator is no longer woken, and the slots its tasks held go to what waits; its token is revoked and
    /// its operator's window closed, each only logged when it fails (an attach does both again). Workers already running are left to finish — Interrupt workers
    /// is separate. A complete operation stays complete, ended.
    func end(run id: UUID) async throws {
        guard let run = self.run(id: id), run.intent != .stopped else { return }
        let before = snapshot(of: id)
        workspace.mutate { state in
            state.updateRun(id: id) { run in
                run.intent = .stopped
                if run.state != .complete { run.state = .stopped }
            }
            for task in state.tasks(inRun: id) where task.operated?.state.isOpen == true {
                _ = try? OperatedTransitions.apply(.stop, toTask: task.id, in: &state, by: .you)
            }
        }
        guard workspace.flush() else {
            restore(before)
            throw ActionUnavailable("The end couldn’t be saved, so the operation was left as it was.")
        }
        for challenge in run.challenges { tools.runningChallenges[challenge.id]?.cancel() }
        waker.forget(id)
        // Its working tasks no longer hold a slot: another operation's queued task may take it now.
        startReadyTasks()
        guard let daemon = daemon() else { return }
        await Log.daemon.attempt("Revoking the token of the ended operation \(id.uuidString)") { try await daemon.revokeOperator(runId: id.uuidString) }
        await closeOperatorWindowIfOnlyItsOperator(id, daemon: daemon)
    }

    /// The first connected snapshot after the helper attaches (spec §9): an ended operation whose operator
    /// tab is listed — one an end could not close, as no helper was there — has its window closed, once the
    /// snapshot shows it holds nothing else. No tab listed, nothing is closed: a recorded window id proves
    /// nothing about what a window holds now (iTerm2 restores windows under saved ids, and you may have
    /// added tabs of your own). The recorded ids are cleared once each run is handled.
    func closeEndedOperatorWindows() {
        guard let daemon = daemon() else { return }
        let ended = runs.filter { $0.intent == .stopped }.map(\.id)
        guard !ended.isEmpty else { return }
        closingEnded = Task {
            for id in ended {
                await closeOperatorWindowIfOnlyItsOperator(id, daemon: daemon)
                mutateRun(id) { $0.operatorWindowId = nil; $0.operatorSessionId = nil }
            }
        }
    }

    /// Closes the window of the run's operator tab as the listed tabs show it, and only when every tab in
    /// it is the run's own: the daemon's close takes the whole window, force and all, and there is no
    /// closing of one tab. A window that holds other tabs is left, and said in the log; with the tabs not
    /// known, or none listed for the run, nothing is closed. Never a recorded window id.
    private func closeOperatorWindowIfOnlyItsOperator(_ id: UUID, daemon: any DaemonCommands) async {
        guard tabsKnown, let tab = operatorTab(of: id) else { return }
        guard live.sessions.allSatisfy({ $0.windowId != tab.windowId || $0.taskUUID == id }) else {
            Log.daemon.info("The window of the ended operation \(id.uuidString, privacy: .public) holds other tabs too, so it is left open")
            return
        }
        await Log.daemon.attempt("Closing the window of the ended operation \(id.uuidString)") { try await daemon.closeWindowIfOpen(tab.windowId) }
    }

    /// Interrupt workers (spec §9): Esc to each worker at work, on your click — never the operator's to do.
    /// A task you took over is yours to drive and is left alone. Every one is tried; the first failure is thrown after.
    func interruptWorkers(run id: UUID) async throws {
        guard let daemon = daemon() else { throw ActionUnavailable(OperationIssue.disconnected("again").title) }
        let working = Set(workspace.state.tasks(inRun: id).filter { $0.operated?.state == .working && $0.operated?.takenOver == false }.map(\.id))
        var failure: (any Error)?
        for tab in live.sessions where tab.taskUUID.map(working.contains) == true && tab.state == .working && tab.agent.agentKind != nil {
            do { try await daemon.interrupt(sessionId: tab.sessionId) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    func rename(run id: UUID, to name: String) throws {
        guard run(id: id) != nil else { throw ActionUnavailable("This operation is no longer in AiTerm.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ActionUnavailable("Give the operation a name.") }
        mutateRun(id) { $0.name = name }
    }

    /// The operation's chat (spec §10.3): its operator's window brought forward, reopened first when it
    /// was closed — which resumes an operation that went offline. An ended operation's window is brought
    /// forward if it is still there, and never reopened.
    func focusOperatorWindow(run id: UUID) async {
        guard let run = self.run(id: id), let daemon = daemon() else { return }
        let ended = run.state == .stopped || run.intent == .stopped
        if operatorTab(of: id) == nil, !ended {
            do {
                if run.state == .operatorOffline { try await resume(run: id) }
                else { _ = try await reopenOperatorWindow(id) }
            } catch {
                notices.report(OperationIssue(title: "Couldn’t reopen \(run.persona.name)’s window.", error: error))
                return
            }
        }
        guard let window = operatorTab(of: id)?.windowId ?? self.run(id: id)?.operatorWindowId else { return }
        try? await daemon.activate(windowId: window)
    }

    /// The operator's window opened again, in front: its conversation resumed under the same frozen
    /// profile, or — with no conversation to resume — a fresh operator, its first message the brief again
    /// (`OperatorCommand.prepare` writes and reads `first-message.md` only for a fresh start). The run
    /// folder is written afresh with its token kept. Nothing when its window is open, is being opened, or
    /// was opened a moment ago and iTerm2 has not listed its tab yet; refused while iTerm2's tabs are not
    /// known, as a tab not listed then is not a tab closed. An operation ended meanwhile (an await passed)
    /// is left ended: the token registered is revoked and the window opened is closed. Says whether it
    /// opened one, or left it to a reopening already under way (or within its wait): a caller that goes on
    /// to change the operation waits for that one instead.
    @discardableResult
    func reopenOperatorWindow(_ id: UUID) async throws -> OperatorReopening {
        guard let run = self.run(id: id) else { throw ActionUnavailable("This operation is no longer in AiTerm.") }
        guard !hasEnded(id) else { throw ActionUnavailable("This operation has ended.") }
        guard operatorTab(of: id) == nil else { return .open }
        guard !reopeningOperator.contains(id) else { return .underway }
        guard let daemon = daemon(), tabsKnown else { throw ActionUnavailable(OperationIssue.disconnected("again").title) }
        if let at = reopenedOperator[id], ports.now().timeIntervalSince(at) < OperatorTiming.launchAdoptAfter { return .underway }
        reopeningOperator.insert(id)
        defer { reopeningOperator.remove(id) }
        let projects = run.projectIds.compactMap(workspace.state.project(id:)), home = ports.home, folder = self.folder(of: id)
        let milestone = ports.milestone
        let prepared = try await BackgroundWork.run {
            let token = OperatorCommand.existingToken(in: folder) ?? OperatorCommand.makeToken()
            return try OperatorCommand.prepare(run: run, projects: projects, home: home, token: token,
                                               resuming: run.operatorConversation, milestone: milestone)
        }
        // Ended while the folder was written: prepare made its token file again, and nothing was registered.
        guard !hasEnded(id) else {
            let file = folder.appendingPathComponent(OperatorCommand.tokenFile)
            await Log.workspace.attempt("Removing the token file of an operation ended while its operator reopened") {
                try await BackgroundWork.run { try FileManager.default.removeItem(at: file) }
            }
            return .ended
        }
        try await daemon.registerOperator(runId: id.uuidString, token: prepared.token)
        // Ended while the token was registered: no window is opened for it, and the token goes again.
        guard !hasEnded(id) else {
            await revokeAfterEnd(id, window: nil, daemon: daemon)
            return .ended
        }
        let window: String
        do {
            window = try await daemon.createTaskWindow(taskId: id.uuidString, cwd: prepared.folder.path, title: run.name,
                                                       agentCommand: prepared.command, frame: taskFrame(), background: false)
        } catch {
            if hasEnded(id) { await revokeAfterEnd(id, window: nil, daemon: daemon) }
            throw error
        }
        guard !hasEnded(id) else {
            await revokeAfterEnd(id, window: window, daemon: daemon)
            return .ended
        }
        reopenedOperator[id] = ports.now()
        mutateRun(id) { $0.operatorWindowId = window }
        return .opened
    }

    private func hasEnded(_ id: UUID) -> Bool {
        guard let run = run(id: id) else { return true }
        return run.state == .stopped || run.intent == .stopped
    }

    /// What an end that came while the operator reopened could not undo itself: the token registered
    /// after its revoke goes again, and the window opened after its close is closed.
    private func revokeAfterEnd(_ id: UUID, window: String?, daemon: any DaemonCommands) async {
        await Log.daemon.attempt("Revoking the token of operation \(id.uuidString) ended while its operator reopened") {
            try await daemon.revokeOperator(runId: id.uuidString)
        }
        if let window {
            await Log.daemon.attempt("Closing the window of operation \(id.uuidString) ended while its operator reopened") {
                try await daemon.closeWindowIfOpen(window)
            }
        }
    }

    // -- taking a change back ---------------------------------------------------------------------
    /// A run and its tasks' operated state as they stand, for a change that is taken back when it cannot be saved.
    private struct Snapshot {
        let run: OperatorRun, tasks: [UUID: OperatedTask]
    }

    private func snapshot(of id: UUID) -> Snapshot? {
        guard let run = self.run(id: id) else { return nil }
        return Snapshot(run: run, tasks: Dictionary(workspace.state.tasks(inRun: id).compactMap { task in
            task.operated.map { (task.id, $0) }
        }, uniquingKeysWith: { first, _ in first }))
    }

    /// Puts `before` back. Nothing awaits between a change and its save, so nothing else has moved since.
    private func restore(_ before: Snapshot?) {
        guard let before else { return }
        workspace.mutate { state in
            if let i = state.runs.firstIndex(where: { $0.id == before.run.id }) { state.runs[i] = before.run }
            for (id, operated) in before.tasks {
                if let i = state.tasks.firstIndex(where: { $0.id == id }) { state.tasks[i].operated = operated }
            }
        }
    }
}

/// What `reopenOperatorWindow` did: opened the operator's window, found it open already, left the
/// opening to one already under way (or opened a moment ago and not yet listed), or found the operation
/// ended and opened nothing.
enum OperatorReopening: Equatable {
    case opened, open, underway, ended
}
