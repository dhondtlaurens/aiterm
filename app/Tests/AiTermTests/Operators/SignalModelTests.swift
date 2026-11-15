import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalModelTests {
    let choice = SignalWorld.agent
    var context: SignalContext {
        SignalContext(models: [.claude: [AgentModel(id: choice.model, label: "Opus", detail: nil,
                                                   efforts: ["medium", "high"], defaultEffort: "high")]], defaults: [.claude: choice])
    }
    @Test func theFiveStepsSaveOneSignalAndItsDescriptionChoicesWithoutStartingDuringPreview() async throws {
        let world = SignalWorld()
        var saved: [Signal] = [], previewed = 0
        let model = SignalModel(projects: world.state.projects, context: context, preview: { _ in
            previewed += 1; return SignalRead(items: [world.ticket(), world.ticket("OTHER-1")], complete: true)
        }, save: { saved.append($0) })
        #expect(!model.canAdvance(step: 1))
        model.name = "Sprint tickets"
        #expect(model.canAdvance(step: 1))
        await model.loadPreview()
        #expect(saved.isEmpty && previewed == 1)
        #expect(model.startCount == 1 && model.previewItems.count == 2)
        model.ticketDescription = false
        model.requestDescription = true
        model.done = .hasReviewer; model.then = .archive
        #expect(model.canAdvance(step: 5))
        #expect(await model.create())
        let signal = try #require(saved.first)
        #expect(saved.count == 1 && signal.name == "Sprint tickets")
        #expect(signal.work.ticketDescription == false && signal.work.requestDescription)
        #expect(signal.finish == SignalFinish(doneWhen: .hasReviewer, then: .archive))
        #expect(signal.agents == [choice])
    }
    @Test func reviewRequestedHasOnlyItsOwnDoneChoicesAndNeverMerges() async {
        let model = SignalModel(projects: [], context: context, save: { _ in })
        model.name = "Reviews"; model.selectSource(.gitHub)
        model.setEvent(.myRequest); model.mergeWhenReady = true
        model.setEvent(.reviewRequested)
        #expect(model.doneChoices == [.myReviewPosted, .mergedOrClosed, .operatorJudges])
        #expect(!model.offersMerge && !model.finish.mergesWhenReady)
        #expect(model.prompt == SignalModel.reviewPrompt)
        model.prompt = "Our own review instructions."
        model.setEvent(.myRequest)
        #expect(model.prompt == "Our own review instructions.")
        model.waitingOnMyReply = false; model.sentBackToMe = false
        #expect(!model.canAdvance(step: 2))
    }
    @Test func editingKeepsIdentityAndAnIncompletePreviewPublishesNoPartialCount() async throws {
        var world = SignalWorld(); let id = world.signal()
        let original = try #require(world.state.signal(id: id))
        var saved: Signal?
        let model = SignalModel(signal: original, projects: world.state.projects, context: context,
                                preview: { _ in SignalRead(items: [world.ticket()], complete: false) }, save: { saved = $0 })
        await model.loadPreview()
        #expect(model.startCount == nil && model.previewItems.isEmpty && model.previewError != nil)
        model.name = "Updated"; model.done = .merged; model.then = .remove; model.deleteMergedBranch = true
        #expect(!model.offersMerge)
        #expect(await model.create())
        #expect(saved?.id == original.id && saved?.createdAt == original.createdAt)
        #expect(saved?.finish.deletesMergedBranch == true && saved?.finish.mergesWhenReady == false)
    }
    @Test func jqlTakesPrecedenceAndAnUnlistedAgentModelCannotBeSaved() async {
        let model = SignalModel(projects: [], context: context, save: { _ in Issue.record("Invalid choices must not save") })
        model.name = "Tickets"; model.queryMode = .jql; model.jql = "labels = operator ORDER BY updated DESC"
        if case .jira(let conditions) = model.source { #expect(JQL.compile(conditions) == model.jql) }
        else { Issue.record("Expected Jira") }
        model.jql = " "
        #expect(!model.canAdvance(step: 2))
        await model.loadPreview()
        #expect(model.startCount == nil && model.previewError != nil, "An empty JQL editor must not preview the hidden condition chips.")
        model.queryMode = .conditions
        model.removeAgent(model.agentRows[0].id)
        #expect(!model.canAdvance(step: 4))
        #expect(await model.create() == false)
    }
}
