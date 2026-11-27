import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// A project signal's Done and Then through the controller's own tick, on a fake clock: its pick-ups scripted as in
/// `PickupRig`, its Done reads and the app's archive scripted here (`DoneScript`). The baseline is read before the window
/// opens; the watch reads each minute, sees Done as an edge, and finishes Then, retrying what may still happen.
@Suite @MainActor struct ProjectSignalWatchTests {
    static let jiraDone = SignalTrigger(source: .jira, query: "status = Done")

    static func tick(_ rig: PickupRig, by seconds: TimeInterval = OperatorTiming.reconcileInterval) async {
        rig.clock.advance(by: seconds)
        await rig.root.reconcile(); await rig.settled()
    }
    static func origin(_ rig: PickupRig, _ id: UUID) -> SignalOrigin? { rig.state.signalItem(id: id)?.signalOrigin }

    /// Two full review cycles: a reviewer match is picked up, its Done reached archives it; matched again (the request
    /// left the read and came back), it is restored, reads a fresh baseline before its prompt reaches it, opens behind
    /// with the prompt, and its Done reached again archives it again.
    @Test func twoFullReviewCyclesArchiveBothTimes() async throws {
        var world = SignalWorld()
        let signal = world.projectSignal(start: SignalTrigger(source: .gitLab, query: "reviewer:@me"),
                                         done: SignalTrigger(source: .gitLab, query: "reviewer:any"), then: .archive)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig)
        await rig.start()

        rig.pass(signal, [ProjectSignalsTests.request(7)], accountUser: "alex")
        await rig.settled()
        let id = try #require(rig.state.tasks.first?.id)
        #expect(Self.origin(rig, id)?.doneMatched == false && rig.opens.count == 1)
        await Self.tick(rig)
        #expect(Self.origin(rig, id)?.doneAt == nil, "Not matching yet.")

        script.facts.doneMatches = true
        await Self.tick(rig)
        #expect(rig.state.archived(id: id) != nil && Self.origin(rig, id)?.thenApplied == true)
        #expect(script.archives == [id])

        // The re-match, through the router: restored, a fresh baseline read, then the prompt opened behind.
        script.facts.doneMatches = false
        let reads = script.reads.count
        rig.pass(signal, [], accountUser: "alex")
        rig.pass(signal, [ProjectSignalsTests.request(7)], accountUser: "alex")
        await rig.settled()
        #expect(rig.restores == [id] && rig.effects.suffix(2) == ["restore", "open"] && rig.opens.count == 2)
        #expect(script.reads.count == reads + 1 && script.reads.last?.owing == true, "The baseline is read before the prompt reaches it.")
        #expect(Self.origin(rig, id)?.doneMatched == false && Self.origin(rig, id)?.owed == nil && Self.origin(rig, id)?.thenApplied == nil)

