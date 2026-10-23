import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// An operation's start and the operator's own tab (spec §4.0.1, §5, §11).
@MainActor @Suite struct OperatorControllerTests {
    let project = OperatorServiceFixtures.project()

    @Test func startingABroadcastSavesItRegistersItsTokenAndOpensTheOperatorInFront() async throws {
        var profile = OperatorServiceFixtures.profile(oracle: true)
        profile.slices.jira = true
        let saved = profile
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [])) { $0.profile = { saved } }
        let id = try await world.controller.startBroadcast(name: "  ", jiraProjectKeys: ["PLUTO"], projectIds: [project.id],
                                                           prompt: "Implement PLUTO-1 and PLUTO-2.\nThen tidy.", review: "  ",
                                                           done: "a commit per ticket")
        let run = try #require(world.run(id))
        #expect(run.name == "Implement PLUTO-1 and PLUTO-2.", "no name given: the prompt's first line")
        #expect(run.state == .planning && run.projectIds == [project.id] && run.done == "a commit per ticket")
        #expect(run.jiraProjectKeys == ["PLUTO"])
        #expect(run.profile == profile, "Settings › Operator's profile, frozen in the run")
        #expect(run.review == nil, "a blank Review is none")
        #expect(run.planRevision == 0)
        let folder = OperatorCommand.runFolder(id, home: world.ports.home)
        let register = try #require(world.daemon.requests("operator.register").first)
        #expect(register.params["runId"] as? String == id.uuidString)
        #expect(register.params["token"] as? String == OperatorCommand.existingToken(in: folder))
        let firstMessage = try String(contentsOf: folder.appendingPathComponent(OperatorCommand.firstMessageFile), encoding: .utf8)
        #expect(firstMessage == "Your broadcast:\n\nImplement PLUTO-1 and PLUTO-2.\nThen tidy.\n\nDone: a commit per ticket")
        let window = try #require(world.daemon.requests("window.createTask").first)
        #expect(window.params["taskId"] as? String == id.uuidString)
        #expect(window.params["cwd"] as? String == folder.path)
        #expect(window.params["background"] == nil)
        #expect((window.params["agentCommand"] as? String) == "eval \"$(command cat launch.sh)\"")
        #expect(try String(contentsOf: folder.appendingPathComponent(OperatorCommand.launchFile), encoding: .utf8).hasPrefix("claude "))
        #expect(run.operatorWindowId == "reopened")
        #expect(world.notifications.authorizationRequests == 1)
        #expect(try world.workspace.file.load().runs.map(\.id) == [id])
    }

    @Test func aBroadcastNeedsAPromptAndProjectsOfThisWorkspace() async throws {
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []))
        await #expect(throws: ActionUnavailable.self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [project.id], prompt: "  ", review: nil, done: nil)
        }
        await #expect(throws: ActionUnavailable.self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [UUID()], prompt: "Go", review: nil, done: nil)
        }
        await #expect(throws: ActionUnavailable.self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [], prompt: "Go", review: nil, done: nil)
        }
        world.link.attached = false
        await #expect(throws: ActionUnavailable.self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [project.id], prompt: "Go", review: nil, done: nil)
        }
        #expect(world.state.runs.isEmpty)
        #expect(world.daemon.requests.isEmpty)
    }

    @Test func theOperatorsTaggedTabGivesTheRunItsSessionWindowAndConversation() throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        world.show([OperatorServiceFixtures.session("op", window: "w7", tag: run.id, conversation: "c-123")])
        let saved = try #require(world.run(run.id))
        #expect(saved.operatorSessionId == "op" && saved.operatorWindowId == "w7" && saved.operatorConversation == "c-123")
        #expect(world.controller.operatorTab(of: run.id)?.sessionId == "op")
    }

    @Test func aDaemonAttachingReregistersEveryTokenButAStoppedRunsAndSaysItReconnected() async throws {
        let active = OperatorServiceFixtures.run(projects: [project], state: .active), stopped = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [active, stopped]))
        let tokens = [active.id: String(repeating: "a", count: 64), stopped.id: String(repeating: "b", count: 64)]
        for run in [active, stopped] {
            _ = try OperatorCommand.prepare(run: run, projects: [project], home: world.ports.home, token: tokens[run.id]!)
        }
        world.show([OperatorServiceFixtures.session("op", tag: active.id)])
        world.controller.daemonAttached()
        await world.controller.registering?.value
        #expect(world.daemon.requests("operator.register").map { $0.params["runId"] as? String } == [active.id.uuidString])
        #expect(world.daemon.requests("operator.register").first?.params["token"] as? String == tokens[active.id])
        try await world.daemon.received("session.deliver")
        #expect(world.daemon.requests("session.deliver").first?.params["text"] as? String == "[AiTerm] reconnected, call run_status")
    }

    @Test func aRunChangingIsHeardOnceAndAnUnrelatedChangeNotAtAll() throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        var heard = 0
        world.controller.onChange { heard += 1 }
        world.workspace.mutate { $0.sidebarFrame = CGRect(x: 0, y: 0, width: 10, height: 10) }
        world.controller.mutateRun(run.id) { $0.name = "Renamed" }
        #expect(heard == 1)
        world.controller.setActing(OperatorActivity(run: run.id, task: nil, act: .loadingTheConstruct), true)
        #expect(heard == 2)
    }

    @Test func aBroadcastIsNamedFromItsBriefsFirstLine() {
        #expect(OperatorController.broadcastName(from: "\n  Fix the login bug  \nmore") == "Fix the login bug")
        #expect(OperatorController.broadcastName(from: String(repeating: "a", count: 80)) == String(repeating: "a", count: 80),
                "whole: the views cut it at their width")
        #expect(OperatorController.broadcastName(from: " \n\t\n") == nil, "a brief with nothing in it, which New Broadcast refuses")
    }

    /// The operator's window closed (spec §9): the run forgets the window and session, and a broadcast under
    /// way goes offline while a complete one keeps its debrief: nothing ends, and a click on its row reopens it. A tab not yet seen,
    /// or tabs not known while iTerm2 is away, close nothing.
    @Test func closingTheOperatorsWindowForgetsItAndTakesTheBroadcastOffline() async throws {
        let active = OperatorServiceFixtures.run(projects: [project], state: .active)
        let complete = OperatorServiceFixtures.run(projects: [project], state: .complete)
        var opening = OperatorServiceFixtures.run(projects: [project], state: .planning)
        opening.operatorWindowId = "w-new"
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [active, complete, opening]))
        world.show([OperatorServiceFixtures.session("op1", window: "w1", tag: active.id),
                    OperatorServiceFixtures.session("op2", window: "w2", tag: complete.id)])
        world.controller.handle(.itermDisconnected)
        world.live.sessions = []
        world.controller.handle(.windowClosed("w1"))
        #expect(world.run(active.id)?.operatorWindowId == "w1", "iTerm2 away: its tabs are not known gone")
        world.show([])
        #expect(world.run(active.id)?.operatorWindowId == nil && world.run(active.id)?.operatorSessionId == nil)
        #expect(world.run(active.id)?.state == .operatorOffline && world.run(active.id)?.intent == nil)
        #expect(world.run(opening.id)?.operatorWindowId == "w-new", "a window whose tab was never seen may still be opening")
        #expect(world.run(complete.id)?.state == .complete && world.run(complete.id)?.intent == nil, "the debrief stays until End")
        #expect(world.daemon.requests("operator.revoke").isEmpty)
    }

    /// A notification's click on an overview (spec §10.3) is for the sidebar to present: it reads
    /// `presentOverview` and clears it.
    @Test func aNotificationsClickOnAnOverviewAsksTheSidebarToPresentIt() {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        let id = UUID()
        controller.openNote(.overview(id))
        #expect(controller.operatorController.presentOverview == id)
    }

    /// News that came while the run was paused is not lost: the wake line goes when it resumes.
    @Test func aPausedRunsWakeNewsGoesWhenItResumes() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .paused)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.workspace.mutate { $0.tasks.append(OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1")) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(world.daemon.requests("session.deliver").isEmpty, "a paused run's operator is not woken")
        world.controller.mutateRun(run.id) { $0.state = .active }
        try await world.daemon.received("session.deliver")
        #expect(world.daemon.requests("session.deliver").first?.params["text"] as? String == "[AiTerm] updates waiting, call run_status")  // the task, and the resuming itself
    }

    // -- the summary: when it is ready (Operator sheet spec, Summary) ------------------------------
    /// An active broadcast of one working task, its Operator's tab listed, on a clock the test moves. Stop Task
    /// ends the task, which completes it.
    private func broadcast(_ clock: StepClock, adjust: @escaping (inout OperatorPorts) -> Void = { _ in }) throws
        -> (OperatorWorld, OperatorRun, TaskItem) {
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working, worktree: "/tmp/aiterm-wt")
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { ports in
            ports.now = { clock.now }
            adjust(&ports)
        }
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        return (world, run, task)
    }

    /// Completing records when, and asks for the summary: nothing is ready, and nothing is posted, until it is
    /// written or `summaryWait` has passed with none — read on any change of the run, as after a relaunch.
    @Test func completingRecordsWhenAndWaitsForTheSummary() throws {
        let clock = StepClock()
        let (world, run, task) = try broadcast(clock)
        try world.controller.stop(task: task.id)
        let done = try #require(world.run(run.id))
        #expect(done.state == .complete && done.completedAt == clock.now)
        #expect(RunSummary(done) == .writing && world.notifications.posted.isEmpty)
        clock.advance(by: OperatorTiming.summaryWait - 1)
        world.controller.runChanged(run.id)
        #expect(world.run(run.id)?.summaryGivenUp == false, "not yet")
        clock.advance(by: 1)
        world.controller.runChanged(run.id)
        #expect(world.run(run.id)?.summaryGivenUp == true)
        #expect(world.notifications.posted.map(\.body) == ["The task is done."])
        #expect(world.notifications.posted.map(\.id) == ["debrief-\(run.id.uuidString)"])
        #expect(try world.workspace.file.load().run(id: run.id)?.summaryGivenUp == true, "saved")
    }

    /// The wait completing schedules: its end gives up on a summary that did not come, and the note goes then.
    @Test func theWaitEndingWithNoSummaryGivesUpAndNotifies() async throws {
        let clock = StepClock()
        let gate = SleepGate(opened: true)
        let (world, run, task) = try broadcast(clock) { $0.summarySleep = { await gate.wait($0) } }
        try world.controller.stop(task: task.id)
        await world.controller.summaryWait?.value
        #expect(gate.asked == [.seconds(OperatorTiming.summaryWait)], "one wait per completion")
        let run2 = try #require(world.run(run.id))
        #expect(run2.summaryGivenUp && RunSummary(run2) == .notComing)
        #expect(world.notifications.posted.map(\.body) == ["The task is done."])
    }

    /// A summary written before the wait ends: never given up, and the note says it is ready.
    @Test func aSummaryWrittenFirstIsNeverGivenUp() async throws {
        let clock = StepClock(), gate = SleepGate()
        let (world, run, task) = try broadcast(clock) { $0.summarySleep = { await gate.wait($0) } }
        try world.controller.stop(task: task.id)
        #expect(await world.call(run.id, "write_summary", ["text": "It merged."]).value?["written"] == true)
        #expect(world.notifications.posted.map(\.body) == ["The summary is ready."])
        clock.advance(by: OperatorTiming.summaryWait)
        gate.open()
        await world.controller.summaryWait?.value
        world.controller.runChanged(run.id)
        #expect(world.run(run.id)?.summaryGivenUp == false)
        #expect(world.notifications.posted.map(\.body) == ["The summary is ready."], "posted once")
    }

    /// The Operator's window gone after completion: no summary is coming, at once.
    @Test func theOperatorsWindowGoneAfterCompletionGivesUpAtOnce() throws {
        let clock = StepClock()
        let (world, run, task) = try broadcast(clock)
        try world.controller.stop(task: task.id)
        world.show([])
        #expect(world.run(run.id)?.state == .complete && world.run(run.id)?.summaryGivenUp == true, "the window closed")
        #expect(world.notifications.posted.map(\.body) == ["The task is done."])

        let (offline, other, its) = try broadcast(clock)
        try offline.controller.stop(task: its.id)
        offline.controller.mutateRun(other.id) { $0.state = .operatorOffline }
        offline.controller.runChanged(other.id)
        #expect(offline.run(other.id)?.summaryGivenUp == true, "offline")
    }

    @Test func endingRecordsWhen() async throws {
        let clock = StepClock()
        let (world, run, _) = try broadcast(clock)
        clock.advance(by: 90)
        try await world.controller.end(run: run.id)
        #expect(world.run(run.id)?.endedAt == clock.now)
        #expect(try world.workspace.file.load().run(id: run.id)?.endedAt == clock.now)
    }

    /// Remove on the Shelf: the run and its folder go, the tasks it ran — in the sidebar or shelved — stay.
    @Test func forgettingAnEndedBroadcastKeepsItsTasks() async throws {
        var ended = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        ended.intent = .stopped
        let live = OperatorServiceFixtures.task(in: ended, project: project, key: "PLUTO-1", state: .stopped)
        let shelved = OperatorServiceFixtures.task(in: ended, project: project, key: "PLUTO-2", state: .published)
        var state = OperatorServiceFixtures.state(projects: [project], runs: [ended], tasks: [live])
        state.archive = [ArchivedTask(task: shelved, archivedAt: Date(timeIntervalSince1970: 50))]
        let world = try OperatorWorld(state)
        let folder = world.controller.folder(of: ended.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent(ActivityLog.file))

        try await world.controller.forget(run: ended.id)
        #expect(world.state.runs.isEmpty)
        #expect(try world.workspace.file.load().runs.isEmpty, "saved")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "its activity log and summary with it")
        #expect(world.state.tasks == [live])
        #expect(world.state.archive == state.archive)
    }

    /// A line still on its way to the log when the broadcast is removed does not make its folder again: Remove waits
    /// for it, and a line whose run has gone is not written.
    @Test func aLineInFlightDoesNotMakeAForgottenRunsFolderAgain() async throws {
        var ended = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        ended.intent = .stopped
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [ended]))
        let folder = world.controller.folder(of: ended.id)
        world.controller.tools.record(OperatorRequest(requestId: "r1", runId: ended.id.uuidString, tool: "run_status", arguments: [:]),
                                      answer: .result(["ok": true]), outcome: .ok)
        try await world.controller.forget(run: ended.id)
        await world.controller.tools.lastRecording?.value
        #expect(world.state.runs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aBroadcastThatHasNotEndedIsNotForgotten() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        await #expect(throws: ActionUnavailable.self) { try await world.controller.forget(run: run.id) }
        #expect(world.state.runs.map(\.id) == [run.id])
    }

    /// A forget that cannot be saved is taken back, and its folder kept.
    @Test func aForgetThatCannotBeSavedLeavesTheBroadcast() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        let folder = world.controller.folder(of: run.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(world.workspace.flush())
        let backup = world.workspace.file.backupURL
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        await #expect(throws: ActionUnavailable.self) { try await world.controller.forget(run: run.id) }
        #expect(world.state.runs.map(\.id) == [run.id])
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    /// A new plan on a complete broadcast: its completion, and its summary, belonged to the old one.
    @Test func aPlanSubmittedAfterCompletionReopensIt() async throws {
        let clock = StepClock()
        let (world, run, task) = try broadcast(clock)
        try world.controller.stop(task: task.id)
        world.link.attached = false
        _ = await world.call(run.id, "write_summary", ["text": "It merged."])
        _ = await world.call(run.id, "create_task", ["key": "PLUTO-2", "title": "Fix PLUTO-2", "brief": "Fix it.", "project": "Shop",
                                                     "agent": "codex", "model": "gpt-6-astra", "modelReason": "Codex.", "end": "commit"])
        #expect(await world.call(run.id, "submit_plan", ["revision": 2]).value?["released"] == 1)
        let reopened = try #require(world.run(run.id))
        #expect(reopened.state == .active && reopened.completedAt == nil && reopened.summary == nil)
    }

    // -- a start that fails leaves nothing behind -----------------------------------------------
    private func startFailing(_ world: OperatorWorld) async {
        await #expect(throws: (any Error).self) {
            try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [project.id], prompt: "Go", review: nil, done: nil)
        }
    }

    /// The folder a failed start wrote: its token file is gone, its brief stays.
    private func expectTokenDiscarded(_ world: OperatorWorld) throws {
        let parent = OperatorCommand.runFolder(UUID(), home: world.ports.home).deletingLastPathComponent()
        let folder = try #require(try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).first)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(OperatorCommand.tokenFile).path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(OperatorCommand.briefFile).path))
    }

    private func expectNoRun(_ world: OperatorWorld) throws {
        #expect(world.state.runs.isEmpty)
        #expect(try world.workspace.file.load().runs.isEmpty)
    }

    @Test func aFailingSaveTakesTheRunBackOutAndRegistersNothing() async throws {
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []))
        #expect(world.workspace.flush())
        let backup = world.workspace.file.backupURL
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        await startFailing(world)
        #expect(world.state.runs.isEmpty)
        #expect(world.daemon.requests("operator.register").isEmpty && world.daemon.requests("window.createTask").isEmpty)
        try expectTokenDiscarded(world)
    }

    @Test func aFailingRegisterTakesTheRunBackOutAndOpensNoWindow() async throws {
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []),
                                      daemon: RecordingDaemon(failing: ["operator.register": "temporary_failure"]))
        await startFailing(world)
        try expectNoRun(world)
        #expect(world.daemon.requests("window.createTask").isEmpty)
        try expectTokenDiscarded(world)
    }

    @Test func aFailingWindowTakesTheRunBackOutAndRevokesItsToken() async throws {
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []),
                                      daemon: RecordingDaemon(failing: ["window.createTask": "temporary_failure"]))
        await startFailing(world)
        try expectNoRun(world)
        try expectTokenDiscarded(world)
        let registered = try #require(world.daemon.requests("operator.register").first?.params["runId"] as? String)
        #expect(world.daemon.requests("operator.revoke").map { $0.params["runId"] as? String } == [registered])
    }

    @Test func aDaemonAttachingRevokesTheTokenOfARunYouEndedWhileItsTokenFileIsThere() async throws {
        let ended = OperatorServiceFixtures.run(projects: [project], state: .complete)
        let gone = OperatorServiceFixtures.run(projects: [project], state: .complete)
        var endedByYou = ended, goneByYou = gone
        endedByYou.intent = .stopped
        goneByYou.intent = .stopped
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [endedByYou, goneByYou]))
        _ = try OperatorCommand.prepare(run: endedByYou, projects: [project], home: world.ports.home, token: String(repeating: "c", count: 64))
        world.controller.daemonAttached()
        await world.controller.registering?.value
        #expect(world.daemon.requests("operator.revoke").map { $0.params["runId"] as? String } == [endedByYou.id.uuidString])
        #expect(world.daemon.requests("operator.register").isEmpty)
    }

    @Test func aNotificationOverviewWaitsForTheRenameSheetToDismiss() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorServiceFixtures.run(projects: [project])
        controller.workspace.mutate { $0.runs = [run] }
        controller.sheet = .rename(.broadcast(run))
        controller.openNote(.overview(run.id))
        controller.presentRequestedOverview()
        #expect(controller.sheet?.id == "rename-\(run.id)")
        #expect(controller.operatorController.presentOverview == run.id)
        controller.sheets.sheet = nil
        guard case .broadcastBoard(let id)? = controller.sheet else { Issue.record("No deferred board"); return }
        #expect(id == run.id)
        #expect(controller.operatorController.presentOverview == nil)
        controller.sheet = nil
        #expect(controller.sheet == nil)
    }

    @Test func aDeferredOverviewForARemovedRunClearsSilently() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorServiceFixtures.run(projects: [project])
        controller.workspace.mutate { $0.runs = [run] }
        controller.sheet = .newDivider
        controller.openNote(.overview(run.id))
        controller.presentRequestedOverview()
        #expect(controller.operatorController.presentOverview == run.id)
        controller.workspace.mutate { $0.runs = [] }
        controller.sheets.sheet = nil
        #expect(controller.sheet == nil)
        #expect(controller.operatorController.presentOverview == nil)
    }

    // -- an answer typed in a worker's window (spec §I) ---------------------------------------------------

    /// An active run with two working tasks, PAY-2 and PAY-3, and the open questions each of `questions` says: its key and
    /// the task it is about, by key.
    func askedWorld(_ questions: [(String, String?)]) throws -> (OperatorWorld, OperatorRun, [String: TaskItem]) {
        var run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let tasks = ["PAY-2", "PAY-3"].map { OperatorServiceFixtures.task(in: run, project: project, key: $0, state: .working) }
        let byKey = Dictionary(uniqueKeysWithValues: tasks.map { ($0.operated!.key, $0) })
        run.questions = questions.map { key, task in
            OperatorQuestion(id: key, text: "Which locale is the default?", task: task.flatMap { byKey[$0]?.id }, askedAt: Date(timeIntervalSince1970: 0))
        }
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: tasks))
        return (world, run, byKey)
    }

    /// The Operator's tab and each worker in `workers`, by key, as the helper lists them with what you typed there.
    func showWorkers(_ world: OperatorWorld, _ run: OperatorRun, _ workers: [String: TaskItem], typed: [String: String?]) {
        let tabs = workers.sorted { $0.key < $1.key }.map { key, task in
            var tab = OperatorServiceFixtures.session("s-\(key)", tag: task.id, state: typed[key].map { $0 == nil ? .idle : .working } ?? .idle)
            tab.yourPrompt = typed[key] ?? nil
            return tab
        }
        world.show([OperatorServiceFixtures.session("op", window: "wop", tag: run.id)] + tabs)
    }

    /// A prompt you type into a task's worker, while a question about that task is open, is written on the question: its
    /// first line, the newest replacing the last, once per prompt. It stays on the question after the turn ends, which clears
    /// the prompt.
    @Test func aPromptTypedInTheWorkerIsWrittenOnTheOpenQuestion() throws {
        let (world, run, tasks) = try askedWorld([("locale", "PAY-2")])
        func written() -> String? { world.run(run.id)?.questions.first?.answeredInWindow }
        showWorkers(world, run, tasks, typed: ["PAY-2": nil, "PAY-3": nil])
        #expect(written() == nil)
        showWorkers(world, run, tasks, typed: ["PAY-2": "Use nl-BE as the default\nand keep en", "PAY-3": nil])
        #expect(written() == "Use nl-BE as the default")
        // Once per prompt: the same prompt shown again writes nothing.
        var writes = 0
        world.workspace.onChange { writes += 1 }
        showWorkers(world, run, tasks, typed: ["PAY-2": "Use nl-BE as the default\nand keep en", "PAY-3": nil])
        #expect(writes == 0)
        showWorkers(world, run, tasks, typed: ["PAY-2": nil, "PAY-3": nil])
        #expect(written() == "Use nl-BE as the default", "the turn ended and cleared the prompt; the question keeps it")
        showWorkers(world, run, tasks, typed: ["PAY-2": "Actually use fr-BE", "PAY-3": nil])
        #expect(written() == "Actually use fr-BE", "the newest replaces the last")
        let status = try #require(world.controller.status(of: run))
        #expect(status.obligations.questionsWaiting.map(\.answeredInWindow) == ["Actually use fr-BE"])
    }

    /// AiTerm only says what you typed: the question stays open, and its task still waits on you, until `resolve_question`.
    @Test func itNeverResolvesTheQuestion() throws {
        let (world, run, tasks) = try askedWorld([("locale", "PAY-2")])
        world.workspace.mutate { $0.updateOperated(tasks["PAY-2"]!.id) { $0.flags.insert(.waitingOnYou) } }
        showWorkers(world, run, tasks, typed: ["PAY-2": "Use nl-BE", "PAY-3": nil])
        showWorkers(world, run, tasks, typed: ["PAY-2": nil, "PAY-3": nil])
        let question = try #require(world.run(run.id)?.questions.first)
        #expect(question.resolution == nil)
        #expect(world.state.task(id: tasks["PAY-2"]!.id)?.operated?.flags.contains(.waitingOnYou) == true)
        #expect(world.controller.status(of: run)?.obligations.questionsWaiting.map(\.key) == ["locale"])
    }

    /// Only an open `ask_you` question about the task whose worker you typed in is marked: not one about another task, one
    /// about none, a resolved one, or one of AiTerm's own.
    @Test func onlyQuestionsAboutThatTaskAreMarked() throws {
        let (world, run, tasks) = try askedWorld([("locale", "PAY-2"), ("other-task", "PAY-3"), ("no-task", nil), ("old", "PAY-2")])
        world.workspace.mutate { state in
            state.updateRun(id: run.id) {
                $0.questions[3].resolution = "Done"
                $0.questions.append(OperatorQuestion(id: "prompt-\(tasks["PAY-2"]!.id.uuidString)-1", text: "Codex asks", task: tasks["PAY-2"]!.id,
                                                     askedAt: Date(timeIntervalSince1970: 0)))
                $0.questions.append(OperatorQuestion(id: "merged-on-host-\(tasks["PAY-2"]!.id.uuidString)", text: "Merged?", task: tasks["PAY-2"]!.id,
                                                     askedAt: Date(timeIntervalSince1970: 0)))
                $0.questions.append(OperatorQuestion(id: "gate-1", text: "Run it?", task: tasks["PAY-2"]!.id, askedAt: Date(timeIntervalSince1970: 0),
                                                     gate: GateRequest(command: "ls", directory: "/tmp")))
            }
        }
        showWorkers(world, run, tasks, typed: ["PAY-2": "Use nl-BE", "PAY-3": nil])
        let marked = world.run(run.id)?.questions.filter { $0.answeredInWindow != nil }.map(\.id)
        #expect(marked == ["locale"])
    }
}

/// A `summarySleep` that ends when the test says, or at once once opened, and keeps what it was asked to wait.
@MainActor final class SleepGate {
    private(set) var asked: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened: Bool
    init(opened: Bool = false) { self.opened = opened }
    func wait(_ duration: Duration) async {
        asked.append(duration)
        guard !opened else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
