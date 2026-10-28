import Foundation
import AiTermCore

/// What you do to a broadcast and its tasks (spec §8, §9, §13). Every change is persisted, so a pause or an
/// end survives a restart, and reconciliation never undoes one.
extension OperatorController {
    // -- a task -----------------------------------------------------------------------------------
    /// Take over (spec §8): the task's ownership generation moves on — a send in flight ends partial,
    /// queued ones are dropped — and the operator's tools refuse it until you hand it back. The operator
    /// hears of it. Taken over already, it only sets the
    /// generation on the tabs again, which is what a retry after a failure is.
    func takeOver(task id: UUID) async throws {
        guard let operated = workspace.state.task(id: id)?.operated else { throw ActionUnavailable("That task isn’t the Operator’s.") }
        guard !operated.takenOver else { return try await setOwnership(operated.ownership, on: id) }
        let ownership = operated.ownership + 1
        workspace.mutate { $0.updateOperated(id) { $0.takenOver = true; $0.ownership = ownership } }
        // A merge waiting is disarmed until the operator's next finish_task, whatever is handed back or resumed.
        finisher.disarm(id, because: TaskFinisher.takenOverProblem)
        // An agent review of its branch stops: what it would find is about a branch that is yours now.
        if tools.runningReviews[id] != nil {
            tools.cancelReviews(of: [id])
            let at = ports.now()
            workspace.mutate { $0.updateOperated(id) {
                $0.agentReview?.failure = "Stopped when the person took over \(operated.key): call review_task again once it is handed back."
                $0.agentReview?.at = at
            } }
        }
        waker.say("the person took over one task", to: operated.runId)
        try await setOwnership(ownership, on: id)
    }

    /// Hand back: the operator may act on it again, and is told. The generation stays what the takeover
    /// set: the helper never lowers one, and the operator's next send carries this one. A queued task
    /// that was held back by the takeover may start now.
    func handBack(task id: UUID) async throws {
        guard let operated = workspace.state.task(id: id)?.operated, operated.takenOver else { return }
        workspace.mutate { $0.updateOperated(id) { $0.takenOver = false } }
        waker.say("one task is handed back", to: operated.runId)
        runChanged(operated.runId)
        try await setOwnership(operated.ownership, on: id)
    }

    /// Stop Task…, in the row's menu (E6, confirmed first): the task ends `stopped`, its dependents
    /// blocked; its workers, in every tab, run on, and none is steered or opened again (`TabOpener.holds`). A question about it has nothing left to ask, so it is
    /// resolved — an open one would keep the broadcast from completing. The broadcast is then settled the
    /// way every other end settles it: the last open task stopped completes it.
    func stop(task id: UUID) throws {
        guard let runId = workspace.state.task(id: id)?.operated?.runId else { throw ActionUnavailable("That task isn’t the Operator’s.") }
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
        // Stopping an accepted task also stops its publication watch.
        finisher.stopWatching(id)
        runChanged(runId)
    }

    /// An end picked on a task's card (broadcast setup v2, Board): set as `TaskEndChange` decides, saved, and the
    /// Operator woken with it, whose next `finish_task` follows it. A merge's watch stops with the wait it cleared, and no
    /// change starts one: a change to Merge is held as a takeover holds one (`TaskEndChange.mergeWaitsForFinish`), so only
    /// the Operator's next `finish_task` merges; a change away from Merge has no merge to hold, a takeover's hold going
    /// with the rest of what was under way for it. A
    /// switch below what is done finishes the task, so the broadcast is settled as every other end settles it; when that
    /// completes it, the one wake line says both, as the waker holds one reason. Refused as `TaskEndChange.refusal` says,
    /// and while AiTerm is carrying out the task's end.
    func changeEnd(of id: UUID, to end: TaskEnd) throws {
        guard let task = workspace.state.task(id: id), let operated = task.operated, let run = run(id: operated.runId) else {
            throw ActionUnavailable("That task isn’t the Operator’s.")
        }
        if let refusal = TaskEndChange.refusal(end, for: task, in: run) { throw ActionUnavailable(refusal) }
        guard !finisher.running.contains(id) else { throw ActionUnavailable("AiTerm is finishing \(task.title). Change its end once it’s done.") }
        workspace.mutate { TaskEndChange.apply(end, toTask: id, in: &$0) }
        finisher.stopWatching(id)
        if end == .merge { finisher.disarm(id, because: TaskEndChange.mergeWaitsForFinish) }
        runChanged(run.id)
        let completed = run.state != .complete && self.run(id: run.id)?.state == .complete
        waker.say(TaskEndChange.wakeReason(key: operated.key, end: end) + (completed ? ", and the broadcast is complete" : ""), to: run.id)
    }

