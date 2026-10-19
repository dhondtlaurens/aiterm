import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The Oracle's challenge: a challenged call does not take effect on its first call; the Operator
/// reads the critique and calls again, and only that call acts, logged with the critique.
@MainActor @Suite struct OperatorChallengeTests {
    let project = OperatorServiceFixtures.project()

    /// `budget` is generous by default: a critique that is ready answers at once, and a whole-suite run
    /// can keep the main actor busy for seconds. The pending path names a short one.
    func makeWorld(oracle: Bool = true, runner: SecondOpinionRunner, budget: Duration = .seconds(60)) async throws -> (OperatorWorld, OperatorRun) {
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: oracle, oracleAgent: .claude), projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { ports in
            ports.secondOpinion = runner
            ports.challengeReplyBudget = budget
        }
        _ = await world.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "Do A.", "project": "Shop", "agent": "claude", "model": "m"])
        return (world, run)
    }

    @Test func theOracleChallengesAPlanAndOnlyTheCallAfterTheCritiqueSubmitsIt() async throws {
        let (world, run) = try await makeWorld(runner: .answering("A is two tasks."))
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(first.value?["challenged"] == true && first.value?["critique"] == "A is two tasks.")
        #expect(world.run(run.id)?.planRevision == 0)
        let id = try #require(first.value?["challengeId"]?.stringValue)
        let second = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "A is one change."])
        #expect(second.value?["submitted"] == true && world.run(run.id)?.planRevision == 1)
        let decision = try #require(world.run(run.id)?.decisions.last)
        #expect(decision.challenge == "A is two tasks." && decision.text == "submit_plan: A is one change.")
        // The acting call again — its reply lost — answers what it answered, and acts no further.
        let decisions = world.run(run.id)?.decisions.count
        #expect(await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "A is one change."]) == second)
        #expect(world.run(run.id)?.decisions.count == decisions && world.run(run.id)?.planRevision == 1)
        #expect(await world.call(run.id, "submit_plan", ["revision": 2, "challengeId": .string(id)]).message?
                .hasPrefix("Challenge \(id) has already acted") == true)
        #expect(await world.call(run.id, "mark_task", ["task": "A", "outcome": "accepted", "challengeId": .string(id)])
                .message?.hasPrefix("No challenge") == true)
    }

    /// The challenge is on disk before the acting call's reply: after AiTerm restarts, the call repeated
    /// answers the same and changes nothing (spec §11).
    @Test func anActedChallengeIsReplayedAfterARestart() async throws {
        let (world, run) = try await makeWorld(runner: .answering("A is two tasks."))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        let acted = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "One change."])
        let saved = try world.workspace.file.load()
        #expect(saved.run(id: run.id)?.challenges.map(\.stage) == [.acted])
        let restarted = try OperatorWorld(saved)
        #expect(await restarted.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "One change."]) == acted)
        #expect(restarted.run(run.id)?.planRevision == 1 && restarted.run(run.id)?.decisions.count == saved.run(id: run.id)?.decisions.count)
    }

    /// A second opinion lost with AiTerm's restart never holds the act up: its next call proceeds, unchallenged.
    @Test func aChallengeStillRunningWhenAiTermQuitProceedsUnchallenged() async throws {
        let (world, run) = try await makeWorld(runner: .answering("Late.", after: .seconds(2)), budget: .milliseconds(20))
        defer { world.controller.tools.cancelChallenges() }
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        #expect(world.workspace.flush())
        let restarted = try OperatorWorld(try world.workspace.file.load())
        #expect(await restarted.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)]).value?["submitted"] == true)
        #expect(restarted.run(run.id)?.decisions.last?.challenge == "unchallenged: AiTerm restarted before the second opinion answered.")
    }

    @Test func withTheOracleOffTheCallActsAtOnce() async throws {
        let (world, run) = try await makeWorld(oracle: false, runner: .answering("never asked"))
        #expect(await world.call(run.id, "submit_plan", ["revision": 1]).value?["submitted"] == true)
    }

    @Test func aSecondOpinionThatCannotRunLetsTheActProceedUnchallenged() async throws {
        let (world, run) = try await makeWorld(runner: .unavailable)
        #expect(await world.call(run.id, "submit_plan", ["revision": 1]).value?["submitted"] == true)
        #expect(world.run(run.id)?.decisions.last?.challenge == "unchallenged: claude isn’t installed.")
    }

    @Test func aSlowCritiqueIsPendingThenReadThenActedOn() async throws {
        let (world, run) = try await makeWorld(runner: .answering("Too broad.", after: .milliseconds(300)), budget: .milliseconds(20))
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(first.value?["pending"] == true && first.value?["critique"] == .null)
        let id = try #require(first.value?["challengeId"]?.stringValue)
        await world.controller.tools.lastChallenge?.value
        let read = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)])
        #expect(read.value?["critique"] == "Too broad." && world.run(run.id)?.planRevision == 0)
        _ = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "Narrowed."])
        #expect(world.run(run.id)?.planRevision == 1)
    }

    /// With the Oracle on, what round 1's Healthy doubt challenged; with it off, nothing.
    @Test func whichCallsTheOracleChallenges() {
        func call(_ tool: String, _ arguments: JSONValue = [:]) -> ToolCall { ToolCall(tool: tool, arguments: arguments) }
        #expect(OperatorToolHandler.isChallenged(call("submit_plan"), oracleIsOn: true, answersQuestion: false))
        #expect(OperatorToolHandler.isChallenged(call("mark_task", ["outcome": "accepted"]), oracleIsOn: true, answersQuestion: false))
        #expect(!OperatorToolHandler.isChallenged(call("mark_task", ["outcome": "noChange"]), oracleIsOn: true, answersQuestion: false))
        #expect(!OperatorToolHandler.isChallenged(call("message_task"), oracleIsOn: true, answersQuestion: false), "steering mid-turn is not")
        #expect(OperatorToolHandler.isChallenged(call("message_task"), oracleIsOn: true, answersQuestion: true))
        #expect(!OperatorToolHandler.isChallenged(call("create_task"), oracleIsOn: true, answersQuestion: false))
        #expect(!OperatorToolHandler.isChallenged(call("propose_lesson"), oracleIsOn: true, answersQuestion: false))
        #expect(!OperatorToolHandler.isChallenged(call("submit_plan"), oracleIsOn: false, answersQuestion: false))
        #expect(!OperatorToolHandler.isChallenged(call("message_task"), oracleIsOn: false, answersQuestion: true))
    }

    /// AiTerm quitting cancels a second opinion: that is not an answer, so the act is not recorded as
    /// unchallenged then. Its record stays running, and the next call proceeds unchallenged with the restart's reason.
    @Test func aChallengeCancelledByQuittingIsNotRecordedAsUnchallenged() async throws {
        let (world, run) = try await makeWorld(runner: .answering("Late.", after: .seconds(30)), budget: .milliseconds(20))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        world.controller.tools.cancelChallenges()
        await world.controller.tools.lastChallenge?.value
        #expect(world.run(run.id)?.challenges.map(\.stage) == [.running])
        #expect(world.run(run.id)?.challenges.first?.unchallengedReason == nil && world.controller.tools.runningChallenges.isEmpty)
        #expect(await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)]).value?["submitted"] == true)
        #expect(world.run(run.id)?.decisions.last?.challenge == "unchallenged: AiTerm restarted before the second opinion answered.")
    }

    @Test func aCritiqueIsCappedAtEightKilobytes() async throws {
        let (world, run) = try await makeWorld(runner: .answering(String(repeating: "é", count: 20_000)))
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        let critique = try #require(first.value?["critique"]?.stringValue)
        #expect(critique.utf8.count <= OperatorToolHandler.critiqueLimit + 64 && critique.hasSuffix(OperatorToolHandler.truncationMarker))
        #expect(world.run(run.id)?.challenges.first?.critique == critique)
    }

    @Test func theSameChallengeIdWithOtherArgumentsIsRefused() async throws {
        let (world, run) = try await makeWorld(runner: .answering("Fine."))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        _ = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)])
        #expect(await world.call(run.id, "submit_plan", ["revision": 1, "extra": true, "challengeId": .string(id)]).message?
                .hasPrefix("Challenge \(id) has already acted") == true)
    }

    /// An active run with one working task, a tab for its worker, and `message_task` under Healthy doubt.
    func makeWorkerWorld(daemon: RecordingDaemon = RecordingDaemon()) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: true, oracleAgent: .claude), projects: [project], state: .active)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "W-1", state: .working, worktree: "/tmp/aiterm-operators-none/w1")
        task.operated?.ownership = 3
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon) { ports in
            ports.secondOpinion = .answering("Ask first.")
            ports.challengeReplyBudget = .seconds(60)
        }
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        return (world, run, task)
    }

    func message(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["task": "W-1", "text": "Use nl-BE."].merging(extra) { $1 })
    }

    /// The acting call's reply is lost after it delivered and the worker went back to work: the tab no longer says
    /// the message answers a question, yet the call repeated replays and delivers nothing more.
    @Test func aMessageThatAnsweredAQuestionIsNotDeliveredAgainWhenRepeatedWhileTheWorkerWorks() async throws {
        let (world, run, task) = try makeWorkerWorld()
        let first = await world.call(run.id, "message_task", message())
        #expect(first.value?["challenged"] == true && world.daemon.requests("session.deliver").isEmpty)
        let id = try #require(first.value?["challengeId"]?.stringValue)
        let acting = message(["challengeId": .string(id), "challengeReply": "Agreed."])
        let acted = await world.call(run.id, "message_task", acting)
        #expect(acted.value?["result"] == "delivered" && world.daemon.requests("session.deliver").count == 1)
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .working)])
        let decisions = world.run(run.id)?.decisions.count
        #expect(await world.call(run.id, "message_task", acting) == acted)
        #expect(world.daemon.requests("session.deliver").count == 1 && world.run(run.id)?.decisions.count == decisions)
    }

    /// The worker starts working between the critique and the acting call: the call still acts as the challenge's,
    /// with the critique logged.
    @Test func aWorkerThatStartsWorkingBeforeTheActingCallStillLogsTheCritique() async throws {
        let (world, run, task) = try makeWorkerWorld()
        let id = try #require(await world.call(run.id, "message_task", message()).value?["challengeId"]?.stringValue)
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .working)])
        let acted = await world.call(run.id, "message_task", message(["challengeId": .string(id)]))
        #expect(acted.value?["result"] == "delivered")
        #expect(world.run(run.id)?.decisions.last?.challenge == "Ask first.")
        #expect(world.run(run.id)?.challenges.map(\.stage) == [.acted])
    }

    /// A second call for a challenge that is mid-act is refused, not performed too: held at the daemon, no sleeps.
    @Test func aSecondCallForAChallengeThatIsActingIsRefusedAndItsMarkIsClearedAfterwards() async throws {
        let daemon = RecordingDaemon(holding: "session.deliver")
        let (world, run, _) = try makeWorkerWorld(daemon: daemon)
        let id = try #require(await world.call(run.id, "message_task", message()).value?["challengeId"]?.stringValue)
        let acting = message(["challengeId": .string(id)])
        let sending = Task { await world.call(run.id, "message_task", acting) }
        try await daemon.received("session.deliver")
        #expect(await world.call(run.id, "message_task", acting).message
                == "Challenge \(id) is already acting on message_task; call again for its result.")
        #expect(daemon.requests("session.deliver").count == 1)
        daemon.release()
        let acted = await sending.value
        #expect(acted.value?["result"] == "delivered" && world.controller.tools.actingChallenges.isEmpty)
        #expect(await world.call(run.id, "message_task", acting) == acted && daemon.requests("session.deliver").count == 1)
    }
}