        await Self.tick(rig)
        #expect(rig.state.task(id: id) != nil, "Not matching yet.")
        script.facts.doneMatches = true
        await Self.tick(rig)
        #expect(rig.state.archived(id: id) != nil && Self.origin(rig, id)?.thenApplied == true)
        #expect(script.archives == [id, id])
    }

    /// The baseline is read and saved before the window opens, while the window still waits for the person's pause, and
    /// also when the Done query already matches: that match is the baseline, not a Done.
    @Test func theBaselineIsSavedBeforeTheWindowOpensAlsoWhenItMatches() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone)
        let typing = Typing()
        let rig = try PickupRig(world, pause: typing.gate); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.facts.doneMatches = true
        await rig.start()

        rig.pass(signal, [world.ticket()])
        #expect(await eventually { rig.state.tasks.first?.signalOrigin?.doneKey != nil })
        await rig.settled(leaving: 1)
        let id = try #require(rig.state.tasks.first?.id)
        #expect(rig.opens.isEmpty && Self.origin(rig, id)?.owed?.kind == .launch)
        let saved = try rig.workspace.file.load().task(id: id)?.signalOrigin
        #expect(saved?.doneKey == SignalOrigin.doneKey(Self.jiraDone) && saved?.doneMatched == true)
        #expect(script.reads.map(\.item) == [world.ticket().item] && script.reads.first?.done == Self.jiraDone)

        typing.idle = 10
        await rig.settled()
        #expect(rig.opens.count == 1 && script.reads.count == 1, "Read once, before the window.")
        await Self.tick(rig)
        #expect(Self.origin(rig, id)?.doneAt == nil, "A match at the baseline is not an edge.")
    }

    /// A Done the worker reaches during its first turn is an edge against the baseline read before it, and archives.
    @Test func aDoneReachedDuringTheFirstTurnIsAnEdgeAndArchives() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .archive)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig)
        await rig.start()
        rig.pass(signal, [world.ticket()]); await rig.settled()
        let id = try #require(rig.state.tasks.first?.id)
        #expect(rig.opens.count == 1 && Self.origin(rig, id)?.doneMatched == false)

        script.facts.doneMatches = true
        await Self.tick(rig)
        #expect(Self.origin(rig, id)?.doneAt == rig.clock.now && rig.state.archived(id: id) != nil)
    }

    /// A baseline that cannot be read holds the launch, the task owing its prompt and the reason as the item's skipped
    /// record beside its started one; five minutes later it is read again and the window opens.
    @Test func aFailedBaselineReadHoldsTheLaunchAndRetries() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.failures = [ActionUnavailable("Connect Jira in Settings.")]
        await rig.start()

        rig.pass(signal, [world.ticket()]); await rig.settled()
        let id = try #require(rig.state.tasks.first?.id)
        #expect(rig.opens.isEmpty && Self.origin(rig, id)?.owed?.kind == .launch && Self.origin(rig, id)?.doneKey == nil)
        #expect(Set(rig.state.signalSeen.map(\.disposition)) == [.started, .skipped])
        #expect(rig.state.signalSeen.first { $0.disposition == .skipped }?.reason == "Its Done trigger could not be read: Connect Jira in Settings.")
        rig.pass(signal, [world.ticket()]); await rig.settled()
        #expect(rig.state.tasks.count == 1 && Self.origin(rig, id)?.owed?.kind == .launch, "The item is not decided again.")

        await Self.tick(rig)
        #expect(script.reads.count == 1 && rig.opens.isEmpty, "Held.")
        await Self.tick(rig, by: SignalPoller.failureBackOff)
        #expect(rig.opens.map(\.id) == [id])
        #expect(script.reads.filter(\.owing).count == 2, "Two baseline reads, both before the prompt.")
        #expect(Self.origin(rig, id)?.doneKey == SignalOrigin.doneKey(Self.jiraDone) && Self.origin(rig, id)?.owed == nil)
        #expect(rig.state.signalSeen.map(\.disposition) == [.started])
    }

    /// A task still owing its first prompt is not read by the watch, even with its baseline saved.
    @Test func aTaskOwingItsFirstPromptIsNotReadByTheWatch() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone)
        let id = world.owing(signal: signal, .launch, window: nil)
        world.state.updateSignalItem(id) { $0.signalOrigin?.doneKey = SignalOrigin.doneKey(Self.jiraDone); $0.signalOrigin?.doneMatched = false }
        let typing = Typing()
        let rig = try PickupRig(world, pause: typing.gate); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.facts.doneMatches = true
        rig.root.start(); await rig.settled(leaving: 1)
        for _ in 0..<2 {
            // The runner waits for the pause meanwhile: everything else settles.
            rig.clock.advance(by: OperatorTiming.reconcileInterval)
            await rig.root.reconcile(); await rig.settled(leaving: 1)
        }

        #expect(script.reads.isEmpty && rig.opens.isEmpty && Self.origin(rig, id)?.doneAt == nil)
        typing.idle = 10
        await rig.settled()
    }

    /// A re-match clears the baseline; it is read afresh, once, before the prompt is typed, and the watch leaves the task
    /// alone while the prompt is owed.
    @Test func aRematchReadsAFreshBaselineBeforeTyping() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone)
        let id = world.launched(signal: signal, matched: true, doneAt: world.now, thenApplied: true)
        let now = world.now
        world.state.updateSignalItem(id) { task in
            task.signalOrigin?.owed = OwedPrompt(text: "Again", at: now, kind: .delivery)
            task.signalOrigin?.doneKey = nil; task.signalOrigin?.doneMatched = nil; task.signalOrigin?.doneAt = nil
            task.signalOrigin?.thenApplied = nil
        }
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig)
        // Its worker at work: the delivery waits, and reads nothing until it may type.
        rig.live.sessions = [OperatorServiceFixtures.session("s1", window: "task-window", tag: id, state: .working)]
        await rig.start(); await Self.tick(rig)
        #expect(script.reads.isEmpty, "The watch reads no task that owes a prompt.")

        #expect(await rig.root.projectSignals.baseline(id))
        #expect(script.reads.map(\.task) == [id])
        #expect(Self.origin(rig, id)?.doneKey == SignalOrigin.doneKey(Self.jiraDone) && Self.origin(rig, id)?.doneMatched == false)
        #expect(Self.origin(rig, id)?.owed?.kind == .delivery, "The prompt is still to type.")
        #expect(await rig.root.projectSignals.baseline(id) && script.reads.count == 1, "Read once.")
    }

    /// Not matching, then matching, is done; Keep leaves the row in the sidebar and finishes Then at once.
    @Test func notMatchingThenMatchingIsDoneAndKeepLeavesTheRow() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone)
        let id = world.launched(signal: signal)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig)
        await rig.start()
        #expect(script.reads.count == 1 && Self.origin(rig, id)?.doneAt == nil)

        script.facts.doneMatches = true
        await Self.tick(rig)
        #expect(Self.origin(rig, id)?.doneAt == rig.clock.now && Self.origin(rig, id)?.thenApplied == true)
        #expect(rig.state.task(id: id) != nil && script.archives.isEmpty)
        await Self.tick(rig)
        #expect(script.reads.count == 2, "No query is read after done.")
    }

    /// With You decide, a merged or closed request is done, though no query is asked.
    @Test(arguments: [true, false]) func mergedOrClosedIsDoneWithYouDecide(merged: Bool) async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.launched(signal: signal)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig)
        await rig.start()
        #expect(Self.origin(rig, id)?.doneAt == nil)

        if merged { script.facts.merged = true } else { script.facts.closed = true }
        await Self.tick(rig)
        #expect(Self.origin(rig, id)?.doneAt != nil && script.reads.allSatisfy { $0.done.source == .person })
    }

    /// Archive goes through the app's teardown, which is told the task may still go while it is unchanged and idle.
    @Test func archiveArchivesThroughTheScriptedTeardown() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .archive)
        let id = world.launched(signal: signal)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.facts.doneMatches = true
        await rig.start()

        #expect(script.archives == [id] && script.allowedAtArchive == [true])
        #expect(rig.state.archived(id: id)?.task.signalOrigin?.thenApplied == true && rig.state.task(id: id) == nil)
        #expect(try rig.workspace.file.load().archived(id: id)?.task.signalOrigin?.thenApplied == true)
    }

    /// A turn under way when the archive starts (`ClosingWait`) leaves Then pending; the next pass archives.
    @Test func thenIsRetriedAfterAClosingWait() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .archive)
        let id = world.launched(signal: signal)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.facts.doneMatches = true
        script.archiveFailures = [ClosingWait.turn]
        await rig.start()
        #expect(Self.origin(rig, id)?.doneAt != nil && Self.origin(rig, id)?.thenApplied == nil && rig.state.task(id: id) != nil)

        await Self.tick(rig)
        #expect(script.archives == [id, id] && rig.state.archived(id: id) != nil && Self.origin(rig, id)?.thenNote == nil)
    }

    /// After a restart, a task saved done with its Then unfinished gets its Then, without a read.
    @Test func thenIsRetriedAfterARestart() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .archive)
        let id = world.launched(signal: signal, matched: true, doneAt: world.now)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig)
        await rig.start()

        #expect(script.reads.isEmpty && script.archives == [id] && Self.origin(rig, id)?.thenApplied == true)
    }

    /// A refusal for good, unsaved work, lands in `thenNote` with Then finished, and is not tried again.
    @Test func aRefusalLandsInThenNoteAndIsNotRetried() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .archive)
        let id = world.launched(signal: signal, matched: true, doneAt: world.now)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig)
        script.archiveFailures = [ActionUnavailable(TaskTeardown.unsavedWork)]
        await rig.start()

        #expect(Self.origin(rig, id)?.thenNote == TaskTeardown.unsavedWork && Self.origin(rig, id)?.thenApplied == true)
        #expect(rig.state.task(id: id) != nil)
        await Self.tick(rig)
        #expect(script.archives == [id], "Not tried again.")
    }

    /// A session of the task at work delays both the read and Then; once it is idle, the task is archived.
    @Test func aWorkingSessionDelaysThen() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .archive)
        let id = world.launched(signal: signal, matched: true, doneAt: world.now)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [OperatorServiceFixtures.session("agent", window: "task-window", tag: id, state: .working)]
        let script = DoneScript(); script.install(rig)
        await rig.start()
        #expect(script.archives.isEmpty && rig.state.task(id: id) != nil)

        rig.live.sessions = [OperatorServiceFixtures.session("agent", window: "task-window", tag: id, state: .idle)]
        await Self.tick(rig)
        #expect(script.archives == [id] && rig.state.archived(id: id) != nil)
    }

    /// A session whose turn ended but that left background work holding it, or an active test run, delays Archive too;
    /// once nothing holds the turn, the task is archived.
    @Test(arguments: [false, true]) func workHoldingTheTurnDelaysArchive(testRun: Bool) async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .archive)
        let id = world.launched(signal: signal, matched: true, doneAt: world.now)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        var holding = OperatorServiceFixtures.session("agent", window: "task-window", tag: id, state: .done)
        if testRun { holding.testActivity = TestActivity(runId: "own", suite: "swift", state: .running) }
        else { holding.work = [WorkItem(kind: .shell, text: "npm run build", holdsTurn: true)] }
        rig.live.sessions = [holding]
        let script = DoneScript(); script.install(rig)
        await rig.start(); await Self.tick(rig)
        #expect(script.archives.isEmpty && rig.state.task(id: id) != nil && Self.origin(rig, id)?.thenApplied == nil)

        rig.live.sessions = [OperatorServiceFixtures.session("agent", window: "task-window", tag: id, state: .done)]
        await Self.tick(rig)
        #expect(script.archives == [id] && rig.state.archived(id: id) != nil)
    }

    /// An idle worker whose input holds the person's unsent words, or an agent's input nothing tells about, holds Archive
    /// pending: closing its tab would lose them. A plain shell's untold input does not. Once it is empty, it archives.
    @Test func unsentInputHoldsArchive() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .archive)
        let id = world.launched(signal: signal, matched: true, doneAt: world.now)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [OperatorServiceFixtures.session("agent", window: "task-window", tag: id, state: .idle),
                             OperatorServiceFixtures.session("shell", window: "task-window", tag: id, agent: .shell)]
        rig.daemon.inputStates = ["agent": .unsent, "shell": .unknown]
        let script = DoneScript(); script.install(rig)
        await rig.start()
        #expect(script.archives.isEmpty && rig.state.task(id: id) != nil && Self.origin(rig, id)?.thenApplied == nil)
        #expect(rig.daemon.requests("session.inputState").map { $0.params["sessionId"] as? String } == ["agent"])

        rig.daemon.inputStates["agent"] = .unknown
        await Self.tick(rig)
        #expect(script.archives.isEmpty && Self.origin(rig, id)?.thenApplied == nil, "An agent's untold input holds it too.")

        rig.daemon.inputStates["agent"] = .empty
        await Self.tick(rig)
        #expect(script.archives == [id] && rig.state.archived(id: id) != nil && Self.origin(rig, id)?.thenNote == nil)
    }

    /// Remove goes through the app's teardown, told the task may still go while it is unchanged and idle: the row is
    /// gone, not archived, and nothing is left to mark.
    @Test func removeRemovesThroughTheScriptedTeardown() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .remove)
        let id = world.launched(signal: signal)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.facts.doneMatches = true
        await rig.start()

        #expect(script.removes == [id] && script.allowedAtRemove == [true] && script.archives.isEmpty)
        #expect(rig.state.task(id: id) == nil && rig.state.archived(id: id) == nil)
        await Self.tick(rig)
        #expect(script.removes == [id], "Nothing is left to remove again.")
    }

    /// A turn under way when the removal starts (`ClosingWait`) leaves Then pending; the next pass removes.
    @Test func removeIsRetriedAfterAClosingWait() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .remove)
        let id = world.launched(signal: signal, matched: true, doneAt: world.now)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.removeFailures = [ClosingWait.turn]
        await rig.start()
        #expect(Self.origin(rig, id)?.thenApplied == nil && Self.origin(rig, id)?.thenNote == nil && rig.state.task(id: id) != nil)

        await Self.tick(rig)
        #expect(script.removes == [id, id] && rig.state.task(id: id) == nil)
    }

    /// A removal refused for good, unsaved work, lands in `thenNote` with Then finished, is said once, and is not tried
    /// again: the task stays.
    @Test func aRefusedRemovalLandsInThenNoteAndIsNotRetried() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .remove)
        let id = world.launched(signal: signal, matched: true, doneAt: world.now)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.removeFailures = [ActionUnavailable(TaskTeardown.unsavedWork)]
        var said: [String] = []
        rig.root.projectWatch.changed = { _, line in said.append(line) }
        await rig.start()

        #expect(Self.origin(rig, id)?.thenNote == TaskTeardown.unsavedWork && Self.origin(rig, id)?.thenApplied == true)
        #expect(rig.state.task(id: id) != nil && said.filter { $0.hasPrefix("Couldn’t remove ") }.count == 1)
        await Self.tick(rig)
        #expect(script.removes == [id], "Not tried again.")
    }

    /// A signal switched off, or its Then edited, while the teardown checks the worktree takes nothing away: the teardown
    /// is told the task may no longer go, and a refusal then marks nothing.
    @Test(arguments: [false, true]) func aSignalSwitchedOffOrEditedDuringRemovalStopsIt(edited: Bool) async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .remove)
        let id = world.launched(signal: signal, matched: true, doneAt: world.now)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig)
        script.removeFailures = [ActionUnavailable("Its finished record couldn’t be saved, so nothing was removed.")]
        script.duringRemove = { [unowned rig] in
            rig.workspace.mutate { state in
                if edited { state.signals[0].finish.then = .keep } else { state.signals[0].enabled = false }
            }
        }
        await rig.start()

        #expect(script.allowedAtRemove == [false] && rig.state.task(id: id) != nil)
        #expect(Self.origin(rig, id)?.thenApplied == nil && Self.origin(rig, id)?.thenNote == nil)
    }

    /// Remove waits as Archive does: a session at work, then an agent's unsent input, hold it; once both are gone it
    /// removes.
    @Test func workAndUnsentInputHoldRemove() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone, then: .remove)
        let id = world.launched(signal: signal, matched: true, doneAt: world.now)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        rig.live.sessions = [OperatorServiceFixtures.session("agent", window: "task-window", tag: id, state: .working)]
        rig.daemon.inputStates = ["agent": .unsent]
        let script = DoneScript(); script.install(rig)
        await rig.start()
        #expect(script.removes.isEmpty && rig.state.task(id: id) != nil)

        rig.live.sessions = [OperatorServiceFixtures.session("agent", window: "task-window", tag: id, state: .idle)]
        await Self.tick(rig)
        #expect(script.removes.isEmpty && Self.origin(rig, id)?.thenApplied == nil)

        rig.daemon.inputStates["agent"] = .empty
        await Self.tick(rig)
        #expect(script.removes == [id] && rig.state.task(id: id) == nil)
    }

    /// The Operator's pause does not stop a project signal's watch.
    @Test func aPausedOperatorDoesNotStopThePass() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone)
        let id = world.launched(signal: signal)
        world.state.operatorSession = OperatorSession(createdAt: world.now); world.state.operatorSession?.paused = true
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.facts.doneMatches = true
        await rig.start()

        #expect(Self.origin(rig, id)?.doneAt != nil)
    }

    /// A switched-off signal's tasks are not read; once it is back, the first read compares with the last, so a Done
    /// reached meanwhile counts. A removed signal's are never read again.
    @Test func aSwitchedOffSignalStopsThePassAndARemovedOneForGood() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone)
        let removed = world.projectSignal(name: "Old", done: Self.jiraDone)
        let id = world.launched(signal: signal), gone = world.launched(signal: removed)
        world.state.signals[0].enabled = false
        world.state.signals.removeAll { $0.id == removed }
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.facts.doneMatches = true
        await rig.start(); await Self.tick(rig)
        #expect(script.reads.isEmpty && Self.origin(rig, id)?.doneAt == nil)

        rig.workspace.mutate { $0.signals[0].enabled = true }
        await Self.tick(rig)
        #expect(script.reads.map(\.task) == [id] && Self.origin(rig, id)?.doneAt != nil)
        #expect(Self.origin(rig, gone)?.doneAt == nil)
    }

    /// An edited Done no longer names the saved baseline: the next read is a new baseline, a match there is not done,
    /// and a later edge against it is.
    @Test func anEditedDoneMakesTheNextReadABaseline() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone)
        let id = world.launched(signal: signal)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig)
        await rig.start()

        let edited = SignalTrigger(source: .jira, query: "status = Closed")
        rig.workspace.mutate { $0.signals[0].done = edited }
        script.facts.doneMatches = true
        await Self.tick(rig)
        #expect(Self.origin(rig, id)?.doneKey == SignalOrigin.doneKey(edited) && Self.origin(rig, id)?.doneMatched == true)
        #expect(Self.origin(rig, id)?.doneAt == nil && script.reads.last?.done == edited)

        script.facts.doneMatches = false; await Self.tick(rig)
        script.facts.doneMatches = true; await Self.tick(rig)
        #expect(Self.origin(rig, id)?.doneAt != nil)
    }

    /// A failed read is unknown: nothing changes, and the next pass reads again.
    @Test func aFailedReadChangesNothing() async throws {
        var world = SignalWorld(); let signal = world.projectSignal(done: Self.jiraDone)
        let id = world.launched(signal: signal)
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig); script.facts.closed = true
        script.failures = [ActionUnavailable("The host is away.")]
        await rig.start()
        #expect(Self.origin(rig, id)?.doneAt == nil && Self.origin(rig, id)?.doneMatched == false)

        await Self.tick(rig)
        #expect(Self.origin(rig, id)?.doneAt != nil)
    }

    // -- the host's Done facts for a project signal's task ---------------------------------------

    /// With You decide, the task's request is found by its branch (a scheduled run names none) and merged is done; no
    /// query is asked.
    @Test func youDecideFindsTheRequestByItsBranchAndAsksNoQuery() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.launched(signal: signal)
        world.state.updateSignalItem(id) { $0.branch = "work" }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            #expect(request.url!.path != "/api/graphql", "You decide asks no query")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard query.contains(where: { $0.name == "state" && $0.value == "all" }) else { return (200, Data("[]".utf8)) }
            return (200, Data(#"[{"iid":7,"title":"Merged","source_branch":"work","target_branch":"main","web_url":"https://git.example/shop/web/-/merge_requests/7","state":"merged","source_project_id":1,"target_project_id":1}]"#.utf8))
        }
        let io = Self.io(h, stub)
        let task = try #require(h.workspace.state.task(id: id))
        let facts = try await io.doneFacts(for: task, done: SignalTrigger(source: .person, query: ""),
                                           item: .run(SignalRunRef(signal: signal, at: world.now)))
        #expect(facts.merged && !facts.closed && !facts.doneMatches)
    }

    /// A scheduled run's task before its request exists: a GitLab Done query does not match, and nothing is asked.
    @Test func aGitLabDoneBeforeTheRequestExistsDoesNotMatch() async throws {
        var world = SignalWorld(); let signal = world.projectSignal()
        let id = world.launched(signal: signal)
        world.state.updateSignalItem(id) { $0.branch = "work" }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            #expect(request.url!.path != "/api/graphql", "no merge request, nothing to ask")
            return (200, Data("[]".utf8))
        }
        let io = Self.io(h, stub)
        let task = try #require(h.workspace.state.task(id: id))
        let facts = try await io.doneFacts(for: task, done: SignalTrigger(source: .gitLab, query: "reviewer:any"),
                                           item: .run(SignalRunRef(signal: signal, at: world.now)))
        #expect(facts == DoneCheck.Facts())
    }

    /// A later request from the source branch of an earlier review is matched to that review's task by the branch: the
    /// task takes the new request, so its Done reads that one and the earlier request's merged state does not end it.
    @Test func aLaterRequestOnTheSameBranchBecomesTheTasksRequest() async throws {
        var world = SignalWorld()
        let signal = world.projectSignal(start: SignalTrigger(source: .gitLab, query: "reviewer:@me"))
        let rig = try PickupRig(world); defer { rig.cleanUp() }
        await rig.start()
        rig.pass(signal, [ProjectSignalsTests.request(7)], accountUser: "alex"); await rig.settled()
        let id = try #require(rig.state.tasks.first?.id)
        #expect(rig.state.task(id: id)?.mr?.iid == 7)
        rig.workspace.mutate { $0.updateSignalItem(id) { $0.signalOrigin?.doneAt = world.now; $0.signalOrigin?.thenApplied = true } }

        rig.pass(signal, [ProjectSignalsTests.request(8)], accountUser: "alex"); await rig.settled()
        let task = try #require(rig.state.task(id: id))
        let origin = try #require(task.signalOrigin)
        #expect(rig.state.tasks.count == 1 && origin.item == ProjectSignalsTests.request(8).item && origin.doneAt == nil)
        #expect(task.mr?.iid == 8 && task.mr?.url == "https://git.example/shop/web/-/merge_requests/8")

        let stub = StubSession { request in
            let earlier = request.url!.path.hasSuffix("/merge_requests/7")
            let iid = earlier ? 7 : 8, state = earlier ? "merged" : "opened"
            return (200, Data(#"{"iid":\#(iid),"title":"Work","source_branch":"feat/work","target_branch":"main","web_url":"https://git.example/shop/web/-/merge_requests/\#(iid)","state":"\#(state)","source_project_id":1,"target_project_id":1}"#.utf8))
        }
        let facts = try await Self.io(rig.h, stub).doneFacts(for: task, done: SignalTrigger(source: .person, query: ""), item: origin.item)
        #expect(!facts.merged && !facts.closed, "The new request is open: the earlier one's merge does not end it.")
    }

    static func io(_ h: SignalHarness, _ stub: StubSession) -> SignalHostIO {
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { links })
        io.remote = { _, _ in "git@git.example:shop/web.git" }
        return io
    }
}

