import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// New Task and New Review share three steps: source and name, prompt, then agent.
@MainActor
struct CreationSheetStepsTests {
    @Test func taskAndReviewShareThreeStepsWithTheAgentLast() {
        #expect(TaskCreation.steps == ReviewCreation.steps)
        let steps = TaskCreation.steps
        #expect(steps.count == 3 && steps.agentStep == 3)
        #expect((1...3).map { steps.primaryTitle(onStep: $0, createLabel: "Create Task") } == ["Continue", "Continue", "Create Task"])
        #expect((1...3).map(steps.secondaryTitle(onStep:)) == ["Cancel", "Back", "Back"])
        #expect((1...3).map(steps.creates(onStep:)) == [false, false, true])
        #expect((1...3).map(steps.showsDestination(onStep:)) == [false, false, true])
        #expect((1...3).map(steps.hasPrompt(onStep:)) == [false, true, false])
    }

    @Test func onlyCompletedStepsCanBeClickedOrReachedByTheirNumber() {
        #expect(SheetStepper.canNavigate(from: 3, to: 1, count: 4))
        #expect(SheetStepper.canNavigate(from: 3, to: 2, count: 4))
        #expect(!SheetStepper.canNavigate(from: 3, to: 4, count: 4))
        #expect(!SheetStepper.canNavigate(from: 3, to: 0, count: 4))
    }

}
