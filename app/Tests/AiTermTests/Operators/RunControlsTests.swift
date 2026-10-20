import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// What you do to an operation and its tasks (spec §8, §9): every one persisted, none the operator's to undo.
@MainActor @Suite struct RunControlsTests {
    let project = OperatorServiceFixtures.project()

    func makeWorld(runState: OperatorRunState = .active, taskState: OperatedState = .working, daemon: RecordingDaemon = RecordingDaemon(),
                   tab: Bool = true, adjust: (inout OperatorPorts) -> Void = { _ in }) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let run = OperatorServiceFixtures.run(projects: [project], state: runState, planRevision: 1)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: taskState, worktree: "/tmp/aiterm-wt")
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon, adjust: adjust)
        world.show(tab ? [OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: .done)]
                       : [OperatorServiceFixtures.session("op", tag: run.id)])
        return (world, run, task)
    }

    /// Saving fails from now on: the file holds the workspace as of this call, and its backup's place is a folder.
    func breakSaving(_ world: OperatorWorld) throws {
        #expect(world.workspace.flush())
        try FileManager.default.createDirectory(at: world.workspace.file.backupURL, withIntermediateDirectories: false)
    }

    // -- one broadcast, and its end (spec §3, §9, §13) -------------------------------------------------
    @Test func aSecondBroadcastIsRefused() async throws {
        let (world, run, _) = try makeWorld()
        #expect(world.controller.activeRun?.id == run.id)
        let refusal = await #expect(throws: ActionUnavailable.self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [project.id], prompt: "Go", review: nil, done: nil)
        }
        #expect(refusal?.message == "A broadcast is already running.")
        #expect(world.state.runs.map(\.id) == [run.id])
        #expect(world.daemon.requests("operator.register").isEmpty && world.daemon.requests("window.createTask").isEmpty)
        // Ended, the "+" returns: the next one starts.
        try await world.controller.end(run: run.id)
        #expect(world.controller.activeRun == nil)
        let next = try await world.controller.startBroadcast(name: "Sprint 43", jiraProjectKeys: ["PLUTO"], projectIds: [project.id],
                                                             prompt: "Go", review: nil, done: nil)
        #expect(world.controller.activeRun?.id == next)
        #expect(world.run(next)?.name == "Sprint 43" && world.run(next)?.jiraProjectKeys == ["PLUTO"])
    }

    @Test func endingDropsUnstartedTasksAndHandsRunningOnesToYou() async throws {
        let (world, run, working) = try makeWorld()
        var blocked = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-2", state: .blocked, worktree: "/tmp/aiterm-wt2")
        blocked.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 1))
        let queued = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-3", state: .queued)
        let planned = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-4", state: .planned)
        var accepted = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-5", state: .accepted, worktree: "/tmp/aiterm-wt5")
        accepted.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 1))
        world.workspace.mutate { $0.tasks += [blocked, queued, planned, accepted] }
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: working.id, state: .working)])
        try await world.controller.end(run: run.id)
        #expect(world.run(run.id)?.state == .stopped && world.run(run.id)?.intent == .stopped)
        #expect(world.task(queued.id) == nil && world.task(planned.id) == nil, "never started: no worktree, no window, dropped")
        #expect(try world.workspace.file.load().tasks.map(\.id).sorted { $0.uuidString < $1.uuidString }
                == [working.id, blocked.id, accepted.id].sorted { $0.uuidString < $1.uuidString })
        for id in [working.id, blocked.id] {
            let operated = try #require(world.task(id)?.operated)
            #expect(operated.state == .stopped && operated.takenOver, "running: it finishes its turn and is yours")
            #expect(operated.ownership == 1, "as after a takeover, nothing the Operator queued lands")
        }
        #expect(world.task(accepted.id)?.operated?.state == .accepted && world.task(accepted.id)?.operated?.takenOver == false)
        #expect(world.daemon.requests("operator.revoke").map { $0.params["runId"] as? String } == [run.id.uuidString])
        #expect(world.daemon.requests("session.setOwnership").map { $0.params["sessionId"] as? String } == ["w1"])
    }

    @Test func endPromptCopy() throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let both = OperatorAlerts.endBroadcast(run, unstarted: 3, running: 2)
        #expect(both.message == "End “Sprint 42”?")
        #expect(both.detail == "3 tasks that haven’t started will be dropped. 2 running tasks finish their turn and become yours. Worktrees and MRs stay.")
        #expect(both.buttons == ["End Broadcast", "Cancel"] && both.escapeButton == 1 && !both.defaultDeletes, "a blue default: nothing is deleted")
        #expect(OperatorAlerts.endBroadcast(run, unstarted: 0, running: 1).detail == "1 running task finishes its turn and becomes yours. Worktrees and MRs stay.")
        #expect(OperatorAlerts.endBroadcast(run, unstarted: 1, running: 0).detail == "1 task that hasn’t started will be dropped. Worktrees and MRs stay.")
        #expect(OperatorAlerts.endBroadcast(run, unstarted: 0, running: 0).detail == "Worktrees and MRs stay.")
        for prompt in [both, OperatorAlerts.endBroadcast(run, unstarted: 1, running: 1)] {
            #expect(!prompt.detail.contains("—") && !prompt.message.contains("—"))
        }
        // Counted from the broadcast: the working task is running, a queued one has not started, an accepted one is neither.
        let (world, live, _) = try makeWorld()
        world.workspace.mutate { state in
            state.tasks.append(OperatorServiceFixtures.task(in: live, project: project, key: "PLUTO-2", state: .queued))
            state.tasks.append(OperatorServiceFixtures.task(in: live, project: project, key: "PLUTO-3", state: .accepted, worktree: "/tmp/aiterm-wt3"))
        }
        let counted = try #require(world.run(live.id))
        #expect(world.controller.endPrompt(run: counted) == OperatorAlerts.endBroadcast(counted, unstarted: 1, running: 1))
    }

    /// Spec §9, §13: the window closing ends nothing. A complete broadcast keeps its debrief until End, and a
    /// click brings its Operator back to it.
    @Test func closingTheWindowOfACompleteRunKeepsTheDebrief() async throws {
        let (world, run, task) = try makeWorld(runState: .complete, taskState: .accepted)
        world.show([])
        #expect(world.run(run.id)?.state == .complete && world.run(run.id)?.intent == nil)
        #expect(world.run(run.id)?.operatorWindowId == nil, "its window is gone")
        #expect(world.controller.activeRun?.id == run.id, "not ended: the debrief stays until End")
        #expect(world.task(task.id)?.operated?.state == .accepted)
        #expect(world.daemon.requests("operator.revoke").isEmpty)
        #expect(try world.workspace.file.load().run(id: run.id)?.intent == nil)
        await world.controller.reopenOperator(run: run.id)
        #expect(world.daemon.requests("window.createTask").count == 1)
        #expect(world.run(run.id)?.state == .complete, "still its debrief, not planning again")
    }

    /// A broadcast whose last open task ends while its Operator is offline completes on resume, as every end
    /// completes one: its Operator is told and you are notified.
    @Test func aRunThatCompletesWhileOfflineSettlesWhenItResumes() async throws {
        let (world, run, task) = try makeWorld()
        world.show([])
        #expect(world.run(run.id)?.state == .operatorOffline)
        try world.controller.stop(task: task.id)
        #expect(world.run(run.id)?.state == .operatorOffline, "offline, nothing settles")
        try await world.controller.resume(run: run.id)
        #expect(world.run(run.id)?.state == .complete)
        #expect(world.notifications.posted.contains { $0.id == "debrief-\(run.id.uuidString)" && $0.target == .overview(run.id) })
        world.show([OperatorServiceFixtures.session("op2", tag: run.id)])
        try await world.daemon.received("session.deliver")
        let lines = world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }
        #expect(lines.contains { $0.contains("broadcast complete") || $0.contains("updates") }, "its Operator is told: \(lines)")
    }

    /// AiTerm's own git problem on a driven task (a checkout or a rebase that failed, in the banner): the task
    /// names the issue as its problem and is blocked with the issue's sentence.
    @Test func anAiTermProblemBlocksItsTaskWithTheIssuesSentence() throws {
        let (world, _, task) = try makeWorld()
        world.controller.notices.report(OperationIssue(title: "The rebase conflicted.", subject: task.id))
        let issue = try #require(world.controller.notices.issue)
        #expect(throws: ActionUnavailable.self) { try world.controller.markProblem(task: task.id, issueId: "another") }
        try world.controller.markProblem(task: task.id, issueId: issue.id)
        let operated = try #require(world.task(task.id)?.operated)
        #expect(operated.state == .blocked && operated.blockedReason == "The rebase conflicted." && operated.problem == issue.id)
    }

    /// The banner raising a problem about a driven task marks it there and then; dismissed, or answered,
    /// the task's `problem` goes with the banner. An issue about no driven task marks nothing.
    @Test func theBannersIssueAboutADrivenTaskIsItsProblemUntilItGoes() throws {
        let (world, _, task) = try makeWorld()
        world.controller.notices.report(OperationIssue(title: "Couldn’t remove the task.", reason: "git refused.", subject: task.id))
        let issue = try #require(world.controller.notices.issue)
        #expect(world.task(task.id)?.operated?.problem == issue.id)
        #expect(world.task(task.id)?.operated?.state == .blocked)
        world.controller.notices.dismissIssue()
        #expect(world.task(task.id)?.operated?.problem == nil)

        world.controller.notices.report(OperationIssue(title: "Couldn’t remove the task.", subject: task.id))
        #expect(world.task(task.id)?.operated?.problem != nil)
        world.controller.notices.dropIssues(about: task.id)
        #expect(world.task(task.id)?.operated?.problem == nil, "answered, it goes too")

        world.controller.notices.report(OperationIssue(title: "Couldn’t pull the default branch."))
        #expect(world.task(task.id)?.operated?.problem == nil, "an issue about no task names none")
    }

    @Test func takingOverMovesTheOwnershipOnAndRefusesTheOperatorUntilItIsHandedBack() async throws {
        let (world, run, task) = try makeWorld()
        try await world.controller.takeOver(task: task.id)
        #expect(world.task(task.id)?.operated?.takenOver == true && world.task(task.id)?.operated?.ownership == 1)
        #expect(world.daemon.requests("session.setOwnership").map { $0.params["ownership"] as? Int } == [1])
        #expect(await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "x"]).message?.hasPrefix("The person took over") == true)
        try await world.controller.handBack(task: task.id)
        #expect(world.task(task.id)?.operated?.takenOver == false && world.task(task.id)?.operated?.ownership == 1)
        #expect(await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "x"]).value?["result"] == "delivered")
    }

    /// Ownership never goes down on the helper (it keeps the larger), so a hand back leaves the generation the
    /// takeover set — the operator's next send carries it — and the next takeover moves on from there.
    @Test func eachTakeoverMovesTheGenerationOnAndAHandBackLeavesIt() async throws {
        let (world, _, task) = try makeWorld()
        try await world.controller.takeOver(task: task.id)
        try await world.controller.takeOver(task: task.id)
        #expect(world.task(task.id)?.operated?.ownership == 1, "a repeat only sets it again")
        try await world.controller.handBack(task: task.id)
        try await world.controller.handBack(task: task.id)
        try await world.controller.takeOver(task: task.id)
        #expect(world.task(task.id)?.operated?.ownership == 2)
        #expect(world.daemon.requests("session.setOwnership").map { $0.params["ownership"] as? Int } == [1, 1, 1, 2])
    }

    @Test func aTakeoverHoldsWhenTheHelperIsGoneAndTheNextAttachSetsItAgain() async throws {
        let (world, _, task) = try makeWorld()
        world.link.attached = false
        try await world.controller.takeOver(task: task.id)
        #expect(world.task(task.id)?.operated?.takenOver == true && world.task(task.id)?.operated?.ownership == 1)
        #expect(world.daemon.requests("session.setOwnership").isEmpty)
        world.link.attached = true
        world.controller.resendOwnership()
        try await world.daemon.received("session.setOwnership")
        #expect(world.daemon.requests("session.setOwnership").last?.params["ownership"] as? Int == 1)
    }

    @Test func aFailedOwnershipOnOneTabStillTriesTheOthersAndIsSaid() async throws {
        let daemon = RecordingDaemon(failing: ["session.setOwnership": .internal])
        let (world, run, task) = try makeWorld(daemon: daemon)
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id),
                    OperatorServiceFixtures.session("w2", window: "w9", tag: task.id)])
        await #expect(throws: DaemonError.self) { try await world.controller.takeOver(task: task.id) }
        #expect(daemon.requests("session.setOwnership").map { $0.params["sessionId"] as? String } == ["w1", "w2"])
        #expect(world.task(task.id)?.operated?.takenOver == true, "the takeover stands: the operator's tools refuse the task")
    }

    /// A taken-over task counts against the cap but a queued one is not startable; handed back, it is.
    @Test func handingBackAQueuedTaskLetsTheSchedulerStartIt() async throws {
        let (world, _, task) = try makeWorld(taskState: .queued, tab: false)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = true; $0.ownership = 1 } }
        world.controller.runChanged(task.operated!.runId)
        #expect(world.task(task.id)?.operated?.launch == nil, "taken over: not startable")
        try await world.controller.handBack(task: task.id)
        #expect(world.task(task.id)?.operated?.launch?.number == 1, "claimed by the start pass at once")
        await world.controller.lastStart?.value
    }

    @Test func aPauseHoldsWorkAndSurvivesAndResumingAnOperatorStillThereWakesIt() async throws {
        let (world, run, _) = try makeWorld()
        try world.controller.pause(run: run.id)
        #expect(world.run(run.id)?.state == .paused && world.run(run.id)?.intent == .paused)
        #expect(try world.workspace.file.load().runs.first?.intent == .paused)
        try await world.controller.resume(run: run.id)
        #expect(world.run(run.id)?.state == .active && world.run(run.id)?.intent == nil)
        #expect(world.daemon.requests("window.createTask").isEmpty)
        try await world.daemon.received("session.deliver")
        #expect(world.daemon.requests("session.deliver").last?.params["text"] as? String == "[AiTerm] resumed, call run_status")
    }

    @Test func aPauseThatCannotBeSavedIsTakenBackSoMemoryNeverClaimsWhatDiskDoesNot() throws {
        let (world, run, _) = try makeWorld()
        try breakSaving(world)
        #expect(throws: ActionUnavailable.self) { try world.controller.pause(run: run.id) }
        #expect(world.run(run.id)?.state == .active && world.run(run.id)?.intent == nil)
    }

    @Test func onlyAnOperationUnderWayCanBePaused() throws {
        let (world, run, _) = try makeWorld(runState: .complete)
        #expect(throws: ActionUnavailable.self) { try world.controller.pause(run: run.id) }
        #expect(world.run(run.id)?.state == .complete)
    }

    @Test func resumingAnOperatorThatIsGoneReopensItsConversationInFront() async throws {
        let (world, run, _) = try makeWorld(runState: .operatorOffline)
        world.controller.mutateRun(run.id) { $0.operatorConversation = "c-9" }
        try world.saveConversation("c-9")
        world.show([])
        try await world.controller.resume(run: run.id)
        let window = try #require(world.daemon.requests("window.createTask").first)
        #expect((window.params["agentCommand"] as? String)?.contains("c-9") == true)
        #expect(window.params["background"] == nil && window.params["taskId"] as? String == run.id.uuidString)
        #expect(window.params["cwd"] as? String == OperatorCommand.runFolder(run.id, home: world.ports.home).path)
        #expect(world.run(run.id)?.state == .active)
    }

    /// A resume that could not reopen the operator changes nothing: still paused, still your pause.
    @Test func aResumeThatCannotReopenTheOperatorLeavesTheOperationPaused() async throws {
        let (world, run, _) = try makeWorld(daemon: RecordingDaemon(failing: ["window.createTask": .internal]))
        try world.controller.pause(run: run.id)
        world.show([])
        await #expect(throws: DaemonError.self) { try await world.controller.resume(run: run.id) }
        #expect(world.run(run.id)?.state == .paused && world.run(run.id)?.intent == .paused)
    }

    /// C14: a fresh operator is briefed again by its first message; a resumed one is not, and keeps its token.
    @Test func reopeningKeepsTheRegisteredTokenAndBriefsOnlyAnOperatorWithNoConversation() async throws {
        let (world, run, _) = try makeWorld(runState: .operatorOffline)
        let folder = OperatorCommand.runFolder(run.id, home: world.ports.home)
        let token = OperatorCommand.makeToken()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(token.utf8).write(to: folder.appendingPathComponent(OperatorCommand.tokenFile))
        world.show([])
        try await world.controller.reopenOperatorWindow(run.id)
        let fresh = try #require(world.daemon.requests("window.createTask").first?.params["agentCommand"] as? String)
        #expect(fresh.contains(OperatorCommand.firstMessageFile), "no conversation: the brief is its first message")
        #expect(world.daemon.requests("operator.register").first?.params["token"] as? String == token)
        world.show([OperatorServiceFixtures.session("op2", tag: run.id)])
        world.show([])
        world.controller.mutateRun(run.id) { $0.operatorConversation = "c-3" }
        try world.saveConversation("c-3")
        try await world.controller.reopenOperatorWindow(run.id)
        let resumed = try #require(world.daemon.requests("window.createTask").last?.params["agentCommand"] as? String)
        #expect(resumed.contains("c-3") && !resumed.contains(OperatorCommand.firstMessageFile))
        #expect(world.daemon.requests("operator.register").last?.params["token"] as? String == token)
    }

    /// A double click on the row must not open two operators.
    @Test func reopeningTheOperatorWindowTwiceAtOnceOpensOne() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let (world, run, _) = try makeWorld(runState: .operatorOffline, daemon: daemon)
        world.show([])
        let first = Task { try await world.controller.reopenOperatorWindow(run.id) }
        try await daemon.received("window.createTask")
        try await world.controller.reopenOperatorWindow(run.id)
        daemon.release()
        _ = try await first.value
        #expect(daemon.requests("window.createTask").count == 1)
    }

    /// Two clicks on an offline operation's row (or a click and ↩): the second finds the reopening under
    /// way and leaves the rest to the first — the state changes once, when the window is there, and the
    /// operator hears of the resume once.
    @Test func twoClicksOnAnOfflineOperationOpenOneWindowChangeItOnceAndWakeItOnce() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let (world, run, _) = try makeWorld(runState: .operatorOffline, daemon: daemon)
        world.show([])
        var states: [OperatorRunState] = [.operatorOffline]
        let hook = world.workspace.onChange {
            guard let state = world.run(run.id)?.state, states.last != state else { return }
            states.append(state)
        }
        defer { world.workspace.removeHook(hook) }
        let first = Task { await world.controller.reopenOperator(run: run.id) }
        try await daemon.received("window.createTask")
        await world.controller.reopenOperator(run: run.id)
        #expect(world.run(run.id)?.state == .operatorOffline, "the second click changed nothing while the window is not there")
        #expect(daemon.requests("session.deliver").isEmpty)
        daemon.release()
        await first.value
        #expect(daemon.requests("window.createTask").count == 1)
        #expect(states == [.operatorOffline, .active] && world.run(run.id)?.state == .active)
        world.show([OperatorServiceFixtures.session("op2", tag: run.id)])
        try await daemon.received("session.deliver")
        let lines = daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }
        #expect(lines.count == 1 && lines[0].hasSuffix(", call run_status"), "one line, as a single click's: \(lines)")
    }

    @Test func anOperatorWithItsWindowOpenIsNotOpenedAgain() async throws {
        let (world, run, _) = try makeWorld(runState: .paused)
        try await world.controller.reopenOperatorWindow(run.id)
        #expect(world.daemon.requests("window.createTask").isEmpty)
    }

    @Test func anEndedOperationIsNotReopened() async throws {
        let (world, run, _) = try makeWorld()
        try await world.controller.end(run: run.id)
        world.show([])
        await #expect(throws: ActionUnavailable.self) { try await world.controller.reopenOperatorWindow(run.id) }
        await world.controller.reopenOperator(run: run.id)
        #expect(world.daemon.requests("window.createTask").isEmpty)
    }

    @Test func endingStopsItsOpenTasksRevokesItsTokenClosesItsWindowAndLeavesWorkersRunning() async throws {
        let (world, run, task) = try makeWorld()
        try await world.controller.end(run: run.id)
        #expect(world.run(run.id)?.state == .stopped && world.run(run.id)?.intent == .stopped)
        #expect(world.task(task.id)?.operated?.state == .stopped)
        #expect(try world.workspace.file.load().runs.first?.intent == .stopped, "saved before anything else")
        #expect(world.daemon.requests("operator.revoke").first?.params["runId"] as? String == run.id.uuidString)
        #expect(world.daemon.requests("window.close").first?.params["windowId"] as? String == "w1")
        #expect(await world.call(run.id, "run_status").message == "This broadcast has ended; its tools no longer act.")
    }

    /// From the debrief: the broadcast is stopped, so the "+" returns, and what ended stays as it ended.
    @Test func endingACompleteBroadcastStopsItAndLeavesItsEndedTasks() async throws {
        let (world, run, task) = try makeWorld(runState: .complete, taskState: .accepted)
        try await world.controller.end(run: run.id)
        #expect(world.run(run.id)?.state == .stopped && world.run(run.id)?.intent == .stopped)
        #expect(world.task(task.id)?.operated?.state == .accepted && world.task(task.id)?.operated?.takenOver == false)
        #expect(world.controller.activeRun == nil)
    }

    @Test func endingStopsTheOperationsRunningSecondOpinionsAndNoOthers() async throws {
        let (world, run, _) = try makeWorld()
        let other = OperatorServiceFixtures.run(projects: [project], state: .active)
        world.workspace.mutate { state in
            state.updateRun(id: run.id) { $0.challenges = [ChallengeRecord(id: "mine", tool: "submit_plan", askedAt: Date(timeIntervalSince1970: 0))] }
            state.runs.append(other)
            state.updateRun(id: other.id) { $0.challenges = [ChallengeRecord(id: "theirs", tool: "submit_plan", askedAt: Date(timeIntervalSince1970: 0))] }
        }
        let mine = Task { _ = try? await Task.sleep(for: .seconds(600)) }, theirs = Task { _ = try? await Task.sleep(for: .seconds(600)) }
        world.controller.tools.runningChallenges = ["mine": mine, "theirs": theirs]
        try await world.controller.end(run: run.id)
        #expect(mine.isCancelled && !theirs.isCancelled)
        theirs.cancel()
    }

    @Test func anEndThatCannotBeSavedIsTakenBackAndDoesNothingElse() async throws {
        let (world, run, task) = try makeWorld()
        try breakSaving(world)
        await #expect(throws: ActionUnavailable.self) { try await world.controller.end(run: run.id) }
        #expect(world.run(run.id)?.state == .active && world.run(run.id)?.intent == nil)
        #expect(world.task(task.id)?.operated?.state == .working)
        #expect(world.daemon.requests("operator.revoke").isEmpty && world.daemon.requests("window.close").isEmpty)
    }

    /// An end with no helper: its token is revoked on attach, and its operator's window is closed on the first
    /// connected snapshot after it — once, and only because that snapshot lists the operator's tab alone in it.
    @Test func anEndWhileTheHelperIsGoneRevokesOnAttachAndClosesTheListedOperatorWindowOnce() async throws {
        let (world, run, _) = try makeWorld()
        let folder = OperatorCommand.runFolder(run.id, home: world.ports.home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(OperatorCommand.makeToken().utf8).write(to: folder.appendingPathComponent(OperatorCommand.tokenFile))
        world.link.attached = false
        try await world.controller.end(run: run.id)
        #expect(world.run(run.id)?.intent == .stopped)
        #expect(world.daemon.requests("operator.revoke").isEmpty && world.daemon.requests("window.close").isEmpty)
        world.link.attached = true
        world.controller.daemonAttached()
        await world.controller.registering?.value
        #expect(world.daemon.requests("operator.revoke").map { $0.params["runId"] as? String } == [run.id.uuidString])
        #expect(world.daemon.requests("window.close").isEmpty, "not before a connected snapshot says what the window holds")
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        await world.controller.closingEnded?.value
        #expect(world.daemon.requests("window.close").map { $0.params["windowId"] as? String } == ["w1"])
        // The window is gone; a later attach finds nothing to close.
        world.show([])
        world.controller.daemonAttached()
        world.show([])
        await world.controller.closingEnded?.value
        #expect(world.daemon.requests("window.close").count == 1)
        #expect(world.run(run.id)?.operatorWindowId == nil && world.run(run.id)?.operatorSessionId == nil)
    }

    /// A recorded window id proves nothing about what the window holds now: it may be restored under the same id,
    /// holding the person's own tabs. Nothing is closed for a run whose operator tab is not listed.
    @Test func anEndedRunsRecordedWindowIsNotClosedWhenOnlyUntaggedTabsAreListedInIt() async throws {
        let (world, run, _) = try makeWorld()
        world.link.attached = false
        try await world.controller.end(run: run.id)
        world.link.attached = true
        world.controller.daemonAttached()
        world.show([OperatorServiceFixtures.session("mine", window: "w1", tag: UUID())])
        await world.controller.closingEnded?.value
        #expect(world.daemon.requests("window.close").isEmpty)
        #expect(world.run(run.id)?.operatorWindowId == nil, "handled: the recorded id does not outlive the snapshot")
    }

    @Test func aWindowThatHoldsTheOperatorsTabAndAnotherIsNeverClosedAsAWindow() async throws {
        let (world, run, _) = try makeWorld()
        world.link.attached = false
        try await world.controller.end(run: run.id)
        world.link.attached = true
        world.controller.daemonAttached()
        world.show([OperatorServiceFixtures.session("op", window: "w1", tag: run.id), OperatorServiceFixtures.session("mine", window: "w1", tag: UUID())])
        await world.controller.closingEnded?.value
        #expect(world.daemon.requests("window.close").isEmpty)
    }

    @Test func endingWithNoOperatorTabListedClosesNothing() async throws {
        let (world, run, _) = try makeWorld(tab: false)
        world.show([])
        try await world.controller.end(run: run.id)
        #expect(world.run(run.id)?.intent == .stopped && world.daemon.requests("operator.revoke").count == 1)
        #expect(world.daemon.requests("window.close").isEmpty, "the recorded id is not a window to close")
    }

    @Test func endingLeavesAWindowThatHoldsOtherTabsOpen() async throws {
        let (world, run, _) = try makeWorld()
        world.show([OperatorServiceFixtures.session("op", window: "w1", tag: run.id), OperatorServiceFixtures.session("mine", window: "w1", tag: UUID())])
        try await world.controller.end(run: run.id)
        #expect(world.run(run.id)?.intent == .stopped && world.daemon.requests("window.close").isEmpty)
    }

    @Test func aFailedRevokeIsLoggedAndTheWindowIsStillClosed() async throws {
        let (world, run, _) = try makeWorld(daemon: RecordingDaemon(failing: ["operator.revoke": .internal]))
        try await world.controller.end(run: run.id)
        #expect(world.run(run.id)?.intent == .stopped)
        #expect(world.daemon.requests("window.close").first?.params["windowId"] as? String == "w1")
    }

    @Test func stoppingOneTaskAndRenaming() async throws {
        let (world, run, task) = try makeWorld()
        try world.controller.stop(task: task.id)
        #expect(world.task(task.id)?.operated?.state == .stopped)
        try world.controller.rename(run: run.id, to: "  Sprint 43  ")
        #expect(world.run(run.id)?.name == "Sprint 43")
        #expect(throws: ActionUnavailable.self) { try world.controller.rename(run: run.id, to: "  ") }
        await world.controller.reopenOperator(run: run.id)
        #expect(world.daemon.requests("window.createTask").isEmpty, "its window is open: the row's click raises it, nothing reopens")
    }

    /// The same completion the tool paths reach: the last open task ended, the operation is complete, its
    /// operator is told and you are notified.
    @Test func stoppingTheLastOpenTaskCompletesTheOperation() async throws {
        let (world, run, task) = try makeWorld()
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.questions = [OperatorQuestion(id: "prompt-\(task.id.uuidString)-1", text: "Claude asks for permission",
                                                                                              task: task.id, askedAt: Date(timeIntervalSince1970: 0), resolution: nil)] } }
        try world.controller.stop(task: task.id)
        #expect(world.run(run.id)?.state == .complete)
        #expect(world.run(run.id)?.questions.first?.resolution != nil, "a question about a stopped task has nothing left to ask")
        #expect(world.notifications.posted.contains { $0.id == "debrief-\(run.id.uuidString)" && $0.target == .overview(run.id) }, "you are told it is done")
        // Its operator is woken; the waker may count the completion among several updates, so only that a line went is pinned.
        try await world.daemon.received("session.deliver")
    }

    @Test func stoppingATaskFreesItsSlotForTheNextQueuedTask() async throws {
        let (world, run, task) = try makeWorld()
        let next = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-2", state: .queued)
        world.workspace.mutate { $0.tasks.append(next) }
        try world.controller.stop(task: task.id)
        #expect(world.task(next.id)?.operated?.launch?.number == 1, "claimed by the start pass at once")
        await world.controller.lastStart?.value
    }

    @Test func aTaskThatHasEndedCannotBeStopped() throws {
        let (world, _, task) = try makeWorld(taskState: .accepted)
        #expect(throws: ActionUnavailable.self) { try world.controller.stop(task: task.id) }
        #expect(world.task(task.id)?.operated?.state == .accepted)
    }

    @Test func aRowThatIsNoOperatorsCannotBeControlled() async throws {
        let (world, _, _) = try makeWorld()
        let plain = TaskItem(id: UUID(), projectId: project.id, title: "Mine", branch: "feat/mine", worktreePath: "/tmp/mine", baseBranch: "",
                             jira: nil, agent: .claude, model: "m", reasoning: nil, firstPrompt: "", appendTicket: false,
                             createdAt: Date(timeIntervalSince1970: 0), windowId: nil)
        world.workspace.mutate { $0.tasks.append(plain) }
        await #expect(throws: ActionUnavailable.self) { try await world.controller.takeOver(task: plain.id) }
        #expect(throws: ActionUnavailable.self) { try world.controller.stop(task: plain.id) }
        #expect(throws: ActionUnavailable.self) { try world.controller.rename(run: UUID(), to: "x") }
    }

    /// Integration decision 7: a worker window you closed comes back on your click — its conversation
    /// resumed behind your work under the operation's flags, a finished worker's too, the row left on the
    /// new window — and a tab still open is brought forward instead of a second worker.
    @Test func aClosedWorkerWindowComesBackWithItsConversationAndNeverTwice() async throws {
        let (world, run, task) = try makeWorld()
        await world.controller.reopenWorker(task: task.id)
        #expect(world.daemon.requests("window.activate").map { $0.params["windowId"] as? String } == ["w9"])
        #expect(world.daemon.requests("window.createTask").isEmpty, "its tab is still open")
        // The window is closed but the row still names it.
        world.workspace.mutate { state in
            guard let i = state.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            state.tasks[i].conversations = [TaskConversation(agent: .claude, id: "conv-7")]
            state.tasks[i].windowId = "w9"
            state.tasks[i].operated?.state = .accepted
            state.tasks[i].operated?.launch = LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 1))
        }
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        await world.controller.reopenWorker(task: task.id)
        let window = try #require(world.daemon.requests("window.createTask").first)
        #expect(window.params["background"] as? Bool == true && window.params["cwd"] as? String == "/tmp/aiterm-wt")
        #expect(window.params["agentCommand"] as? String
                == AgentCommand.resumeWorker(agent: .claude, conversation: "conv-7", model: "m", reasoning: nil))
        #expect(world.task(task.id)?.windowId == "reopened")
        #expect(world.task(task.id)?.operated?.state == .accepted && world.task(task.id)?.operated?.launch?.number == 1, "resumed, never launched again")
        #expect(world.notifications.posted.isEmpty && world.controller.notices.issue == nil)
    }

    /// A click while iTerm2's tabs are not known could open a second worker beside one that is there.
    @Test func noWorkerIsReopenedWhileTheTabsAreNotKnown() async throws {
        let (world, _, task) = try makeWorld(tab: false)
        world.workspace.mutate { $0.tasks[0].conversations = [TaskConversation(agent: .claude, id: "conv-7")] }
        world.controller.handle(.itermDisconnected)
        await world.controller.reopenWorker(task: task.id)
        #expect(world.daemon.requests("window.createTask").isEmpty)
        #expect(world.controller.notices.issue?.reason == OperationIssue.disconnected("again").title)
    }

    @Test func aWorkerWindowThatWillNotOpenIsSaidInTheBanner() async throws {
        let (world, _, task) = try makeWorld(daemon: RecordingDaemon(failing: ["window.createTask": .internal]), tab: false)
        world.workspace.mutate { $0.tasks[0].conversations = [TaskConversation(agent: .claude, id: "conv-7")] }
        await world.controller.reopenWorker(task: task.id)
        #expect(world.daemon.requests("window.createTask").count == 1)
        #expect(world.controller.notices.issue?.title == "Couldn’t reopen Task PLUTO-1’s worker.")
        #expect(world.controller.notices.issue?.reason == "Its window wouldn’t open.")
        #expect(world.task(task.id)?.windowId == nil)
    }

    @Test func aWorkerWithNoConversationToResumeSaysSoInTheBanner() async throws {
        let (world, _, task) = try makeWorld(tab: false)
        await world.controller.reopenWorker(task: task.id)
        #expect(world.daemon.requests("window.createTask").isEmpty)
        #expect(world.controller.notices.issue?.title == "Couldn’t reopen Task PLUTO-1’s worker.")
        #expect(world.controller.notices.issue?.reason == "Its worker left no conversation to resume.")
    }

    @Test func aTaskThatHasNotStartedHasNoWindowToReopen() async throws {
        let (world, run, _) = try makeWorld(tab: false)
        let queued = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-2", state: .queued)
        world.workspace.mutate { $0.tasks.append(queued) }
        await world.controller.reopenWorker(task: queued.id)
        #expect(world.daemon.requests("window.createTask").isEmpty)
        #expect(world.controller.notices.issue?.reason == "It hasn’t started: AiTerm opens its window when it does.")
    }

    // -- reopening the operator --------------------------------------------------------------------
    @Test func noOperatorIsReopenedWhileTheTabsAreNotKnown() async throws {
        let (world, run, _) = try makeWorld(runState: .operatorOffline)
        world.show([])
        world.controller.handle(.itermDisconnected)
        await #expect(throws: ActionUnavailable.self) { try await world.controller.reopenOperatorWindow(run.id) }
        await world.controller.reopenOperator(run: run.id)
        #expect(world.daemon.requests("window.createTask").isEmpty)
        #expect(world.controller.notices.issue?.title == "Couldn’t reopen the Operator’s window.")
        #expect(world.run(run.id)?.state == .operatorOffline)
    }

    @Test func aClickBeforeTheNewOperatorTabIsListedOpensNothingUntilItIsListedAndClosedOrTheWaitHasPassed() async throws {
        let clock = StepClock()
        let (world, run, _) = try makeWorld(runState: .operatorOffline, adjust: { $0.now = { clock.now } })
        world.show([])
        try await world.controller.reopenOperatorWindow(run.id)
        try await world.controller.reopenOperatorWindow(run.id)
        #expect(world.daemon.requests("window.createTask").count == 1, "the tab is not listed yet")
        // Listed, then closed again: a click opens it again at once.
        world.show([OperatorServiceFixtures.session("op2", tag: run.id)])
        world.show([])
        try await world.controller.reopenOperatorWindow(run.id)
        #expect(world.daemon.requests("window.createTask").count == 2)
        // Never listed: opened again once the wait has passed.
        try await world.controller.reopenOperatorWindow(run.id)
        #expect(world.daemon.requests("window.createTask").count == 2)
        clock.advance(by: OperatorTiming.launchAdoptAfter + 1)
        try await world.controller.reopenOperatorWindow(run.id)
        #expect(world.daemon.requests("window.createTask").count == 3)
    }

    /// An end that comes while the operator is reopening: the token registered after its revoke goes again,
    /// and the window opened after its close is closed. The operation stays ended.
    @Test func anEndWhileResumeIsReopeningTheOperatorLeavesNothingOpen() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let (world, run, _) = try makeWorld(runState: .operatorOffline, daemon: daemon)
        world.show([])
        let resuming = Task { try await world.controller.resume(run: run.id) }
        try await daemon.received("window.createTask")
        try await world.controller.end(run: run.id)
        daemon.release()
        try await resuming.value
        #expect(world.run(run.id)?.state == .stopped && world.run(run.id)?.intent == .stopped)
        #expect(daemon.requests("operator.revoke").count == 2, "its own, and the one for the token registered since")
        #expect(daemon.requests("window.close").map { $0.params["windowId"] as? String } == ["reopened"])
    }

    /// An end that lands while the token is being registered: no window is opened for the ended operation at all.
    @Test func anEndWhileTheTokenIsBeingRegisteredOpensNoWindow() async throws {
        let daemon = RecordingDaemon(holding: "operator.register")
        let (world, run, _) = try makeWorld(runState: .operatorOffline, daemon: daemon)
        world.show([])
        let resuming = Task { try await world.controller.resume(run: run.id) }
        try await daemon.received("operator.register")
        try await world.controller.end(run: run.id)
        daemon.release()
        try await resuming.value
        #expect(daemon.requests("window.createTask").isEmpty)
        #expect(daemon.requests("operator.revoke").count == 2, "its own, and the one for the token registered since")
        #expect(world.run(run.id)?.state == .stopped)
    }

    /// An End while a new broadcast's window is opening: the window that arrives late is closed, the token
    /// registered is revoked again, and the broadcast stays ended, the "+" back.
    @Test func anEndWhileABroadcastsWindowOpensClosesItAndKeepsItEnded() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []), daemon: daemon)
        let starting = Task {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [project.id], prompt: "Go", review: nil, done: nil)
        }
        try await daemon.received("window.createTask")
        let id = try #require(world.state.runs.first?.id)
        try await world.controller.end(run: id)
        daemon.release()
        #expect(try await starting.value == id)
        #expect(world.run(id)?.state == .stopped && world.run(id)?.intent == .stopped)
        #expect(world.run(id)?.operatorWindowId == nil, "the window closed is not the run's")
        #expect(try world.workspace.file.load().run(id: id)?.state == .stopped)
        #expect(daemon.requests("operator.revoke").count == 2, "End's, and the one after the window arrived")
        #expect(daemon.requests("window.close").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(world.controller.activeRun == nil)
    }

    /// An End while a new broadcast's token is being registered: no window opens for it, and the token goes again.
    @Test func anEndWhileABroadcastsTokenRegistersOpensNoWindow() async throws {
        let daemon = RecordingDaemon(holding: "operator.register")
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []), daemon: daemon)
        let starting = Task {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [project.id], prompt: "Go", review: nil, done: nil)
        }
        try await daemon.received("operator.register")
        let id = try #require(world.state.runs.first?.id)
        try await world.controller.end(run: id)
        daemon.release()
        #expect(try await starting.value == id)
        #expect(daemon.requests("window.createTask").isEmpty)
        #expect(daemon.requests("operator.revoke").count == 2, "End's, and the one for the token registered since")
        #expect(world.run(id)?.state == .stopped && world.controller.activeRun == nil)
    }

    @Test func aClickOnAnEndedOperationNeverReopensIt() async throws {
        let (world, run, _) = try makeWorld()
        try await world.controller.end(run: run.id)
        world.show([])
        await world.controller.reopenOperator(run: run.id)
        #expect(world.daemon.requests("window.createTask").isEmpty)
    }

    @Test func aClickOnAnOfflineOperationResumesItInFront() async throws {
        let (world, run, _) = try makeWorld(runState: .operatorOffline)
        world.show([])
        await world.controller.reopenOperator(run: run.id)
        #expect(world.daemon.requests("window.createTask").count == 1)
        #expect(world.run(run.id)?.state == .active)
        #expect(world.daemon.requests("window.createTask").first?.params["background"] == nil, "in front")
        #expect(world.controller.notices.issue == nil)
    }

    /// The broadcast row's click reopens the Operator's window behind the board it opens (spec §9).
    @Test func aClickBehindTheBoardReopensTheWindowInTheBackground() async throws {
        let (world, run, _) = try makeWorld(runState: .operatorOffline)
        world.show([])
        await world.controller.reopenOperator(run: run.id, background: true)
        #expect(world.daemon.requests("window.createTask").first?.params["background"] as? Bool == true, "behind the sheet")
        #expect(world.run(run.id)?.state == .active)
    }

    /// A conversation that can't be resumed is said on the board (spec §13), not in the banner: its footer's
    /// Notice offers Start Fresh, which lets it go.
    @Test func aConversationThatCannotResumeIsSaidOnTheBoard() async throws {
        let (world, run, _) = try makeWorld()
        world.workspace.mutate { $0.runs[0].operatorConversation = "c-gone" }
        world.show([])
        #expect(world.run(run.id)?.state == .operatorOffline)
        await world.controller.reopenOperator(run: run.id, background: true)
        #expect(world.controller.reopenFailed.contains(run.id))
        #expect(world.controller.notices.issue == nil, "the board says it")
        #expect(world.daemon.requests("window.createTask").isEmpty)
        try await world.controller.startFresh(run: run.id)
        #expect(world.controller.reopenFailed.isEmpty)
        #expect(world.daemon.requests("window.createTask").count == 1)
    }

    @Test func resumingStartsATaskThatQueuedWhileItWasPaused() async throws {
        let (world, _, task) = try makeWorld(runState: .paused, taskState: .queued, tab: true)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.launch == nil, "paused: nothing starts")
        try await world.controller.resume(run: task.operated!.runId)
        #expect(world.task(task.id)?.operated?.launch?.number == 1, "claimed by the start pass at once")
        await world.controller.lastStart?.value
    }

    // -- reopening a worker, more ------------------------------------------------------------------
    @Test func aWorkerWindowClickedTwiceBeforeItsTabIsListedOpensOne() async throws {
        let (world, run, task) = try makeWorld(tab: false)
        world.workspace.mutate { $0.tasks[0].conversations = [TaskConversation(agent: .claude, id: "conv-7")] }
        await world.controller.reopenWorker(task: task.id)
        await world.controller.reopenWorker(task: task.id)
        #expect(world.daemon.requests("window.createTask").count == 1, "the tab is not listed yet")
        // Listed, then closed again: the next click opens it.
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "reopened", tag: task.id)])
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        await world.controller.reopenWorker(task: task.id)
        #expect(world.daemon.requests("window.createTask").count == 2)
    }

    /// A launch that never showed a window is D14's to launch again: a click resumes nothing of an earlier attempt.
    @Test func aLaunchThatNeverShowedAWindowIsLeftToTheReconciler() async throws {
        let (world, _, task) = try makeWorld(tab: false)
        world.workspace.mutate { state in
            state.tasks[0].conversations = [TaskConversation(agent: .claude, id: "conv-7")]
            state.tasks[0].operated?.launch = LaunchAttempt(number: 2, requestedAt: Date(timeIntervalSince1970: 0))
        }
        await world.controller.reopenWorker(task: task.id)
        #expect(world.daemon.requests("window.createTask").isEmpty)
        #expect(world.controller.notices.issue == nil)
        #expect(world.task(task.id)?.operated?.launch?.openedAt == nil && world.task(task.id)?.windowId == nil)
    }
}

extension RunControlsTests {
    /// The Operator's `claude` keeps its conversation under the folder `CLAUDE_CONFIG_DIR` names, so that
    /// is where a reopening looks for it before it resumes it.
    @Test func resumingFindsTheOperatorsConversationInTheConfiguredClaudeFolder() async throws {
        let (world, run, _) = try makeWorld(runState: .operatorOffline, adjust: { $0.claudeConfig = ClaudeConfig("~/profile") })
        world.controller.mutateRun(run.id) { $0.operatorConversation = "c-9" }
        let folder = world.ports.home.appendingPathComponent("profile/projects/-operator")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent("c-9.jsonl"))
        world.show([])
        try await world.controller.resume(run: run.id)
        let window = try #require(world.daemon.requests("window.createTask").first)
        #expect((window.params["agentCommand"] as? String)?.contains("c-9") == true)
    }
}