    /// One More Round or Accept As It Is, on the card of a task out of its review's fix rounds: the Operator woken with
    /// your answer, once per question. The question stays open: the Operator resolves it, as with an answer in its chat.
    /// Refused for a task you took over or that has finished.
    func answerFixRounds(of id: UUID, _ answer: BroadcastBoard.FixRoundsAnswer) throws {
        guard let operated = workspace.state.task(id: id)?.operated, !operated.takenOver, !operated.isFinished,
              let run = run(id: operated.runId), !run.hasEnded,
              let question = run.fixRoundsQuestion(on: id)
        else { throw ActionUnavailable("Nothing asks about that task’s fix rounds any more.") }
        // A second click before the Operator resolved it: already said.
        let asked = "\(run.id.uuidString)/\(question.id)/\(question.askedAt.timeIntervalSince1970)"
        guard Self.fixRoundsAnswered.insert(asked).inserted else { return }
        waker.say(answer.wakeReason(key: operated.key), to: run.id)
    }

    /// The fix-rounds questions answered from a card, each keyed by its question (its run, its id and when it was asked, as
    /// the Operator may ask again under the same id), so each wakes the Operator once.
    private static var fixRoundsAnswered: Set<String> = []

    /// A worker window you closed, back on your click or ↩ on its row (integration decision 7): its
    /// conversation resumed in a window behind your work under the broadcast's flags (`WorkerStarter.reopen`),
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
        else if task.firstWorkerConversation == nil { reason = "Its worker left no conversation to resume." }
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

