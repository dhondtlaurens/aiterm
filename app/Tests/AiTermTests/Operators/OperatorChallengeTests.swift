import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Second opinion (spec §4.4): a challenged call does not take effect on its first call; the operator
/// reads the critique and calls again, and only that call acts, logged with the critique.
@MainActor @Suite struct OperatorChallengeTests {
    let project = OperatorServiceFixtures.project()

    /// `budget` is generous by default: a critique that is ready answers at once, and a whole-suite run
    /// can keep the main actor busy for seconds. The pending path names a short one.
    func makeWorld(_ level: SecondOpinionLevel, runner: SecondOpinionRunner, budget: Duration = .seconds(60)) async throws -> (OperatorWorld, OperatorRun) {
        var persona = OperatorServiceFixtures.persona(autonomy: .handsOff, level: level)
        persona.secondOpinion.agent = .claude
        let run = OperatorServiceFixtures.run(persona, projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { ports in
            ports.secondOpinion = runner
            ports.challengeReplyBudget = budget
        }
        _ = await world.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "Do A.", "project": "Shop", "agent": "claude", "model": "m"])
        return (world, run)
    }

    @Test func healthyDoubtChallengesAPlanAndOnlyTheCallAfterTheCritiqueSubmitsIt() async throws {
        let (world, run) = try await makeWorld(.healthyDoubt, runner: .answering("A is two tasks."))
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
        #expect(await world.call(run.id, "propose_lesson", ["key": "l", "lesson": "x", "because": "y", "challengeId": .string(id)])
                .message?.hasPrefix("No challenge") == true)
    }

    /// The challenge is on disk before the acting call's reply: after AiTerm restarts, the call repeated
    /// answers the same and changes nothing (spec §11).
    @Test func anActedChallengeIsReplayedAfterARestart() async throws {
        let (world, run) = try await makeWorld(.healthyDoubt, runner: .answering("A is two tasks."))
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
        let (world, run) = try await makeWorld(.healthyDoubt, runner: .answering("Late.", after: .seconds(2)), budget: .milliseconds(20))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        #expect(world.workspace.flush())
        let restarted = try OperatorWorld(try world.workspace.file.load())
        #expect(await restarted.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)]).value?["submitted"] == true)
        #expect(restarted.run(run.id)?.decisions.last?.challenge == "unchallenged: AiTerm restarted before the second opinion answered.")
    }

    @Test func noSelfDoubtActsAtOnce() async throws {
        let (world, run) = try await makeWorld(.noSelfDoubt, runner: .answering("never asked"))
        #expect(await world.call(run.id, "submit_plan", ["revision": 1]).value?["submitted"] == true)
    }

    @Test func aSecondOpinionThatCannotRunLetsTheActProceedUnchallenged() async throws {
        let (world, run) = try await makeWorld(.healthyDoubt, runner: .unavailable)
        #expect(await world.call(run.id, "submit_plan", ["revision": 1]).value?["submitted"] == true)
        #expect(world.run(run.id)?.decisions.last?.challenge == "unchallenged: claude isn’t installed.")
    }

    @Test func aSlowCritiqueIsPendingThenReadThenActedOn() async throws {
        let (world, run) = try await makeWorld(.healthyDoubt, runner: .answering("Too broad.", after: .milliseconds(300)), budget: .milliseconds(20))
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(first.value?["pending"] == true && first.value?["critique"] == .null)
        let id = try #require(first.value?["challengeId"]?.stringValue)
        await world.controller.tools.lastChallenge?.value
        let read = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)])
        #expect(read.value?["critique"] == "Too broad." && world.run(run.id)?.planRevision == 0)
        _ = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "Narrowed."])
        #expect(world.run(run.id)?.planRevision == 1)
    }

    @Test func whichCallsEachStopChallenges() {
        func call(_ tool: String, _ arguments: JSONValue = [:]) -> ToolCall { ToolCall(tool: tool, arguments: arguments) }
        #expect(OperatorToolHandler.isChallenged(call("mark_task", ["outcome": "accepted"]), level: .healthyDoubt, answersQuestion: false))
        #expect(!OperatorToolHandler.isChallenged(call("mark_task", ["outcome": "noChange"]), level: .healthyDoubt, answersQuestion: false))
        #expect(OperatorToolHandler.isChallenged(call("propose_lesson"), level: .healthyDoubt, answersQuestion: false))
        #expect(!OperatorToolHandler.isChallenged(call("message_task"), level: .healthyDoubt, answersQuestion: false))
        #expect(OperatorToolHandler.isChallenged(call("message_task"), level: .healthyDoubt, answersQuestion: true))
        #expect(OperatorToolHandler.isChallenged(call("message_task"), level: .impostor, answersQuestion: false))
        #expect(!OperatorToolHandler.isChallenged(call("create_task"), level: .impostor, answersQuestion: false))
        #expect(!OperatorToolHandler.isChallenged(call("submit_plan"), level: .noSelfDoubt, answersQuestion: false))
    }

    /// AiTerm quitting cancels a second opinion: that is not an answer, so the act is not recorded as
    /// unchallenged then. Its record stays running, and the next call proceeds unchallenged with the restart's reason.
    @Test func aChallengeCancelledByQuittingIsNotRecordedAsUnchallenged() async throws {
        let (world, run) = try await makeWorld(.healthyDoubt, runner: .answering("Late.", after: .seconds(30)), budget: .milliseconds(20))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        world.controller.tools.cancelChallenges()
        await world.controller.tools.lastChallenge?.value
        #expect(world.run(run.id)?.challenges.map(\.stage) == [.running])
        #expect(world.run(run.id)?.challenges.first?.unchallengedReason == nil && world.controller.tools.runningChallenges.isEmpty)
        #expect(await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)]).value?["submitted"] == true)
        #expect(world.run(run.id)?.decisions.last?.challenge == "unchallenged: AiTerm restarted before the second opinion answered.")
    }

    @Test func aCritiqueIsCappedAtEightKilobytes() async throws {
        let (world, run) = try await makeWorld(.healthyDoubt, runner: .answering(String(repeating: "é", count: 20_000)))
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        let critique = try #require(first.value?["critique"]?.stringValue)
        #expect(critique.utf8.count <= OperatorToolHandler.critiqueLimit + 64 && critique.hasSuffix(OperatorToolHandler.truncationMarker))
        #expect(world.run(run.id)?.challenges.first?.critique == critique)
    }

    @Test func theSameChallengeIdWithOtherArgumentsIsRefused() async throws {
        let (world, run) = try await makeWorld(.healthyDoubt, runner: .answering("Fine."))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        _ = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)])
        #expect(await world.call(run.id, "submit_plan", ["revision": 1, "extra": true, "challengeId": .string(id)]).message?
                .hasPrefix("Challenge \(id) has already acted") == true)
    }
}
