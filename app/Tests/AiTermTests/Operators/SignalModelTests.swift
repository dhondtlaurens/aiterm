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
        var saved: [Signal] = [], previewed: [SignalTrigger] = []
        let model = SignalModel(projects: world.state.projects, context: context, preview: { trigger in
            previewed.append(trigger); return SignalRead(items: [world.ticket(), world.ticket("OTHER-1")], complete: true)
        }, save: { saved.append($0) })
        #expect(!model.canAdvance(step: SignalModel.nameStep))
        model.name = "Sprint tickets"
        #expect(model.canAdvance(step: SignalModel.nameStep))
        model.start.query = " labels = ready "
        model.prompt = "Plan, build and review it."
        await model.loadPreview()
        #expect(saved.isEmpty && previewed.map(\.query) == [" labels = ready "])
        #expect(model.startCount == 1 && model.previewItems.count == 2)
        model.ticketDescription = false
        model.requestDescription = true
        model.then = .archive
        #expect(!model.canAdvance(step: SignalModel.doneStep), "a Done trigger needs its query")
        model.done = SignalTrigger(source: .gitLab, query: "reviewer:any")
        #expect(model.canAdvance(step: SignalModel.doneStep))
        #expect(await model.create())
        let signal = try #require(saved.first)
        #expect(saved.count == 1 && signal.name == "Sprint tickets")
        #expect(signal.start == SignalTrigger(source: .jira, query: "labels = ready"), "saved trimmed")
        #expect(signal.done == SignalTrigger(source: .gitLab, query: "reviewer:any"))
        #expect(signal.work.ticketDescription == false && signal.work.requestDescription)
        #expect(signal.finish == SignalFinish(then: .archive))
        #expect(signal.agents == [choice])
    }
    /// Merge when ready is offered only where the Start trigger's merge requests are the person's own.
    @Test func aReviewerStartQueryNeverOffersMerge() async {
        let model = SignalModel(projects: [], context: context, save: { _ in })
        model.name = "Reviews"; model.prompt = "Our own review instructions."
        model.start = SignalTrigger(source: .gitHub, query: "author:@me"); model.mergeWhenReady = true
        #expect(model.offersMerge && model.finish.mergesWhenReady)
        model.start.query = "user-review-requested:@me"
        #expect(!model.offersMerge && !model.finish.mergesWhenReady)
        model.start.source = .jira
        #expect(model.offersMerge && model.prompt == "Our own review instructions.")
    }
    @Test func aNewSignalStartsBlankAndNeedsAQueryAndAPrompt() async {
        var previewed = 0
        let model = SignalModel(projects: [], context: context, preview: { _ in previewed += 1; return SignalRead(items: [], complete: true) },
                                save: { _ in })
        #expect(model.start == SignalTrigger(source: .jira, query: "") && model.prompt.isEmpty)
        #expect(!model.isEditing && model.title == "New Operator signal")
        model.name = "Tickets"
        #expect(!model.canAdvance(step: SignalModel.startStep), "No query would match every ticket the account can see.")
        await model.loadPreview()
        #expect(previewed == 0 && model.previewError != nil)
        model.start.query = "sprint in openSprints()"
        #expect(model.canAdvance(step: SignalModel.startStep))
        #expect(!model.canAdvance(step: SignalModel.promptStep))
        model.prompt = "Fix it."
        #expect(model.canAdvance(step: SignalModel.promptStep))
    }
    enum Part: CaseIterable, Sendable { case query, agents, prompt }
    /// A signal saves only whole: without its Start query, its agents or its prompt, create refuses it.
    @Test(arguments: Part.allCases) func createRefusesASignalMissingAPart(missing: Part) async {
        let model = SignalModel(projects: [], context: context, save: { _ in Issue.record("An incomplete signal must not save") })
        model.name = "Tickets"; model.start.query = "labels = ready"; model.done.query = "status = Done"; model.prompt = "Fix it."
        #expect(model.canAdvance(step: SignalModel.doneStep))
        switch missing {
        case .query: model.start.query = " "
        case .agents: model.removeAgent(model.agentRows[0].id)
        case .prompt: model.prompt = " "
        }
        #expect(await model.create() == false)
    }
    /// A GitLab Start query AiTerm refuses says why, blocks the step and is never read.
    @Test func aRefusedGitLabQuerySaysWhyAndIsNotPreviewed() async {
        var previewed = 0
        let model = SignalModel(projects: [], context: context, preview: { _ in previewed += 1; return SignalRead(items: [], complete: true) },
                                save: { _ in })
        model.name = "Reviews"; model.start = SignalTrigger(source: .gitLab, query: "review-state:unreviewed draft:no")
        #expect(model.startRefusal?.message == "Name yourself in one role: author:@me, assignee:@me or reviewer:@me.")
        #expect(!model.canAdvance(step: SignalModel.startStep))
        await model.loadPreview()
        #expect(previewed == 0 && model.previewError == nil)
        model.start.query = "reviewer:@me review-state:unreviewed draft:no"
        #expect(model.startRefusal == nil && model.canAdvance(step: SignalModel.startStep))
        model.done = SignalTrigger(source: .gitLab, query: "author:@me reviewer:@me")
        #expect(model.doneRefusal != nil)
        model.done.query = ""
        #expect(model.doneRefusal == nil, "an empty field is not refused, only incomplete")
    }
    @Test func editingKeepsIdentityAndAnIncompletePreviewPublishesNoPartialCount() async throws {
        var world = SignalWorld(); let id = world.signal()
        let original = try #require(world.state.signal(id: id))
        var saved: Signal?
        let model = SignalModel(signal: original, projects: world.state.projects, context: context,
                                preview: { _ in SignalRead(items: [world.ticket()], complete: false) }, save: { saved = $0 })
        #expect(model.isEditing && model.title == "Edit Operator signal")
        #expect(model.start == original.start && model.done == original.done)
        await model.loadPreview()
        #expect(model.startCount == nil && model.previewItems.isEmpty && model.previewError != nil)
        model.name = "Updated"; model.then = .remove; model.deleteMergedBranch = true; model.done.query = " "
        #expect(await model.create() == false && saved == nil, "a Done trigger without a query cannot save")
        model.done.query = "status = Closed"
        #expect(await model.create())
        #expect(saved?.id == original.id && saved?.createdAt == original.createdAt)
        #expect(saved?.finish.deletesMergedBranch == true && saved?.finish.mergesWhenReady == false)
    }
    @Test func readinessNeverDisablesCreate() async {
        let model = SignalModel(projects: [], context: context, save: { _ in })
        model.name = "Tickets"; model.start.query = "labels = ready"; model.done.query = "status = Done"; model.prompt = "Fix it."
        for readiness in [SignalReadiness.checking, .ready, .notReady(["Messaging needs attention"])] {
            model.readiness = { _ in readiness }
            #expect(model.canAdvance(step: SignalModel.doneStep))
            #expect(await model.create())
        }
    }

    @Test func anUnavailableModelExplainsWhyContinueIsDisabled() {
        let signal = Signal(name: "Tickets", createdAt: Date(), start: SignalTrigger(source: .gitHub, query: "user-review-requested:@me"),
                            done: SignalTrigger(source: .gitHub, query: "reviewed-by:@me"), work: SignalWork(prompt: "Fix it."),
                            agents: [AgentChoice(agent: .claude, model: "removed", reasoning: nil)], finish: SignalFinish(then: .archive))
        let model = SignalModel(signal: signal, projects: [], context: context, save: { _ in })
        #expect(!model.canAdvance(step: SignalModel.agentsStep))
        #expect(model.agentsWhyNot == ModelReasoningFields.unavailableHelp)
    }

    @Test func anEmptyAgentsListSaysAddAnAgent() {
        let model = SignalModel(projects: [], context: context, save: { _ in })
        model.removeAgent(model.agentRows[0].id)
        #expect(model.agentsWhyNot == "Add an agent.")
    }

    @Test func anUninstalledRowExplainsWhyContinueIsDisabled() {
        let missing = SignalContext(models: context.models, defaults: [.codex: AgentChoice(agent: .codex, model: "m", reasoning: nil)])
        var world = SignalWorld(); let id = world.signal()
        let model = SignalModel(signal: world.state.signal(id: id), projects: [], context: missing, save: { _ in })
        #expect(model.agentsWhyNot == "Claude Code isn’t installed. Choose another agent for its row, or remove it.")
    }

    @Test func savedReasoningNoLongerOfferedLoadsAsTheModelsLevel() {
        var world = SignalWorld(); let id = world.signal()
        var signal = world.state.signal(id: id)!
        signal.agents = [AgentChoice(agent: .claude, model: choice.model, reasoning: "removed")]
        let model = SignalModel(signal: signal, projects: [], context: context, save: { _ in })
        #expect(model.agents.first?.reasoning == "high")
        #expect(model.agentsWhyNot == nil)
    }

    /// Write runs only from its button, with the trigger's description; it fills the query, keeps the description, and
    /// is pressable only with a description.
    @Test func writeFillsTheQueryAndKeepsTheDescription() async {
        let model = SignalModel(projects: [], context: context, save: { _ in })
        var asked: [(SignalTrigger, Bool)] = []
        model.writeQuery = { trigger, start in asked.append((trigger, start)); return .written("reviewer:@me review-state:unreviewed") }
        model.start.source = .gitLab
        #expect(!model.canWrite(start: true), "nothing described yet")
        await model.write(start: true)
        #expect(asked.isEmpty && model.start.query.isEmpty)
        model.start.description = "Reviews asked of me"
        #expect(model.canWrite(start: true) && !model.canWrite(start: false))
        await model.write(start: true)
        #expect(asked.map(\.1) == [true] && asked.first?.0.description == "Reviews asked of me")
        #expect(model.start == SignalTrigger(source: .gitLab, description: "Reviews asked of me", query: "reviewer:@me review-state:unreviewed"))
        #expect(model.writing(start: true) == QueryWriting(written: true) && model.writing(start: false) == QueryWriting())
    }

    /// A query that still fails is put in the field with its reason, which goes once the person edits either field.
    @Test func aFailedWritesErrorClearsOnEdit() async {
        let model = SignalModel(projects: [], context: context, save: { _ in })
        model.writeQuery = { _, _ in .failed("Claude’s query still fails: Field 'statuz' does not exist.", query: "statuz = Done") }
        model.done.description = "When it's done"
        await model.write(start: false)
        #expect(model.done.query == "statuz = Done")
        #expect(model.writing(start: false) == QueryWriting(error: "Claude’s query still fails: Field 'statuz' does not exist."))
        model.done.query = "status = Done"
        #expect(model.writing(start: false).error == nil)
        await model.write(start: false)
        #expect(model.writing(start: false).error != nil)
        model.done.description = "When it's closed"
        #expect(model.writing(start: false).error == nil)
        model.writeQuery = { _, _ in .failed("Claude Code isn’t installed.", query: nil) }
        await model.write(start: false)
        #expect(model.done.query == "statuz = Done", "a run with no query leaves the field as it was")
    }

    /// While Claude writes, the button is busy and a second press does nothing; a source switched meanwhile drops the answer.
    @Test func aWriteInFlightIsBusyAndASwitchedSourceDropsItsAnswer() async {
        let model = SignalModel(projects: [], context: context, save: { _ in })
        let asked = TestLatch(), answer = TestLatch()
        var calls = 0
        model.writeQuery = { _, _ in calls += 1; asked.signal(); await answer.wait(); return .written("status = Done") }
        model.start.description = "Mine"
        let writing = Task { await model.write(start: true) }
        await asked.wait()
        #expect(model.writing(start: true).busy)
        await model.write(start: true)
        #expect(calls == 1)
        model.start.source = .gitHub
        answer.signal(); await writing.value
        #expect(model.start.query.isEmpty && model.writing(start: true) == QueryWriting())
    }

    /// The preview reads the Start query; a description edited while it reads keeps its answer, since nothing refreshes it.
    @Test func aDescriptionEditedDuringThePreviewKeepsIt() async {
        let asked = TestLatch(), answer = TestLatch()
        let model = SignalModel(projects: [], context: context, preview: { _ in
            asked.signal(); await answer.wait(); return SignalRead(items: [], complete: true)
        }, save: { _ in })
        model.start = SignalTrigger(source: .jira, query: "status = Open")
        let reading = Task { await model.loadPreview() }
        await asked.wait()
        model.start.description = "Open tickets"
        answer.signal(); await reading.value
        #expect(model.startCount == 0 && model.previewError == nil)
    }

    /// A query typed or a description changed while Claude writes is the person's newer word: the answer is dropped.
    @Test(arguments: [true, false]) func anEditDuringAWriteKeepsTheEdit(editsQuery: Bool) async {
        let model = SignalModel(projects: [], context: context, save: { _ in })
        let asked = TestLatch(), answer = TestLatch()
        model.writeQuery = { _, _ in asked.signal(); await answer.wait(); return .written("status = Done") }
        model.start.description = "Mine"
        let writing = Task { await model.write(start: true) }
        await asked.wait()
        if editsQuery { model.start.query = "status = Open" } else { model.start.description = "Mine, in review" }
        answer.signal(); await writing.value
        #expect(model.start.query == (editsQuery ? "status = Open" : ""))
        #expect(!model.writing(start: true).busy)
    }

    /// The description is saved with its trigger and shown again when the signal is edited.
    @Test func theDescriptionIsSavedWithItsTrigger() async throws {
        var saved: [Signal] = []
        let model = SignalModel(projects: [], context: context, save: { saved.append($0) })
        model.name = "Tickets"; model.prompt = "Fix it."
        model.start = SignalTrigger(source: .jira, description: " My sprint tickets ", query: "sprint in openSprints()")
        model.done = SignalTrigger(source: .jira, description: "When it's done", query: "statusCategory = Done")
        #expect(await model.create())
        let signal = try #require(saved.first)
        #expect(signal.start.description == "My sprint tickets" && signal.done.description == "When it's done")
        #expect(SignalModel(signal: signal, projects: [], context: context, save: { _ in }).start.description == "My sprint tickets")
    }

    // -- a project signal (where New Signal… was chosen decides its kind) -------------------------------------------------
    /// Claude and Codex both installed: an Operator signal lists both rows, a project signal only the first.
    var pair: SignalContext {
        let codex = AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")
        return SignalContext(models: [.claude: [AgentModel(id: choice.model, label: "Opus", detail: nil, efforts: ["medium", "high"], defaultEffort: "high")],
                                      .codex: [AgentModel(id: codex.model, label: "gpt-6-astra", detail: nil, efforts: ["medium"], defaultEffort: "medium")]],
                             defaults: [.claude: choice, .codex: codex])
    }
    @Test func aNewProjectSignalSavesItsKindOneAgentAndAFinishItCanRun() async throws {
        let world = SignalWorld()
        var saved: [Signal] = []
        let model = SignalModel(kind: .project, projects: world.state.projects, context: pair, save: { saved.append($0) })
        #expect(model.isProject && model.title == "New project signal" && model.stepNames[SignalModel.agentsStep - 1] == "Agent")
        #expect(model.agentRows.map(\.choice) == [choice], "one row, the first")
        model.addAgent()
        #expect(model.agentRows.count == 1, "a project signal has no Add")
        #expect(model.doneKinds == [.query, .youDecide] && model.thenValues == [.keep, .archive])
        model.name = "Reviews for me"
        #expect(model.canAdvance(step: SignalModel.nameStep) && !model.canAdvance(step: SignalModel.startStep))
        model.start = SignalTrigger(source: .gitLab, query: "author:@me")
        #expect(model.canAdvance(step: SignalModel.startStep) && model.canAdvance(step: SignalModel.agentsStep))
        #expect(!model.offersMerge, "a project signal merges nothing, even on the person's own merge requests")
        model.mergeWhenReady = true; model.deleteMergedBranch = true
        #expect(!model.canAdvance(step: SignalModel.promptStep))
        model.prompt = "/psg:review"
        #expect(model.canAdvance(step: SignalModel.promptStep))
        #expect(model.doneKind == .query && !model.canAdvance(step: SignalModel.doneStep), "A query matches needs its query")
        model.doneKind = .youDecide
        #expect(model.done.source == .person && model.canAdvance(step: SignalModel.doneStep))
        model.doneKind = .operatorDecides
        #expect(model.doneKind == .youDecide, "the Operator does not decide a project signal's Done")
        #expect(await model.create())
        let signal = try #require(saved.first)
        #expect(signal.kind == .project && signal.agents == [choice] && signal.isValid)
        #expect(signal.finish == SignalFinish(then: .archive), "no merge and no branch deletion")
    }
    @Test func editingAProjectSignalKeepsItsKind() async throws {
        var world = SignalWorld(); let id = world.projectSignal(start: SignalTrigger(source: .gitLab, query: "reviewer:@me"))
        let original = try #require(world.state.signal(id: id))
        var saved: Signal?
        // The caller's kind is for a new signal only: editing reads the signal's own.
        let model = SignalModel(signal: original, kind: .operator, projects: world.state.projects, context: pair, save: { saved = $0 })
        #expect(model.isProject && model.title == "Edit project signal" && model.doneKind == .youDecide)
        #expect(model.agentRows.map(\.choice) == original.agents)
        model.name = "Reviews, renamed"
        #expect(await model.create())
        #expect(saved?.kind == .project && saved?.id == original.id && saved?.done.source == .person)
    }
    @Test func anOperatorSignalStillSavesNoKind() async throws {
        var saved: [Signal] = []
        let model = SignalModel(projects: [], context: pair, save: { saved.append($0) })
        #expect(!model.isProject && model.agentRows.count == 2 && model.doneKinds == [.query, .operatorDecides])
        #expect(model.thenValues == SignalFinish.Then.allCases && model.stepNames == SignalModel.stepNames)
        model.doneKind = .youDecide
        #expect(model.doneKind == .query, "only a project signal leaves Done to the person")
        model.name = "Tickets"; model.prompt = "Fix it."
        model.start.query = "labels = ready"; model.done.query = "status = Done"
        #expect(await model.create())
        let signal = try #require(saved.first)
        #expect(signal.kind == nil && signal.agents.count == 2)
        let edited = SignalModel(signal: signal, kind: .project, projects: [], context: pair, save: { _ in })
        #expect(!edited.isProject && edited.title == "Edit Operator signal")
    }
}