/// A project signal's Done reads and the app's archive and removal, scripted on a rig's controller: a read answers `facts`
/// (or throws the next of `failures`); an archive throws the next of `archiveFailures`, or moves the row into the
/// archive; a removal throws the next of `removeFailures`, or drops the row.
@MainActor final class DoneScript {
    var facts = DoneCheck.Facts()
    var failures: [any Error] = []
    var archiveFailures: [any Error] = []
    var removeFailures: [any Error] = []
    /// Runs as a removal begins, before it asks whether it is still allowed: the person's change meanwhile.
    var duringRemove: (() -> Void)?
    /// Every read, and whether its task still owed a prompt then.
    private(set) var reads: [(task: UUID, done: SignalTrigger, item: ItemRef, owing: Bool)] = []
    /// Every archive asked for, and whether it was still allowed as it began.
    private(set) var archives: [UUID] = []
    private(set) var allowedAtArchive: [Bool] = []
    /// Every removal asked for, and whether it was still allowed as it began.
    private(set) var removes: [UUID] = []
    private(set) var allowedAtRemove: [Bool] = []

    func install(_ rig: PickupRig) {
        rig.root.doneFacts = { [unowned self] task, done, item in
            self.reads.append((task.id, done, item, task.signalOrigin?.owed != nil))
            if !self.failures.isEmpty { throw self.failures.removeFirst() }
            return self.facts
        }
        rig.root.archive = { [unowned self, unowned rig] task, allowed in
            self.archives.append(task.id); self.allowedAtArchive.append(allowed())
            if !self.archiveFailures.isEmpty { throw self.archiveFailures.removeFirst() }
            rig.workspace.mutate { state in
                state.tasks.removeAll { $0.id == task.id }
                var archived = task; archived.windowId = nil
                state.archive.append(ArchivedTask(task: archived, archivedAt: rig.clock.now))
            }
            rig.workspace.flush()
        }
        rig.root.remove = { [unowned self, unowned rig] task, allowed in
            self.duringRemove?()
            self.removes.append(task.id); self.allowedAtRemove.append(allowed())
            if !self.removeFailures.isEmpty { throw self.removeFailures.removeFirst() }
            rig.workspace.mutate { $0.tasks.removeAll { $0.id == task.id } }
            rig.workspace.flush()
        }
    }
}

extension SignalWorld {
    /// A task `signal` started, whose prompt reached its worker after its baseline was read for the signal's Done.
    @discardableResult mutating func launched(signal: UUID, matched: Bool = false, doneAt: Date? = nil, thenApplied: Bool? = nil) -> UUID {
        let id = markedTask(signal: signal)
        let done = state.signal(id: signal)?.done ?? SignalTrigger(source: .person, query: "")
        let now = now
        state.updateSignalItem(id) { task in
            task.signalOrigin?.doneKey = SignalOrigin.doneKey(done)
            task.signalOrigin?.doneMatched = done.source == .person ? nil : matched
            task.signalOrigin?.doneAt = doneAt; task.signalOrigin?.thenApplied = thenApplied
            task.signalOrigin?.turn = SignalTurn(sentAt: now)
        }
        return id
    }
}
