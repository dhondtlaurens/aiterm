import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The board's end menu and its fix-rounds links act through the app (`AppController.boardActions`): each reaches the
/// Operator controller on the broadcast as it is when clicked, and what it refuses is said in the banner.
@MainActor
struct BoardActionsWiringTests {
    @Test func theEndMenuAndTheFixRoundsAnswerReachTheController() async throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.workspace.load()
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

        // Fix rounds are answered in their block, as any question is: by one of its two buttons.
        actions.answer("fix-footer", "Accept As It Is")
        await eventually(describing: "the answer recorded") {
            controller.state.run(id: run.id)?.questions.first?.answeredOnCard == "acceptAsItIs"
        }

        // A refusal is said in the banner: Merge is off for this broadcast.
        actions.changeEnd(task.id, .merge)
        await eventually(describing: "the refusal reported") { controller.notices.issue != nil }
        #expect(controller.notices.issue?.title == "Couldn’t change the task’s end.")
        #expect(controller.notices.issue?.reason == "Merge is off for this broadcast, so a task ends at a commit or a draft MR.")
        #expect(controller.state.task(id: task.id)?.operated?.end == .commit)
    }

    /// A question's block under Waiting on you: a choice or Send records the answer, and an answer AiTerm refuses is said
    /// in the banner. A pick from a row's menu reaches the controller, and the row's items follow its card.
    @Test func aBlocksAnswerAndARowsMenuReachTheController() async throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.workspace.load()
        let web = OperatorUIFixtures.project("pluto-web")
        var run = OperatorUIFixtures.run(projectIds: [web.id], agents: OperatorUIFixtures.agents, taskSettings: OperatorUIFixtures.taskSettings)
        let task = OperatorUIFixtures.task("Footer", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "footer", state: .working, end: .draftMR))
        run.questions = [OperatorQuestion(id: "scope", text: "Keep drafts?", task: task.id, askedAt: OperatorUIFixtures.epoch, holds: false,
                                          choices: ["Keep them", "Drop them"]),
                         OperatorQuestion(id: "gate-1", text: "The Oracle stopped `npm publish`.", task: nil, askedAt: OperatorUIFixtures.epoch,
                                          gate: GateRequest(command: "npm publish", directory: "/w"))]
        controller.workspace.mutate { state in state.append(project: web); state.runs = [run]; state.tasks = [task] }
        let actions = controller.boardActions(for: run.id, dismiss: {})

        actions.answer("scope", "Keep them")
        await eventually(describing: "the answer recorded") {
            controller.state.run(id: run.id)?.questions.first?.answeredHere == "Keep them"
        }
        func card() throws -> BroadcastBoard.Card {
            let run = try #require(controller.state.run(id: run.id))
            return try #require(BroadcastBoard.make(run: run, state: controller.state, acting: .none, requests: []).stages.flatMap(\.cards).first)
        }
        func items(_ card: BroadcastBoard.Card) -> [OperatorMenuItem] {
            card.stoppable.map { OperatorMenus.task(takenOver: card.takenOver, stoppable: $0) } ?? []
        }
        #expect(try items(card()) == OperatorMenus.task(controller.state.task(id: task.id)?.operated, broadcastLive: true))
        #expect(try items(card()) == [.takeOver, .separator, .stopTask])
        actions.perform(.takeOver, task.id)
        await eventually(describing: "the task taken over") { controller.state.task(id: task.id)?.operated?.takenOver == true }
        #expect(try items(card()) == [.handBack, .separator, .stopTask])
        let shelved = BroadcastBoard.shelved(run: try #require(controller.state.run(id: run.id)), state: controller.state)
        #expect(shelved.stages.flatMap(\.cards).allSatisfy { $0.stoppable == nil }, "a shelved board's rows have none of them")

        actions.answer("gate-1", "yes")
        await eventually(describing: "the refusal reported") { controller.notices.issue != nil }
        #expect(controller.notices.issue?.title == "Couldn’t answer the question.")
        #expect(controller.notices.issue?.reason == "Answer it in the Operator’s chat.")
    }
}
