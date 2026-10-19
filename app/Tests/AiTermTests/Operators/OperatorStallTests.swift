import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Possibly stalled with several workers at work, as the controller runs it: each task on its own clock.
@MainActor @Suite(.blocking) struct OperatorStallTests {
    let clock = StepClock()

    @Test func aQuietWorkerIsFlaggedOnceBesideABusyOneAndClearedByItsNextSign() async throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project],
                                              state: .active, planRevision: 1)
        var busy = OperatorServiceFixtures.task(in: run, project: project, key: "BUSY-1", state: .working, worktree: "/tmp/aiterm-wt-busy")
        var quiet = OperatorServiceFixtures.task(in: run, project: project, key: "QUIET-1", state: .working, worktree: "/tmp/aiterm-wt-quiet")
        busy.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now)
        quiet.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [busy, quiet])) { [clock] ports in
            ports.now = { clock.now }
        }

        /// The operator's tab, idle so a wake line reaches it, and the two workers' tabs with these titles.
        func tabs(busy busyTitle: String, quiet quietTitle: String) -> [SessionInfo] {
            var a = OperatorServiceFixtures.session("a", window: "wb", tag: busy.id, state: .working)
            a.title = busyTitle
            var b = OperatorServiceFixtures.session("b", window: "wq", tag: quiet.id, state: .working)
            b.title = quietTitle
            return [OperatorServiceFixtures.session("op", window: "wo", tag: run.id), a, b]
        }
        func stalledLines() -> [String] {
            world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }.filter { $0.contains("may be stalled") }
        }

        world.show(tabs(busy: "reading", quiet: "reading"))
        clock.advance(by: 15 * 60)
        world.show(tabs(busy: "editing", quiet: "reading"))
        clock.advance(by: 6 * 60)
        world.controller.reconcileTick()
        #expect(world.task(quiet.id)?.operated?.flags.contains(.possiblyStalled) == true)
        #expect(world.task(busy.id)?.operated?.flags.contains(.possiblyStalled) == false)
        #expect(await eventually(describing: "the operator told") { stalledLines() == ["[AiTerm] QUIET-1 may be stalled — call run_status"] })

        world.controller.reconcileTick()
        // A second line would be armed with no coalescing delay and typed within a few turns of the main actor.
        for _ in 0..<50 { await Task.yield() }
        await world.controller.waker.lastSend?.value
        #expect(stalledLines().count == 1, "told once")

        world.show(tabs(busy: "editing", quiet: "editing"))
        world.controller.reconcileTick()
        #expect(world.task(quiet.id)?.operated?.flags.contains(.possiblyStalled) == false)
    }
}
