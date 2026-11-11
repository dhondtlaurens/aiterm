import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// A question and the flag it holds its task by have one writer (`AppState.open(_:inRun:)`, `release(_:unlessHeldIn:)`):
/// a task waits on you while an open question holds it, and stops once none does.
@Suite struct OperatorQuestionWriterTests {
    @Test func aQuestionThatHoldsItsTaskMakesItWaitOnYouUntilNoneHolds() throws {
        var world = OperatedWorld()
        let run = world.addRun(), id = world.addTask("T-1", run: run, state: .working)
        let at = world.createdAt
        world.state.open(OperatorQuestion(id: "free", text: "Which colour?", task: id, askedAt: at, holds: false), inRun: run)
        #expect(world.operated(id)?.flags.contains(.waitingOnYou) == false, "a question that doesn't hold leaves it be")
        world.state.open(OperatorQuestion(id: "q-1", text: "Ship it?", task: id, askedAt: at), inRun: run)
        world.state.open(OperatorQuestion(id: OperatorQuestion.gatePrefix + "1", text: "Allow `rm`?", task: id, askedAt: at), inRun: run)
        world.state.open(OperatorQuestion(id: "broadcast", text: "Go on?", task: nil, askedAt: at), inRun: run)
        #expect(world.state.run(id: run)?.questions.map(\.id) == ["free", "q-1", "gate-1", "broadcast"])
        #expect(world.operated(id)?.flags.contains(.waitingOnYou) == true)
        world.state.updateRun(id: run) { $0.questions[1].resolution = "Yes" }
        world.state.release(id, unlessHeldIn: run)
        #expect(world.operated(id)?.flags.contains(.waitingOnYou) == true, "the stopped command still holds it")
        world.state.updateRun(id: run) { $0.questions[2].resolution = "Allowed" }
        world.state.release(id, unlessHeldIn: run)
        #expect(world.operated(id)?.flags.contains(.waitingOnYou) == false)
    }
}
