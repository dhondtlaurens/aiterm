import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The creation frame's steps (`CreationSteps`): New Task and New Review keep their three, with the
/// agent second, and New Broadcast has five, its Agents list third and no agent step, creating on the fifth.
@MainActor
struct CreationSheetStepsTests {
    @Test func newTaskStillHasThreeSteps() {
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

    @Test func broadcastCreatesOnStepFive() {
        let steps = CreationSteps.broadcast
        #expect(steps == CreationSteps(count: 5, agentStep: nil, agentsListStep: 3))
        #expect((1...5).map { steps.primaryTitle(onStep: $0, createLabel: "Start Broadcast") }
                == ["Continue", "Continue", "Continue", "Continue", "Start Broadcast"])
        #expect((1...5).map(steps.secondaryTitle(onStep:)) == ["Cancel", "Back", "Back", "Back", "Back"])
        #expect((1...5).map(steps.creates(onStep:)) == [false, false, false, false, true])
        #expect((1...5).map(steps.showsDestination(onStep:)) == [true, false, false, false, true])
        #expect((1...5).map(steps.showsCommand(onStep:)) == [false, false, false, false, false], "no agent of its own, so no command")
        #expect((1...5).map(steps.saysNoAgentCanRun(onStep:)) == [false, false, false, false, false])
        #expect((1...5).map(steps.hasPrompt(onStep:)) == [false, true, false, true, true], "Prompt, Task's review and Done's goal are prompt editors")
    }
}
