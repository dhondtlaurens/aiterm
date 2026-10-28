import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// New Broadcast's Agents, Task and Done steps as a model (broadcast setup v2): the rows seeded from the last broadcast's
/// or the Settings › Agents defaults, the row rules, the end the Merge slice allows, the closing boxes, the goal the
/// Oracle allows, and what Start hands over.
@MainActor
struct BroadcastSetupStepsTests {
    private static let efforts = ["low", "medium", "high"]
    static let opus = AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil, efforts: efforts, defaultEffort: "high")
    static let sonnet = AgentModel(id: "claude-sonnet-5-5", label: "Sonnet 5.5", detail: nil, efforts: ["low", "medium"], defaultEffort: "medium")
    static let astra = AgentModel(id: "gpt-6-astra", label: "gpt-6-astra", detail: nil, efforts: efforts, defaultEffort: "medium")
    static let opusHigh = AgentChoice(agent: .claude, model: opus.id, reasoning: "high")
    static let sonnetMedium = AgentChoice(agent: .claude, model: sonnet.id, reasoning: "medium")
    static let astraMedium = AgentChoice(agent: .codex, model: astra.id, reasoning: "medium")

    private let webshop = Project(id: UUID(), name: "webshop", path: "/tmp/webshop", provider: .gitlab, remoteUrl: nil,
                                  addedAt: Date(), collapsed: false)

    private func sheet(_ context: NewBroadcastContext = .installed(),
                       start: @escaping @MainActor (NewBroadcastModel.Request) async throws -> UUID = { _ in UUID() }) -> NewBroadcastModel {
        let model = NewBroadcastModel(projects: [webshop], context: context, start: start)
        model.add(project: webshop)
        model.prompt = "Implement PAY-230"
        return model
    }

    private func rows(_ model: NewBroadcastModel) -> [AgentChoice] { model.agentRows.map(\.choice) }

    // -- Agents: seeding ----------------------------------------------------------------

    @Test func withNoLastRowsItStartsWithEachInstalledAgentAtItsDefault() {
        #expect(rows(sheet(.installed())) == [Self.opusHigh, Self.astraMedium], "Claude, then Codex")
        #expect(rows(sheet(.installed(agents: [.claude]))) == [Self.opusHigh], "Codex isn't installed")
    }

    @Test func itStartsAsTheLastBroadcastsRowsLessWhatIsGone() {
        let gone = AgentChoice(agent: .claude, model: "claude-opus-4-1", reasoning: "high")
        let pi = AgentChoice(agent: .pi, model: "pi-model", reasoning: nil)
        let last = [Self.sonnetMedium, gone, Self.astraMedium, pi]
        #expect(rows(sheet(.installed(last: last))) == [Self.sonnetMedium, Self.astraMedium], "a model no longer listed, and PI, are dropped")
        #expect(rows(sheet(.installed(agents: [.claude], last: last))) == [Self.sonnetMedium], "Codex is no longer installed")
    }

    @Test func aKeptRowAtAReasoningItsModelNoLongerOffersTakesTheModelsDefault() {
        let high = AgentChoice(agent: .claude, model: Self.sonnet.id, reasoning: "high")
        #expect(rows(sheet(.installed(last: [high]))) == [Self.sonnetMedium])
    }

    @Test func identicalLastRowsAreKeptOnce() {
        #expect(rows(sheet(.installed(last: [Self.astraMedium, Self.astraMedium]))) == [Self.astraMedium])
        let high = AgentChoice(agent: .claude, model: Self.sonnet.id, reasoning: "high")
        #expect(rows(sheet(.installed(last: [high, Self.sonnetMedium]))) == [Self.sonnetMedium],
                "alike once Sonnet's reasoning is adjusted")
    }

    /// An installed agent whose Settings › Agents default names a model no longer listed still has a default: its first
    /// model at that model's own reasoning. So it is offered, and a kept row on it stays one it can pick.
    @Test func anAgentWhoseSavedDefaultIsGoneDefaultsToItsFirstModel() throws {
        let preferences = ScratchDefaults.make()
        ModelSettings.save(ModelPreference(model: "gpt-5-retired", reasoning: "high"), for: .codex, defaults: preferences)
        let lists: [AgentKind: [AgentModel]] = [.claude: [Self.opus, Self.sonnet], .codex: [Self.astra]]
        let context = NewBroadcastContext.read(profile: nil, installed: [.claude, .codex], models: { lists[$0] ?? [] },
                                               remembered: [:], preferences: preferences)
        #expect(context.defaults[.codex] == Self.astraMedium)
        #expect(rows(sheet(context)) == [Self.opusHigh, Self.astraMedium], "no last rows: Codex at its first model")
        #expect(sheet(context).offeredAgents == [.claude, .codex])

        try OperatorProfileStore.saveLastAgents([Self.astraMedium], preferences)
        let kept = NewBroadcastContext.read(profile: nil, installed: [.claude, .codex], models: { lists[$0] ?? [] },
                                            remembered: [:], preferences: preferences)
        let model = sheet(kept)
        #expect(rows(model) == [Self.astraMedium])
        #expect(model.offeredAgents.contains(.codex), "the kept row's agent is one its Agent menu lists")
    }

    /// Every last row gone (a model no longer listed, an agent no longer offered): each installed agent at its default.
    @Test func withEveryLastRowDroppedItStartsWithEachInstalledAgentAtItsDefault() {
        let last = [AgentChoice(agent: .claude, model: "claude-opus-4-1", reasoning: "high"), AgentChoice(agent: .pi, model: "pi-model", reasoning: nil)]
        #expect(rows(sheet(.installed(last: last))) == [Self.opusHigh, Self.astraMedium])
    }

    /// An agent's default is the one its Settings › Agents card shows (`ModelSettings.resolve`): the saved default, else
    /// the model last picked for it, else its first.
    @Test func anAgentsDefaultIsTheOneItsSettingsCardShows() {
        let preferences = ScratchDefaults.make()
        ModelSettings.save(ModelPreference(model: Self.astra.id, reasoning: "low"), for: .codex, defaults: preferences)
        let lists: [AgentKind: [AgentModel]] = [.claude: [Self.opus, Self.sonnet], .codex: [Self.astra]]
        let remembered: [AgentKind: String] = [.claude: Self.sonnet.id, .codex: Self.opus.id]
        let context = NewBroadcastContext.read(profile: nil, installed: [.claude, .codex], models: { lists[$0] ?? [] },
                                               remembered: remembered, preferences: preferences)
        #expect(context.defaults[.claude] == Self.sonnetMedium, "no saved default: the model last picked, at its reasoning")
        #expect(context.defaults[.codex] == AgentChoice(agent: .codex, model: Self.astra.id, reasoning: "low"), "the saved default first")
        for agent in [AgentKind.claude, .codex] {
            let card = ModelSettings.resolve(for: agent, catalog: lists[agent] ?? [], remembered: remembered[agent], defaults: preferences)
            #expect(context.defaults[agent].map { ModelPreference(model: $0.model, reasoning: $0.reasoning) } == card)
        }
    }

    // -- Agents: the rows ---------------------------------------------------------------

    @Test func itOffersTheInstalledAgentsWithTheirOwnModels() {
        let model = sheet(.installed(agents: [.codex]))
        #expect(model.offeredAgents == [.codex])
        #expect(sheet().offeredAgents == [.claude, .codex])
        #expect(sheet().models(for: .claude) == [Self.opus, Self.sonnet])
        #expect(NewBroadcastModel.agentsHelp
                == "The Operator starts every worker, tab and reviewer from this list, and nothing else. It starts as your last broadcast’s list.")
        #expect(NewBroadcastModel.addAgentLabel == "Add an agent")
    }

    @Test func addAnAgentAddsTheNextAgentAtItsDefault() throws {
        let model = sheet(.installed(last: [Self.sonnetMedium]))
        model.addAgent()
        #expect(rows(model) == [Self.sonnetMedium, Self.astraMedium], "Codex has no row yet")
        model.addAgent()
        #expect(rows(model) == [Self.sonnetMedium, Self.astraMedium, Self.opusHigh], "both have one: the first agent's default")
    }

    @Test func pickingAnAgentTakesItsDefaultAndPickingAModelKeepsAReasoningItOffers() throws {
        let model = sheet(.installed(last: [Self.opusHigh]))
        let row = try #require(model.agentRows.first).id
        model.setAgent(.codex, of: row)
        #expect(rows(model) == [Self.astraMedium])
        model.setAgent(.claude, of: row)
        #expect(rows(model) == [Self.opusHigh])
        model.setReasoning("low", of: row)
        model.setModel(Self.sonnet, of: row)
        #expect(rows(model) == [AgentChoice(agent: .claude, model: Self.sonnet.id, reasoning: "low")], "Sonnet offers low")
        model.setAgent(.claude, of: row)
        #expect(rows(model) == [AgentChoice(agent: .claude, model: Self.sonnet.id, reasoning: "low")],
                "picking the agent it already runs keeps its model and reasoning")
        model.setReasoning("medium", of: row)
        model.setModel(Self.opus, of: row)
        model.setReasoning("high", of: row)
        model.setModel(Self.sonnet, of: row)
        #expect(rows(model) == [Self.sonnetMedium], "Sonnet has no high: its default")
    }

    @Test func atLeastOneRowIsNeededToContinue() throws {
        let model = sheet(.installed(agents: [.claude]))
        #expect(model.canAdvance(step: 3))
        model.removeAgent(try #require(model.agentRows.first).id)
        #expect(model.agentRows.isEmpty)
        #expect(model.canAdvance(step: 2), "the Prompt step needs no row")
        #expect(!model.canAdvance(step: 3) && !model.canAdvance(step: 4) && !model.canStart)
        model.addAgent()
        #expect(model.canAdvance(step: 3) && model.canStart)
    }

    @Test func noAgentInstalledLeavesNoRowAndNothingToAdd() {
        let model = sheet(.installed(agents: []))
        #expect(model.agentRows.isEmpty && model.offeredAgents.isEmpty)
        model.addAgent()
        #expect(model.agentRows.isEmpty)
        #expect(!model.canAdvance(step: 3))
    }

    @Test func identicalRowsReachStartOnce() async throws {
        var requests: [NewBroadcastModel.Request] = []
        let model = sheet(.installed(last: [Self.opusHigh, Self.sonnetMedium])) { requests.append($0); return UUID() }
        let second = model.agentRows[1].id
        model.setModel(Self.opus, of: second)
        model.setReasoning("high", of: second)
        model.addAgent()
        #expect(model.agentRows.count == 3, "a row alike stays on screen while it is being picked")
        _ = await model.start()
        #expect(try #require(requests.first).agents == [Self.opusHigh, Self.astraMedium])
    }

    // -- Task ---------------------------------------------------------------------------

    @Test func theTaskStepSaysEveryTaskFollowsIt() {
        #expect(NewBroadcastModel.taskLeadTitle == "Every task follows these.")
        #expect(NewBroadcastModel.taskLead == "The broadcast’s own goal is the next step.")
        #expect(NewBroadcastModel.reviewLabel == "Each task is reviewed with")
        #expect(NewBroadcastModel.reviewHelp == "Who reviews each task, what counts as passing, and how many rounds of fixes it gets before it comes to you. Type / for skills. Optional: left empty, a task is accepted without a review.")
        #expect(NewBroadcastModel.endLabel == "Each task ends at")
        #expect(NewBroadcastModel.closingLabel == "When the broadcast ends")
        #expect(NewBroadcastModel.closeLabel == "Close finished tasks’ tabs and remove their worktrees")
        #expect(NewBroadcastModel.deleteBranchLabel == "Delete their local branches once merged into the default branch")
    }

    @Test func mergeAndLocalMergeArePickedOnlyWithTheMergeSlice() {
        let on = sheet(.installed(slices: Slices(merge: true))), off = sheet(.installed(slices: .none))
        #expect(on.end == .draftMR && off.end == .draftMR)
        #expect(TaskEnd.allCases.map(on.canPick) == [true, true, true, true])
        #expect(TaskEnd.allCases.map(off.canPick) == [true, true, false, false])
        #expect(on.endHelp == "Where every task’s work ends.")
        #expect(off.endHelp == "Where every task’s work ends. Merge is off in Settings › Operator, so a task ends at a commit or a draft MR.")
        on.pick(end: .mergeLocal)
        off.pick(end: .merge)
        off.pick(end: .commit)
        off.pick(end: .mergeLocal)
        #expect(on.end == .mergeLocal && off.end == .commit)
    }

    private func project(_ name: String) -> Project {
        Project(id: UUID(), name: name, path: "/tmp/\(name)", provider: .gitlab, remoteUrl: nil, addedAt: Date(), collapsed: false)
    }

    /// Draft MR and Merge need a code host: while a chosen project has none connected, both are dimmed, and the help says
    /// which, as it says the Merge slice is off.
    @Test func draftMRAndMergeWaitForEveryChosenProjectsCodeHost() async {
        let blog = project("blog"), docs = project("docs")
        let model = NewBroadcastModel(projects: [webshop, blog, docs], context: .installed(slices: Slices(merge: true)),
                                      hasCodeHost: { $0.name == "webshop" }, start: { _ in UUID() })
        model.add(project: webshop)
        await model.loadCodeHosts()
        #expect(TaskEnd.allCases.map(model.canPick) == [true, true, true, true])
        #expect(model.endHelp == "Where every task’s work ends.")
        model.add(project: blog)
        await model.loadCodeHosts()
        #expect(TaskEnd.allCases.map(model.canPick) == [true, false, false, true], "Commit and Local merge need no host")
        model.pick(end: .mergeLocal)
        #expect(model.endHelp == "Where every task’s work ends. blog has no connected code host, so a task ends at a commit or a local merge.")
        model.pick(end: .merge)
        #expect(model.end == .mergeLocal, "Merge is refused")
        model.add(project: docs)
        await model.loadCodeHosts()
        #expect(model.endHelp == "Where every task’s work ends. blog and docs have no connected code host, so a task ends at a commit or a local merge.")
        model.remove(project: blog)
        model.remove(project: docs)
        await model.loadCodeHosts()
        #expect(TaskEnd.allCases.map(model.canPick) == [true, true, true, true])
    }

    /// A draft MR and a merge go through the code host; a commit and a local merge stay on this Mac.
    @Test func draftMRAndMergeNeedACodeHost() {
        #expect(TaskEnd.allCases.filter(\.needsCodeHost) == [.draftMR, .merge])
    }

    /// Start waits for the chosen projects' code hosts to be checked, again whenever they change; Continue doesn't.
    @Test func startWaitsForTheCodeHostCheck() async {
        let blog = project("blog")
        let model = NewBroadcastModel(projects: [webshop, blog], context: .installed(), hasCodeHost: { _ in true },
                                      start: { _ in UUID() })
        model.add(project: webshop)
        model.prompt = "Implement PAY-230"
        let start = CreationSteps.broadcast.count
        #expect(!model.canAdvance(step: start))
        #expect(model.canAdvance(step: start - 1))
        await model.loadCodeHosts()
        #expect(model.canAdvance(step: start))
        model.add(project: blog)
        #expect(!model.canAdvance(step: start), "blog isn't checked yet")
        await model.loadCodeHosts()
        #expect(model.canAdvance(step: start))
    }

    /// An end picked that becomes dimmed moves to Commit, and the help says so.
    @Test func theDefaultDraftMRWithAHostlessProjectMovesToCommit() async {
        let blog = project("blog")
        let model = NewBroadcastModel(projects: [blog], context: .installed(slices: Slices(merge: true)), hasCodeHost: { _ in false },
                                      start: { _ in UUID() })
        #expect(model.end == .draftMR)
        model.add(project: blog)
        await model.loadCodeHosts()
        #expect(model.end == .commit)
        #expect(model.endHelp == "Where every task’s work ends. blog has no connected code host, so a task ends at a commit or a local merge. Draft MR moved to Commit.")
    }

    @Test func aMergePickedBeforeAHostlessProjectIsAddedMovesToCommit() async {
        let blog = project("blog")
        let model = NewBroadcastModel(projects: [webshop, blog], context: .installed(slices: Slices(merge: true)),
                                      hasCodeHost: { $0.name == "webshop" }, start: { _ in UUID() })
        model.add(project: webshop)
        await model.loadCodeHosts()
        model.pick(end: .merge)
        #expect(model.end == .merge)
        model.add(project: blog)
        await model.loadCodeHosts()
        #expect(model.end == .commit)
        #expect(model.endHelp.hasSuffix(" Merge moved to Commit."), "the step names an end by its title")
    }

    /// Whatever was picked, Start hands over an end the step lets be picked.
    @Test(arguments: [TaskEnd.draftMR, .merge]) func startNeverSendsADimmedEnd(picked: TaskEnd) async {
        let blog = project("blog")
        var requests: [NewBroadcastModel.Request] = []
        let model = NewBroadcastModel(projects: [webshop, blog], context: .installed(slices: Slices(merge: true)),
                                      hasCodeHost: { $0.name == "webshop" }) { requests.append($0); return UUID() }
        model.add(project: webshop)
        model.prompt = "Implement PAY-230"
        await model.loadCodeHosts()
        model.pick(end: picked)
        model.add(project: blog)
        await model.loadCodeHosts()
        #expect(model.canAdvance(step: CreationSteps.broadcast.count))
        #expect(await model.start() != nil)
        let sent = requests.compactMap(\.taskSettings?.end)
        #expect(sent == [.commit])
        #expect(sent.allSatisfy(model.canPick))
    }

    @Test func withMergeOffAndNoCodeHostATaskEndsAtACommit() async {
        let blog = project("blog")
        let model = NewBroadcastModel(projects: [blog], context: .installed(slices: .none), hasCodeHost: { _ in false }, start: { _ in UUID() })
        model.add(project: blog)
        await model.loadCodeHosts()
        #expect(TaskEnd.allCases.map(model.canPick) == [true, false, false, false])
        #expect(model.endHelp == "Where every task’s work ends. Merge is off in Settings › Operator and blog has no connected code host, so a task ends at a commit. Draft MR moved to Commit.")
    }

    @Test func theBranchBoxWaitsForTheCloseBox() {
        let model = sheet()
        #expect(model.closeWhenDone && !model.deleteMergedBranch, "close on, branches kept")
        #expect(model.canDeleteMergedBranch)
        model.deleteMergedBranch = true
        model.closeWhenDone = false
        #expect(!model.canDeleteMergedBranch)
        #expect(!model.deleteMergedBranch, "unticked with it, so no branch is deleted without closing")
        model.closeWhenDone = true
        #expect(!model.deleteMergedBranch, "ticking close again leaves it to the person")
    }

    // -- Done ---------------------------------------------------------------------------

    @Test func theGoalAndItsRoundsFollowTheOracle() {
        let on = sheet(.installed(oracle: true)), off = sheet(.installed(oracle: false))
        #expect(on.goalIsAvailable && !off.goalIsAvailable)
        #expect(NewBroadcastModel.goalLabel == "Goal" && NewBroadcastModel.extraRoundsLabel == "Extra rounds")
        #expect(NewBroadcastModel.goalPlaceholder == "Every ticket is merged and its work is released")
        #expect(on.goalHelp == "What must be true once every task is done. The Operator checks it with the Oracle. Optional: left empty, the broadcast ends when its tasks do.")
        #expect(on.extraRoundsHelp == "How many times the Operator may plan what the goal still misses, once every task is done. When they are used up, it stops and says what is left.")
        #expect(off.goalHelp == "The Oracle is off in Settings › Operator, and a goal needs it: the broadcast ends when its tasks do.")
        #expect(off.extraRoundsHelp == nil, "the goal's help says it for both")
        #expect(on.extraRounds == 2)
    }

    @Test func extraRoundsTakeDigitsOnly() {
        let model = sheet()
        #expect(model.extraRoundsText == "2")
        model.extraRoundsText = "1a2"
        #expect(model.extraRoundsText == "12" && model.extraRounds == 12)
        model.extraRoundsText = "-3"
        #expect(model.extraRounds == 3, "a minus sign is dropped like any other non-digit")
        model.extraRoundsText = ""
        #expect(model.extraRounds == 2, "emptied, it goes back to the default")
        #expect(NewBroadcastModel.extraRoundsPlaceholder == "2", "which the empty field shows")
        model.extraRoundsText = String(Int.max)
        #expect(model.extraRounds == Int.max)
        model.extraRoundsText = String(Int.max) + "9"
        #expect(model.extraRoundsText == String(Int.max), "a digit past what a count can hold is refused")
    }

    @Test func everyNewStepsCopyKeepsTheHouseStyle() {
        let on = sheet(.installed(oracle: true)), off = sheet(.installed(slices: .none, oracle: false))
        let copy = [NewBroadcastModel.agentsHelp, NewBroadcastModel.reviewHelp, off.endHelp, NewBroadcastModel.closeLabel,
                    NewBroadcastModel.deleteBranchLabel, on.goalHelp, off.goalHelp, on.extraRoundsHelp ?? "",
                    NewBroadcastModel.taskLeadTitle, NewBroadcastModel.taskLead]
        for text in copy {
            #expect(!text.contains("—"), "no em dash in \(text)")
            #expect(!text.contains("'"), "the app's curly apostrophe in \(text)")
        }
    }

    // -- Start --------------------------------------------------------------------------

    @Test func startHandsOverTheRowsTheTaskSettingsAndTheGoal() async throws {
        var requests: [NewBroadcastModel.Request] = []
        let model = sheet(.installed(slices: Slices(merge: true), oracle: true)) { requests.append($0); return UUID() }
        model.review = "  An adversarial review with /code-review.\n"
        model.pick(end: .merge)
        model.deleteMergedBranch = true
        model.done = " Every PAY ticket is merged. "
        model.extraRoundsText = "3"
        _ = await model.start()
        let request = try #require(requests.first)
        #expect(request.agents == [Self.opusHigh, Self.astraMedium])
        #expect(request.review == nil && request.done == nil, "a new broadcast keeps no Review and Done text")
        #expect(request.taskSettings == TaskSettings(review: "An adversarial review with /code-review.", end: .merge,
                                                     closeWhenDone: true, deleteMergedBranch: true))
        #expect(request.goal == BroadcastGoal(text: "Every PAY ticket is merged.", extraRounds: 3))
    }

    @Test func anEmptyReviewAndGoalAreNone() async throws {
        var requests: [NewBroadcastModel.Request] = []
        let model = sheet { requests.append($0); return UUID() }
        model.review = " \n"
        model.done = "  "
        _ = await model.start()
        let request = try #require(requests.first)
        #expect(request.taskSettings == TaskSettings(review: nil, end: .draftMR))
        #expect(request.goal == nil)
    }

    @Test func withTheOracleOffTheBroadcastStartsWithNoGoal() async throws {
        var requests: [NewBroadcastModel.Request] = []
        let model = sheet(.installed(oracle: false)) { requests.append($0); return UUID() }
        model.done = "Every PAY ticket is merged."
        _ = await model.start()
        #expect(try #require(requests.first).goal == nil)
    }
}

extension NewBroadcastContext {
    /// What New Broadcast opens with in these tests: `agents` installed, Claude listing Opus 5.5 and Sonnet 5.5 and Codex
    /// gpt-6-astra, each defaulting to its first at that model's own reasoning, and `last` as the last broadcast's rows.
    @MainActor static func installed(agents: [AgentKind] = [.claude, .codex], slices: Slices = .none, oracle: Bool = true,
                          last: [AgentChoice] = []) -> NewBroadcastContext {
        typealias T = BroadcastSetupStepsTests
        let lists: [AgentKind: [AgentModel]] = [.claude: [T.opus, T.sonnet], .codex: [T.astra]]
        let defaults: [AgentKind: AgentChoice] = [.claude: T.opusHigh, .codex: T.astraMedium]
        return NewBroadcastContext(slices: slices, oracleIsOn: oracle, models: lists.filter { agents.contains($0.key) },
                                   defaults: defaults.filter { agents.contains($0.key) }, lastAgents: last)
    }
}
