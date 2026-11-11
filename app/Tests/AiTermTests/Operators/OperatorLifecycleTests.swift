import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct OperatorLifecycleTests {
    @Test func cancellingAPassDropsItsRemainingReadsAndKeepsAReplacementOwned() async {
        let work = OperatorWork(), pass = TickPass(work: work), oldGate = SleepGate(), newGate = SleepGate()
        let old = UUID(), skipped = UUID(), replacement = UUID()
        var read: [UUID] = []
        pass.run([old, skipped]) { id in read.append(id); await oldGate.wait(.zero) }
        await eventually { oldGate.asked.count == 1 }
        pass.cancel()
        pass.run([replacement]) { id in read.append(id); await newGate.wait(.zero) }
        await eventually { newGate.asked.count == 1 }
        oldGate.open()
        // The old pass ends; the replacement is still held.
        await work.settled(leaving: 1)
        pass.run([UUID()]) { read.append($0) }
        #expect(read == [old, replacement], "The old completion cannot release the new pass's slot")
        newGate.open()
        await work.settled()
    }

    @Test func stoppingDropsSummaryWaitsAndLateCallbacksCannotCompleteTheRun() async throws {
        let project = OperatorServiceFixtures.project(), gate = SleepGate()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) {
            $0.clock.overrideSleep(.summary) { await gate.wait($0) }
        }
        try world.controller.stop(task: task.id)
        await eventually { gate.asked.count == 1 }
        world.controller.stop()
        gate.open()
        await world.settled()
        #expect(world.controller.summaryWaits.isEmpty)
        #expect(world.run(run.id)?.summaryGivenUp == false)
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.state = .active } }
        world.controller.runChanged(run.id)
        #expect(world.run(run.id)?.state == .active, "A stopped runtime ignores callbacks from old jobs")
    }
}

extension OperatorWakerTests {
    @Test func stoppingDropsCoalescedNewsAndRestartOnlySendsFreshNews() async throws {
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        waker.say("reconnected", to: run.id)
        await hand.started(1)
        waker.stop()
        hand.releaseAll()
        await work.settled()
        waker.say("broadcast complete", to: run.id)
        waker.operatorSessionChanged(run.id)
        #expect(lines.isEmpty)
        waker.start()
        waker.say("operation complete", to: run.id)
        await hand.release(2)
        await work.settled()
        #expect(lines == ["[AiTerm] operation complete, call run_status"])
    }
}

extension WorkerTurnReaderTests {
    @Test func stoppingDiscardsAnOutstandingTurnReading() async throws {
        let (world, _, task, _) = try makeWorld(worker: .idle)
        world.controller.stop()
        await world.settled()
        #expect(world.controller.turns.readings[task.id] == nil)
    }
}

// -- Stop ends everything the runtime started (plan 2026-11-10, phase 5: Stop left pause notes, the closing sweep and
// replaced registrations running) --------------------------------------------------------------------------------

extension RunControlsTests {
    /// Stop ends the pause notes still to be typed: the one the helper holds lands as it may, and none follows it.
    @Test func stoppingEndsThePauseNotesStillToBeTyped() async throws {
        let (world, run, _) = try pausingWorld(daemon: RecordingDaemon(holding: "session.deliver"))
        try world.controller.pause(run: run.id)
        try await world.daemon.received("session.deliver")
        world.controller.stop()
        world.daemon.release()
        await world.settled()
        #expect(notes(world) == ["w2: pause"], "no note after Stop")
    }
}

extension OperatorLifecycleTests {
    /// Stop ends the closing of ended broadcasts' windows after an attach: the close the helper holds lands as it may, and
    /// no other window is closed after it.
    @Test func stoppingEndsTheClosingOfEndedBroadcastsWindows() async throws {
        let project = OperatorServiceFixtures.project()
        var first = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        var second = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        first.intent = .stopped
        second.intent = .stopped
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [first, second]),
                                      daemon: RecordingDaemon(holding: "window.close"))
        world.controller.daemonAttached()
        world.show([OperatorServiceFixtures.session("op1", window: "w1", tag: first.id),
                    OperatorServiceFixtures.session("op2", window: "w2", tag: second.id)])
        try await world.daemon.received("window.close")
        world.controller.stop()
        world.daemon.release()
        await world.settled()
        #expect(world.daemon.requests("window.close").count == 1, "no window closed after Stop")
    }

    /// Stop ends a registration of the runs' tokens that a later attach replaced: neither goes on once the helper
    /// answers the registration it holds.
    @Test func stoppingEndsARegistrationALaterAttachReplaced() async throws {
        let project = OperatorServiceFixtures.project()
        let open = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var ended = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        ended.intent = .stopped
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [open, ended]),
                                      daemon: RecordingDaemon(holding: "operator.register"))
        for run in [open, ended] {
            _ = try OperatorCommand.prepare(run: run, projects: [project], home: world.ports.home, token: OperatorCommand.makeToken())
        }
        world.controller.daemonAttached()
        try await world.daemon.received("operator.register")
        world.controller.daemonAttached()
        try await world.daemon.received("operator.register", count: 2)
        world.controller.stop()
        world.daemon.release()
        await world.settled()
        #expect(world.daemon.requests("operator.revoke").isEmpty, "no token revoked after Stop")
    }
}
