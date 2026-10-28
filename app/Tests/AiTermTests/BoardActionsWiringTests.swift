import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The board's end menu and its fix-rounds links act through the app (`AppController.boardActions`): each reaches the
/// Operator controller on the broadcast as it is when clicked, and what it refuses is said in the banner.
@MainActor
struct BoardActionsWiringTests {
    @Test func theEndMenuAndTheFixRoundsLinksReachTheController() async throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let web = OperatorUIFixtures.project("pluto-web")
        var run = OperatorUIFixtures.run(projectIds: [web.id], agents: OperatorUIFixtures.agents, taskSettings: OperatorUIFixtures.taskSettings)
        let task = OperatorUIFixtures.task("Footer", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "footer", state: .working, end: .draftMR))
        run.questions = [OperatorQuestion(id: "fix-footer", text: "Out of fix rounds?", task: task.id, askedAt: OperatorUIFixtures.epoch,
                                          about: OperatorQuestion.fixRounds)]
        controller.workspace.mutate { state in state.append(project: web); state.runs = [run]; state.tasks = [task] }
        let actions = controller.boardActions(for: run.id, dismiss: {})

        actions.changeEnd(task.id, .commit)
        await eventually(describing: "the end changed") { controller.state.task(id: task.id)?.operated?.end == .commit }

        actions.answerFixRounds(task.id, .acceptAsItIs)
        await eventually(describing: "the answer recorded") {
            controller.state.run(id: run.id)?.questions.first?.answeredOnCard == "accept it as it is"
        }

        // A refusal is said in the banner: Merge is off for this broadcast.
        actions.changeEnd(task.id, .merge)
        await eventually(describing: "the refusal reported") { controller.notices.issue != nil }
        #expect(controller.state.task(id: task.id)?.operated?.end == .commit)
    }
}
