import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct OperatorLifecycleTests {
    @Test func cancellingAPassDropsItsRemainingReadsAndKeepsAReplacementOwned() async {
        let pass = TickPass(), oldGate = SleepGate(), newGate = SleepGate()
        let old = UUID(), skipped = UUID(), replacement = UUID()
        var read: [UUID] = []
        pass.run([old, skipped]) { id in read.append(id); await oldGate.wait(.zero) }
        let original = pass.last
        await eventually { oldGate.asked.count == 1 }
        pass.cancel()
        pass.run([replacement]) { id in read.append(id); await newGate.wait(.zero) }
        let current = pass.last
        await eventually { newGate.asked.count == 1 }
        oldGate.open()
        await original?.value
        pass.run([UUID()]) { read.append($0) }
        #expect(read == [old, replacement], "The old completion cannot release the new pass's slot")
        newGate.open()
        await current?.value
    }

    @Test func stoppingDropsSummaryWaitsAndLateCallbacksCannotCompleteTheRun() async throws {
        let project = OperatorServiceFixtures.project(), gate = SleepGate()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) {
            $0.clock.overrideSleep(.summary) { await gate.wait($0) }
        }
        try world.controller.stop(task: task.id)
        let wait = world.controller.summaryWait
        await eventually { gate.asked.count == 1 }
        world.controller.stop()
        gate.open()
        await wait?.value
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
        let pending = waker.lastCoalesce
        waker.stop()
        hand.releaseAll()
        await pending?.value
        waker.say("broadcast complete", to: run.id)
        waker.operatorSessionChanged(run.id)
        #expect(lines.isEmpty)
        waker.start()
        waker.say("operation complete", to: run.id)
        await hand.release(2)
        await waker.lastCoalesce?.value
        await waker.lastSend?.value
        #expect(lines == ["[AiTerm] operation complete, call run_status"])
    }
}

extension WorkerTurnReaderTests {
    @Test func stoppingDiscardsAnOutstandingTurnReading() async throws {
        let (world, _, task, _) = try makeWorld(worker: .idle)
        let reading = world.controller.turns.lastRead
        world.controller.stop()
        await reading?.value
        #expect(world.controller.turns.readings[task.id] == nil)
    }
}