    /// The task's generation on each of its tabs, its first worker's and every extra tab's (`open_tab`), all tagged with
    /// the task, every one tried: the first failure is thrown after. With
    /// no helper nothing is lost — the change is saved, and `resendOwnership` sets it once one attaches.
    private func setOwnership(_ ownership: Int, on task: UUID) async throws {
        guard let daemon = daemon() else { return }
        var failure: (any Error)?
        for tab in live.sessions where tab.taskUUID == task {
            do { try await daemon.setOwnership(sessionId: tab.sessionId, ownership: ownership) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    // -- a broadcast -----------------------------------------------------------------------------
    /// Pause (spec §9): no task starts, no message is delivered, nothing is accepted; workers finish
    /// their turn. Persisted as your intent: a pause that cannot be saved is taken back, so the broadcast
    /// never reads as paused for what the file would not hold. A delivery already in flight is not
    /// cancelled — the daemon offers no way to — it ends as the daemon's rules end it.
    func pause(run id: UUID) throws {
        guard let run = self.run(id: id), [.planning, .active, .operatorOffline].contains(run.state) else {
            throw ActionUnavailable("Only a broadcast under way can be paused.")
        }
        try savedOrTakenBack("The pause couldn’t be saved, so the broadcast was left as it was.") { state in
            state.updateRun(id: id) { $0.intent = .paused; $0.state = .paused }
        }
        finisher.stopWatching(inRun: id)
    }

    /// Resume (spec §9), from paused or offline: an operator still there is kept and woken; one gone is
    /// reopened — its conversation resumed, or a fresh operator briefed from the run — before anything
    /// changes, so a reopening that fails leaves the broadcast as it was. Then whatever was held back starts.
    /// `background`: the window reopens behind what is in front, the board.
    func resume(run id: UUID, background: Bool = false) async throws {
        guard let run = self.run(id: id), run.state == .paused || run.state == .operatorOffline else { return }
        // A reopening already under way (a second click) is the first one's to finish: it sets the state and wakes.
        if operatorTab(of: id) == nil, try await reopenOperatorWindow(id, background: background) == .underway { return }
        // The reopening took a while: it may have been ended meanwhile.
        guard let current = self.run(id: id), !current.hasEnded else { return }
        if current.state == .paused || current.state == .operatorOffline {
            mutateRun(id) { $0.intent = nil; $0.state = RunReconciler.resumedState(of: $0) }
        }
        waker.say("resumed", to: id)
        runChanged(id)
    }

    /// End Broadcast (spec §9, §13), early or once complete: your stop, persisted first with when, for the
    /// Shelf — one that cannot be saved is taken back and nothing else is done. The tasks that never started are dropped, their rows
    /// gone with them: they have no worktree and no window. Those started and still open end `stopped` and
    /// are yours, as after a takeover: their ownership moves on, so nothing the Operator queued lands, and
    /// an agent mid-turn is never interrupted but finishes it. Its second opinions are cancelled, its
    /// Operator is no longer woken, its token is revoked and its window closed, each only logged when it
    /// fails (an attach does both again). Every task that started stays, its worktree and MR untouched, and
    /// the "+" returns.
    func end(run id: UUID) async throws {
        guard let run = self.run(id: id), run.state != .stopped else { return }
        let now = ports.now()
        let ending = try savedOrTakenBack("The end couldn’t be saved, so the broadcast was left as it was.") { state in
            Self.applyEnd(id, at: now, to: &state)
        }
        finisher.stopWatching(inRun: id)
        for challenge in run.challenges { tools.runningChallenges[challenge.id]?.cancel() }
        tools.cancelReviews(of: Set(workspace.state.tasks(inRun: id).map(\.id)))
        waker.forget(id)
        // No start pass follows: nothing waited on a slot the ended broadcast held, as there is no cap.
        guard let daemon = daemon() else { return }
        await Log.daemon.attempt("Revoking the token of the ended broadcast \(id.uuidString)") { try await daemon.revokeOperator(runId: id.uuidString) }
        for task in ending.handed {
            guard let ownership = workspace.state.task(id: task)?.operated?.ownership else { continue }
            await Log.daemon.attempt("Setting the ownership of task \(task.uuidString), yours since its broadcast ended") {
                try await setOwnership(ownership, on: task)
            }
        }
        await closeOperatorWindowIfOnlyItsOperator(id, daemon: daemon)
    }

    /// Remove on the Shelf: an ended broadcast forgotten — saved first, one that cannot be saved taken back and
    /// nothing else done — then its run folder deleted off the main actor, `activity.jsonl` and the brief with it, once the
    /// lines already on their way to it have landed, so none makes the folder again.
    /// Its tasks are not touched: those in the sidebar and those shelved stay where they are, each still naming
    /// the run. Refused for a broadcast that has not ended.
    func forget(run id: UUID) async throws {
        guard let run = self.run(id: id) else { return }
        guard run.hasEnded else { throw ActionUnavailable("Only an ended broadcast can be removed from the Shelf.") }
        try savedOrTakenBack("The removal couldn’t be saved, so the broadcast was left on the Shelf.") { state in
            state.runs.removeAll { $0.id == id }
            state.foldedRuns.remove(id)
        }
        let folder = self.folder(of: id)
        await tools.lastRecording?.value
        try await BackgroundWork.run {
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// End's change to the workspace, as `end(run:)` saves it: the run stopped at `now`, the tasks that never started
    /// dropped and those started and still open stopped and yours, their ownership moved on (`ending`). Returns
    /// what `ending` said of them.
    @discardableResult
    static func applyEnd(_ id: UUID, at now: Date, to state: inout AppState) -> (dropped: Set<UUID>, handed: [UUID]) {
        let ending = Self.ending(id, in: state)
        state.updateRun(id: id) { $0.intent = .stopped; $0.state = .stopped; $0.endedAt = now }
        state.tasks.removeAll { ending.dropped.contains($0.id) }
        for task in ending.handed {
            _ = try? OperatedTransitions.apply(.stop, toTask: task, in: &state, by: .you)
            state.updateOperated(task) { $0.takenOver = true; $0.ownership += 1 }
        }
        return ending
    }

    /// What End does to a broadcast's tasks (spec §9, §13): those that never started — no launch and no
    /// checkout — are dropped; those started and still open (working, blocked, failed, in review, waiting
    /// on you) are handed to you. A task that has ended stays as it is.
    static func ending(_ run: UUID, in state: AppState) -> (dropped: Set<UUID>, handed: [UUID]) {
        var dropped: Set<UUID> = [], handed: [UUID] = []
        for task in state.tasks(inRun: run) {
            guard let operated = task.operated else { continue }
            if !operated.started, !task.hasCheckout { dropped.insert(task.id) }
            else if operated.state.isOpen { handed.append(task.id) }
        }
        return (dropped, handed)
    }

    /// End Broadcast…'s question, with what it does to this broadcast's tasks as they stand (spec §13).
    func endPrompt(run: OperatorRun) -> AlertPrompt {
        let ending = Self.ending(run.id, in: workspace.state)
        return OperatorAlerts.endBroadcast(run, unstarted: ending.dropped.count, running: ending.handed.count)
    }

    /// The first connected snapshot after the helper attaches (spec §9): an ended broadcast whose operator
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
            Log.daemon.info("The window of the ended broadcast \(id.uuidString, privacy: .public) holds other tabs too, so it is left open")
            return
        }
        await Log.daemon.attempt("Closing the window of the ended broadcast \(id.uuidString)") { try await daemon.closeWindowIfOpen(tab.windowId) }
    }

    func rename(run id: UUID, to name: String) throws {
        guard run(id: id) != nil else { throw ActionUnavailable("This broadcast is no longer in AiTerm.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ActionUnavailable("Give the broadcast a name.") }
        mutateRun(id) { $0.name = name }
    }

    /// AiTerm's own git problem on a driven task (spec §6, §13): a checkout or a rebase that failed, shown in
    /// the banner as the issue `issueId`. The task keeps the issue as its `problem`, so its card sends you to
    /// the banner's Notice, and is blocked with the issue's sentence; one whose state cannot be blocked (an
    /// accepted task waiting on its end) keeps its state, its `problem` alone saying so. Refused for a task
    /// that is no operator's, and for an issue the banner does not show.
    func markProblem(task id: UUID, issueId: String) throws {
        guard let operated = workspace.state.task(id: id)?.operated else { throw ActionUnavailable("That task isn’t the Operator’s.") }
        guard let issue = notices.issue, issue.id == issueId else { throw ActionUnavailable("That problem is no longer shown.") }
        workspace.mutate { state in
            _ = try? OperatedTransitions.apply(.block(reason: issue.title), toTask: id, in: &state, by: .aiterm)
            state.updateOperated(id) { $0.problem = issueId }
        }
        runChanged(operated.runId)
    }

    /// The banner's issue changed (spec §6, §13): one it showed is no driven task's problem any more —
    /// dismissed, answered or replaced — and one it shows now about a driven task is that task's.
    /// AiTerm raises no git problem about a driven task yet but through the banner, so every issue
    /// that names one marks it; the Operator picks the task back up once you have dealt with it.
    func bannerChanged(from old: OperationIssue?, to new: OperationIssue?) {
        if let old, old.id != new?.id {
            let marked = workspace.state.tasks.filter { $0.operated?.problem == old.id }
            if !marked.isEmpty {
                workspace.mutate { state in for task in marked { state.updateOperated(task.id) { $0.problem = nil } } }
                for runId in Set(marked.compactMap { $0.operated?.runId }) { runChanged(runId) }
            }
        }
        if let new, let subject = new.subject, let operated = workspace.state.task(id: subject)?.operated,
           operated.problem != new.id {
            do { try markProblem(task: subject, issueId: new.id) }
            catch { Log.ui.notice("Couldn’t mark the problem on \(operated.key, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }

    // -- the Operator's window --------------------------------------------------------------------
    /// The Operator's row chosen with its window closed (spec §3, §9): the window reopens, in front, and a
    /// broadcast that went offline resumes; a pause of yours stays paused. An ended broadcast is never
    /// reopened. A conversation that can't be resumed is remembered (`reopenFailed`), so the board's footer
    /// offers Start Fresh (`startFresh`), and said in the banner. `background` opens it behind what is in
    /// front, and says only a failure other than that one in the banner: nothing in the sidebar asks for it
    /// since its row brings the window to front (21 Oct 2026).
    func reopenOperator(run id: UUID, background: Bool = false) async {
        guard let run = self.run(id: id), !hasEnded(id), operatorTab(of: id) == nil else { return }
        do {
            if run.state == .operatorOffline { try await resume(run: id, background: background) }
            else { _ = try await reopenOperatorWindow(id, background: background) }
        } catch {
            if (error as? ActionUnavailable)?.message == Self.cannotResume { reopenFailed.insert(id) }
            if !background || !reopenFailed.contains(id) {
                notices.report(OperationIssue(title: "Couldn’t reopen the Operator’s window.", error: error))
            }
        }
    }

    /// Start Fresh (spec §13), when the Operator's conversation cannot be resumed: it is let go, and a new
    /// Operator session opens in front, its first message the broadcast, where it stands as `run_status`
    /// shows it, and the decisions so far (`OperatorCommand.freshStartMessage`). A broadcast that went
    /// offline resumes, as a click on its row resumes it. Refused once ended, and while the Operator's
    /// window is open: close it first.
    func startFresh(run id: UUID) async throws {
        guard let run = self.run(id: id), !hasEnded(id) else { throw ActionUnavailable("This broadcast has ended.") }
        guard operatorTab(of: id) == nil else { throw ActionUnavailable("The Operator’s window is still open. Close it first.") }
        if run.operatorConversation != nil { mutateRun(id) { $0.operatorConversation = nil } }
        reopenFailed.remove(id)
        if run.state == .operatorOffline { try await resume(run: id) }
        else { _ = try await reopenOperatorWindow(id) }
    }

    /// Why a reopening opened nothing: the conversation it would continue is not on this Mac any more.
    static let cannotResume = "Its conversation can’t be resumed."

    /// The operator's window opened again, in front: its conversation resumed under the same frozen
    /// profile, or — with no conversation to resume — a fresh operator, briefed with the broadcast and
    /// where it stands (`OperatorCommand.freshStartMessage`; `prepare` writes `first-message.md` only for a
    /// fresh start). A conversation whose file is gone from Claude's folder is refused (`cannotResume`): Start
    /// Fresh lets it go. The run folder is written afresh with its token kept. Nothing when its window is
    /// open, is being opened, or was opened a moment ago and iTerm2 has not listed its tab yet; refused
    /// while iTerm2's tabs are not known, as a tab not listed then is not a tab closed. A broadcast ended
    /// meanwhile (an await passed) is left ended: the token registered is revoked and the window opened is
    /// closed. Says whether it opened one, or left it to a reopening already under way (or within its
    /// wait): a caller that goes on to change the broadcast waits for that one instead. `background`
    /// opens it behind what is in front.
    @discardableResult
    func reopenOperatorWindow(_ id: UUID, background: Bool = false) async throws -> OperatorReopening {
        guard let run = self.run(id: id) else { throw ActionUnavailable("This broadcast is no longer in AiTerm.") }
        guard !hasEnded(id) else { throw ActionUnavailable("This broadcast has ended.") }
        guard operatorTab(of: id) == nil else { return .done }
        guard !reopeningOperator.contains(id) else { return .underway }
        guard let daemon = daemon(), tabsKnown else { throw ActionUnavailable(OperationIssue.disconnected("again").title) }
        if let at = reopenedOperator[id], ports.now().timeIntervalSince(at) < OperatorTiming.launchAdoptAfter { return .underway }
        reopeningOperator.insert(id)
        defer { reopeningOperator.remove(id) }
        let projects = run.projectIds.compactMap(workspace.state.project(id:)), home = ports.home, folder = self.folder(of: id)
        let transcripts = self.transcripts
        let conversation = run.operatorConversation, cannotResume = Self.cannotResume
        // A fresh Operator is told where the broadcast stands; a resumed one remembers.
        let fresh = conversation == nil
            ? OperatorCommand.freshStartMessage(for: run, status: status(of: run).flatMap { try? String(decoding: $0.json(), as: UTF8.self) } ?? "{}")
            : nil
        let prepared = try await BackgroundWork.run {
            if let conversation, transcripts.file(agent: .claude, conversation: conversation) == nil {
                throw ActionUnavailable(cannotResume)
            }
            let token = OperatorCommand.existingToken(in: folder) ?? OperatorCommand.makeToken()
            return try OperatorCommand.prepare(run: run, projects: projects, home: home, token: token,
                                               resuming: conversation, firstMessage: fresh)
        }
        // Ended while the folder was written: prepare made its token file again, and nothing was registered.
        guard !hasEnded(id) else {
            let file = folder.appendingPathComponent(OperatorCommand.tokenFile)
            await Log.workspace.attempt("Removing the token file of a broadcast ended while its operator reopened") {
                try await BackgroundWork.run { try FileManager.default.removeItem(at: file) }
            }
            return .done
        }
        try await daemon.registerOperator(runId: id.uuidString, token: prepared.token)
        // Ended while the token was registered: no window is opened for it, and the token goes again.
        guard !hasEnded(id) else {
            await revokeAfterEnd(id, window: nil, daemon: daemon)
            return .done
        }
        let window: String
        do {
            window = try await daemon.createTaskWindow(taskId: id.uuidString, cwd: prepared.folder.path, title: run.name,
                                                       agentCommand: prepared.command, frame: taskFrame(), background: background)
        } catch {
            if hasEnded(id) { await revokeAfterEnd(id, window: nil, daemon: daemon) }
            throw error
        }
        guard !hasEnded(id) else {
            await revokeAfterEnd(id, window: window, daemon: daemon)
            return .done
        }
        reopenedOperator[id] = ports.now()
        reopenFailed.remove(id)
        mutateRun(id) { $0.operatorWindowId = window }
        return .done
    }

    func hasEnded(_ id: UUID) -> Bool { run(id: id)?.hasEnded ?? true }

    /// What an end that came while the operator opened or reopened could not undo itself: the token
    /// registered after its revoke goes again, and the window opened after its close is closed.
    func revokeAfterEnd(_ id: UUID, window: String?, daemon: any DaemonCommands) async {
        await Log.daemon.attempt("Revoking the token of broadcast \(id.uuidString) ended while its operator opened") {
            try await daemon.revokeOperator(runId: id.uuidString)
        }
        if let window {
            await Log.daemon.attempt("Closing the window of broadcast \(id.uuidString) ended while its operator opened") {
                try await daemon.closeWindowIfOpen(window)
            }
        }
    }

    // -- taking a change back ---------------------------------------------------------------------
    /// `change`, saved, or taken back when it cannot be saved: the runs, the tasks and the folded broadcasts put back
    /// as they stood, and `refusal` thrown. Nothing awaits between the change and its save, so nothing else has moved since.
    @discardableResult
    private func savedOrTakenBack<Value>(_ refusal: String, _ change: (inout AppState) -> Value) throws -> Value {
        let before = (runs: workspace.state.runs, tasks: workspace.state.tasks, folded: workspace.state.foldedRuns)
        let value = workspace.mutate(change)
        guard workspace.flush() else {
            workspace.mutate { state in
                state.runs = before.runs
                state.tasks = before.tasks
                state.foldedRuns = before.folded
            }
            throw ActionUnavailable(refusal)
        }
        return value
    }
}

/// What `reopenOperatorWindow` did: left the opening to one already under way (or opened a moment ago and not
/// yet listed), or anything else: opened the operator's window, found it open already, or found the broadcast
/// ended and opened nothing.
enum OperatorReopening: Equatable {
    case underway, done
}
