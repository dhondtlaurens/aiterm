import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

private actor ReviewGate {
    private var held: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { held = $0; entered?.resume(); entered = nil } }
    func started() async { if held == nil { await withCheckedContinuation { entered = $0 } } }
    func release() { held?.resume(); held = nil }
}

private final class ReviewGit: GitRunning, @unchecked Sendable {
    let reads = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        reads.continuation.yield(())
        release.wait()
        return "new-sha"
    }
}

@MainActor @Suite struct OperatorReviewTests {
    let project = OperatorServiceFixtures.project()

    func fixture(_ daemon: RecordingDaemon = RecordingDaemon(), git: any GitRunning = GitRunner.hermetic(),
                 adjust: (inout OperatorPorts) -> Void = { _ in }) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .working)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon,
                                      git: git, adjust: adjust)
        world.live.sessions = [OperatorServiceFixtures.session("worker", tag: task.id)]
        return (world, run, task)
    }

    @Test func deliveredMessagesReplayForTenMinutes() async throws {
        let clock = StepClock()
        let (world, run, _) = try fixture { $0.now = { clock.now } }
        let args: JSONValue = ["task": "A", "text": "Continue"]
        let first = await world.call(run.id, "message_task", args)
        clock.advance(by: 599)
        #expect(await world.call(run.id, "message_task", args) == first)
        #expect(world.daemon.requests("session.deliver").count == 1)
        _ = await world.call(run.id, "message_task", ["task": "A", "text": "Different"])
        #expect(world.daemon.requests("session.deliver").count == 2)
        clock.advance(by: 1)
        _ = await world.call(run.id, "message_task", args)
        #expect(world.daemon.requests("session.deliver").count == 3)
    }

    @Test(arguments: [OperatorRunState.paused, .stopped], ["message_task", "submit_plan"])
    func aChallengeReloadsTheRun(_ changed: OperatorRunState, _ tool: String) async throws {
        let gate = ReviewGate()
        let runner = SecondOpinionRunner(locate: { _ in "/fake" }, run: { _, _, _, _, _ in
            await gate.wait()
            throw CancellationError()
        })
        let (world, run, _) = try fixture { $0.secondOpinion = runner; $0.challengeReplyBudget = .seconds(3600) }
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.profile.oracle.isOn = true } }
        let arguments: JSONValue = tool == "message_task" ? ["task": "A", "text": "Continue"] : ["revision": 1]
        let call = Task { await world.call(run.id, tool, arguments) }
        await gate.started()
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.state = changed; $0.intent = changed } }
        await gate.release()
        #expect(await call.value.message != nil)
        #expect(world.daemon.requests("session.deliver").isEmpty)
        #expect(world.run(run.id)?.planRevision == 0)
    }

    @Test(arguments: [0, 1, 2, 3], ["pause", "end", "takeover", "handback", "state"])
    func reacceptRechecksAfterEachRead(_ read: Int, _ change: String) async throws {
        let git = ReviewGit()
        let (world, run, task) = try fixture(git: git) { $0.milestone = .m3 }
        var parent = OperatorServiceFixtures.task(in: run, project: project, key: "parent", state: .accepted)
        parent.operated?.acceptance = TaskAcceptance(resultSHA: "parent-sha", prerequisiteSHAs: [], checkOutput: "ok", note: nil,
                                                    at: Date(timeIntervalSince1970: 0))
        world.workspace.mutate { $0.tasks.append(parent) }
        world.workspace.mutate { $0.updateOperated(task.id) {
            $0.dependsOn = [TaskDependency(task: parent.id, kind: .code)]
            $0.flags.insert(.upstreamReplaced)
            $0.state = .accepted
            $0.acceptance = TaskAcceptance(resultSHA: "old-sha", prerequisiteSHAs: [], checkOutput: "ok", note: nil, at: Date(timeIntervalSince1970: 0))
        } }
        let call = Task { await world.call(run.id, "mark_task", ["task": "A", "outcome": "accepted", "sha": "new-sha", "checkOutput": "ok"]) }
        var iterator = git.reads.stream.makeAsyncIterator()
        // Repeat check, requested SHA, branch tip, then upstream ancestry.
        for index in 0...read { _ = await iterator.next(); if index < read { git.release.signal() } }
        world.workspace.mutate { state in
            switch change {
            case "pause": state.updateRun(id: run.id) { $0.state = .paused; $0.intent = .paused }
            case "end": state.updateRun(id: run.id) { $0.state = .stopped; $0.intent = .stopped }
            case "takeover": state.updateOperated(task.id) { $0.takenOver = true; $0.ownership += 1 }
            case "handback": state.updateOperated(task.id) { $0.ownership += 2 }
            default: state.updateOperated(task.id) { $0.state = .stopped }
            }
        }
        for _ in 0..<5 { git.release.signal() }
        #expect(await call.value.message != nil)
        #expect(world.task(task.id)?.operated?.acceptance?.resultSHA == "old-sha")
    }

    @Test(arguments: [DaemonError.Code.timeout, .disconnected, .itermUnavailable])
    func anUnknownWindowFateKeepsTheRun(_ code: DaemonError.Code) async throws {
        let daemon = RecordingDaemon(failing: ["window.createTask": code])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []), daemon: daemon)
        _ = try? await world.controller.startOperation(profile: OperatorServiceFixtures.profile(), prompt: "Work", done: nil)
        let run = try #require(world.state.runs.first)
        #expect(run.state == .operatorOffline)
        #expect(daemon.requests("operator.revoke").isEmpty)
        let folder = OperatorCommand.runFolder(run.id, home: world.ports.home)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(OperatorCommand.tokenFile).path))
        #expect(try world.workspace.file.load().run(id: run.id) != nil)
        world.show([OperatorServiceFixtures.session("operator", window: "late", tag: run.id)])
        #expect(world.run(run.id)?.operatorWindowId == "late")
    }

    @Test func anExternalUpdateDuringDeliveryStillWakes() async throws {
        let daemon = RecordingDaemon(holding: "session.deliver")
        let requests = AsyncStream<String>.makeStream()
        daemon.onRequest = { requests.continuation.yield($0) }
        var request = requests.stream.makeAsyncIterator()
        let gate = ReviewGate()
        let (world, run, _) = try fixture(daemon) { $0.wakeSleep = { _ in await gate.wait() } }
        world.live.sessions.append(OperatorServiceFixtures.session("operator", tag: run.id, state: .working))
        _ = await world.call(run.id, "run_status")
        let call = Task { await world.call(run.id, "message_task", ["task": "A", "text": "Continue"]) }
        #expect(await request.next() == "session.deliver")
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.questions.append(OperatorServiceFixtures.question()) } }
        await gate.started()
        daemon.release()
        _ = await call.value
        world.live.sessions[1].state = .idle
        await gate.release()
        await world.controller.waker.lastCoalesce?.value
        await world.controller.waker.lastSend?.value
        #expect(daemon.requests("session.deliver").contains { $0.params["wake"] as? Bool == true })
    }

    @Test func aShellWindowStaysUncertainUntilAWorkerAppears() throws {
        let (world, _, task) = try fixture()
        world.workspace.mutate { $0.updateOperated(task.id) {
            $0.launch = LaunchAttempt(number: 2, requestedAt: Date(timeIntervalSince1970: 0))
            $0.retriesUsed = 1
        } }
        world.live.sessions = [OperatorServiceFixtures.session("shell", window: "existing", tag: task.id, agent: .shell)]
        var notices = 0
        world.controller.starter.onUncertain = { _ in notices += 1 }
        world.controller.starter.recordWindow("existing", of: task.id)
        #expect(world.task(task.id)?.operated?.flags.contains(.uncertain) == true)
        world.controller.starter.recordWindow("existing", of: task.id)
        world.controller.starter.tabsListed(world.live.sessions)
        #expect(notices == 1)
        world.live.sessions[0].agent = .claude
        world.controller.starter.tabsListed(world.live.sessions)
        #expect(world.task(task.id)?.operated?.flags.contains(.uncertain) == false)
        #expect(notices == 1)
        #expect(world.daemon.requests("session.deliver").isEmpty)
    }

    @Test func knownRecordsKeepNewerFields() throws {
        let (_, run, task) = try fixture()
        func roundTrip<T: Codable>(_ value: T) throws {
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            let extra: [String: Any] = ["nested": [1, true, "future", NSNull()] as [Any]]
            json["futureField"] = extra
            let decoded = try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
            let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
            #expect((saved["futureField"] as? NSDictionary) == (extra as NSDictionary))
        }
        try roundTrip(task)
        try roundTrip(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        try roundTrip(run)
        try roundTrip(try #require(task.operated))
        try roundTrip(TaskPublication())
    }
}
