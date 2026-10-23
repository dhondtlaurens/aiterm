import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The sidebar's Notice when the Operator's wake line is refused (`OperatorController.wakeNotice`): shown on a
/// refusal with what waits on the Operator and why, and taken down by the Operator's `run_status`. That a prompt waiting on
/// the person is never reported, and a later line that lands clears it too, is the waker's (`OperatorWakerTests`).
@MainActor @Suite struct OperatorWakeNoticeTests {
    let project = OperatorServiceFixtures.project()
    static let unrecognised = Delivery(result: .refused, reason: "unrecognised screen", code: .unrecognisedScreen)

    /// A broadcast whose two working tasks wait for the Operator to accept them, its Operator idle in its tab, and the
    /// daemon answering wake lines with `deliveries`, in order.
    func world(_ deliveries: [Delivery]) throws -> (OperatorWorld, OperatorRun) {
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        let tasks = ["PAY-1", "PAY-2"].map { OperatorServiceFixtures.task(in: run, project: project, key: $0, state: .working) }
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: tasks))
        world.daemon.deliveries = deliveries
        world.show([OperatorServiceFixtures.session("op", tag: run.id)]
                   + tasks.enumerated().map { OperatorServiceFixtures.session("w\($0.offset)", window: "w\($0.offset + 2)", tag: $0.element.id) })
        return (world, run)
    }

    /// Wakes the Operator once, and waits for the daemon's answer.
    func wake(_ world: OperatorWorld, _ run: OperatorRun, count: Int = 1) async throws {
        world.controller.waker.say("reconnected", to: run.id)
        try await world.daemon.received("session.deliver", count: count)
        await world.controller.waker.lastSend?.value
    }

    @Test func aRefusedWakeLineShowsWhatWaitsOnTheOperatorAndWhy() async throws {
        let (world, run) = try world([Self.unrecognised])
        try await wake(world, run)
        let notice = try #require(world.controller.wakeNotice)
        #expect(notice.run == run.id)
        #expect(notice.description == "2 tasks ready to accept in “Sprint 42”. Its tab doesn’t show Claude Code’s input box.")
    }

    @Test func theOperatorCallingRunStatusTakesItDown() async throws {
        let (world, run) = try world([Self.unrecognised])
        try await wake(world, run)
        #expect(world.controller.wakeNotice != nil)
        _ = await world.call(run.id, "run_status")
        #expect(world.controller.wakeNotice == nil)
    }
}
