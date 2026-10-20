import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The creation frame's steps (`CreationSteps`): New Task and New Review keep their three, with the
/// agent second, and New Broadcast has four and no agent step, creating on the fourth.
@MainActor
struct CreationSheetStepsTests {
    @Test func newTaskStillHasThreeSteps() {
        #expect(TaskCreation.stepCount == 3 && TaskCreation.agentStep == 2)
        #expect(ReviewCreation.stepCount == 3 && ReviewCreation.agentStep == 2)
        #expect(TaskCreation.steps == ReviewCreation.steps)
        let steps = TaskCreation.steps
        #expect(steps == CreationSteps(count: 3, agentStep: 2))
        #expect((1...3).map { steps.primaryTitle(onStep: $0, createLabel: "Create Task") } == ["Continue", "Continue", "Create Task"])
        #expect((1...3).map(steps.secondaryTitle(onStep:)) == ["Cancel", "Back", "Back"])
        #expect((1...3).map(steps.creates(onStep:)) == [false, false, true])
        #expect((1...3).map(steps.showsDestination(onStep:)) == [true, false, true], "steps 1 and 3, never the agent's")
        #expect((1...3).map(steps.showsCommand(onStep:)) == [false, true, true])
        #expect((1...3).map(steps.saysNoAgentCanRun(onStep:)) == [false, false, true])
        #expect((1...3).map(steps.hasPrompt(onStep:)) == [false, false, true])
    }

    @Test func broadcastCreatesOnStepFour() {
        let steps = CreationSteps.broadcast
        #expect(steps == CreationSteps(count: 4, agentStep: nil))
        #expect((1...4).map { steps.primaryTitle(onStep: $0, createLabel: "Start Broadcast") }
                == ["Continue", "Continue", "Continue", "Start Broadcast"])
        #expect((1...4).map(steps.secondaryTitle(onStep:)) == ["Cancel", "Back", "Back", "Back"])
        #expect((1...4).map(steps.creates(onStep:)) == [false, false, false, true])
        #expect((1...4).map(steps.showsDestination(onStep:)) == [true, false, false, true])
        #expect((1...4).map(steps.showsCommand(onStep:)) == [false, false, false, false], "no agent, so no command")
        #expect((1...4).map(steps.saysNoAgentCanRun(onStep:)) == [false, false, false, false])
        #expect((1...4).map(steps.hasPrompt(onStep:)) == [false, true, true, true], "Prompt, Review and Done are prompt editors")
    }
}
