import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
struct TaskCreationModelTests {
    @Test func lateSearchCannotReplaceNewerResultsOrAPickedTicket() async throws {
        var pending: [String: CheckedContinuation<[JiraTicket], Error>] = [:]
        let model = fixture(search: { text in try await withCheckedThrowingContinuation { pending[text] = $0 } })
        let first = Task { await model.search(text: "old") }
        await eventually { pending["old"] != nil }
        let second = Task { await model.search(text: "new") }
        await eventually { pending["new"] != nil }
        let ticket = JiraTicket(key: "MOB-1", summary: "Newest", description: "", issueType: nil, status: nil, url: "https://example.com")
        try #require(pending["new"]).resume(returning: [ticket])
        await second.value
        try #require(pending["old"]).resume(returning: [])
        await first.value
        #expect(model.results == [ticket])
        let third = Task { await model.search(text: "abandoned") }
        await eventually { pending["abandoned"] != nil }
        model.cancelSearch()
        model.draft.apply(ticket: ticket)
        try #require(pending["abandoned"]).resume(throwing: JiraError.unauthorized)
        await third.value
        #expect(model.draft.ticket == ticket)
        #expect(model.searchError == nil)
    }

    @Test func duplicateSubmissionIsBlockedAndFailureKeepsDraft() async throws {
        var calls = 0
        var completion: CheckedContinuation<Void, Error>?
        let model = fixture(create: { _ in
            calls += 1
            try await withCheckedThrowingContinuation { completion = $0 }
        })
        await model.loadAgentCatalogue()
        let first = Task { await model.create() }
        await eventually { calls == 1 }
        #expect(model.creating)
        #expect(await model.create() == false)
        #expect(calls == 1)
        try #require(completion).resume(throwing: GitError(args: ["worktree", "add"], code: 1, stderr: "branch already exists"))
        #expect(await first.value == false)
        #expect(!model.creating)
        #expect(model.draft.title == "Keep this draft")
        #expect(model.error?.reason == "Branch already exists.")
    }

    @Test func staleDefaultCannotCreateUntilCurrentModelIsSelected() async {
        let defaults = ScratchDefaults.make()
        ModelSettings.save(ModelPreference(model: "openai/model-x", reasoning: "high"), for: .pi, defaults: defaults)
        let current = AgentModel(id: "anthropic/model-x", label: "anthropic / model-x", detail: nil,
                                 efforts: [], defaultEffort: nil)
        var created = 0
        let model = fixture(agent: .pi, model: "openai/model-x", catalogue: { _ in [current] },
                            defaults: defaults, create: { _ in created += 1 })

        await model.loadAgentCatalogue()
        #expect(model.draft.model.isEmpty)
        #expect(!model.selectedModelIsCurrent)
        #expect(await model.create() == false)
        #expect(created == 0)
        model.draft.setModel(current.id, catalog: model.models)
        #expect(model.selectedModelIsCurrent)
        #expect(await model.create())
        #expect(created == 1)
    }

    /// The segmented agent picker sets its binding even when the tapped segment is already
    /// selected; that click must not wipe the loaded catalogue, because the `.task(id: agent)`
    /// reload never re-fires for the same agent.
    @Test func reselectingTheCurrentAgentKeepsTheLoadedCatalogue() async {
        let defaults = ScratchDefaults.make()
        let current = AgentModel(id: "anthropic/model-x", label: "anthropic / model-x", detail: nil,
                                 efforts: [], defaultEffort: nil)
        let model = fixture(agent: .pi, model: "anthropic/model-x", catalogue: { _ in [current] },
                            defaults: defaults)
        await model.loadAgentCatalogue()
        #expect(model.selectedModelIsCurrent)
        model.selectAgent(.pi)
        #expect(model.catalogueLoaded)
        #expect(model.models == [current])
        #expect(model.selectedModelIsCurrent)
    }

    @Test func agentStepCannotContinueWithoutASelectableCurrentModel() async {
        let model = fixture(agent: .pi, model: "", catalogue: { _ in [] })
        await model.loadAgentCatalogue()
        #expect(!NewTaskSheet.canAdvance(step: 2, model: model))
        #expect(!NewTaskSheet.canAdvance(step: 3, model: model))
    }

    /// A title of spaces is no name: create refuses it, so the sheet must not carry it through three
    /// steps first. The rule is the one New Review and `TaskCreator` apply.
    @Test func aBlankTitleCannotLeaveTheFirstStep() async {
        let model = fixture()
        await model.loadAgentCatalogue()
        model.draft.setTitle("   ")
        #expect(!NewTaskSheet.canAdvance(step: 1, model: model))
        #expect(!NewTaskSheet.canAdvance(step: 3, model: model))
    }

    /// No agent CLI at all — a fresh Mac. Step 1 still continues; the agent step does not, even
    /// with the catalogue of the agent the draft remembers.
    @Test func agentStepCannotContinueWithNoAgentInstalled() async {
        let model = fixture(available: [])
        await model.loadAgentCatalogue()
        #expect(model.selectedModelIsCurrent)
        #expect(NewTaskSheet.canAdvance(step: 1, model: model))
        #expect(!NewTaskSheet.canAdvance(step: 2, model: model))
        #expect(!NewTaskSheet.canAdvance(step: 3, model: model))
    }

    /// A keystroke in the prompt redraws the prompt step and the command preview, which draw it,
    /// and not the sheet around them: its other steps' fields, the destination, the footer.
    @Test func aPromptKeystrokeRedrawsOnlyWhatDrawsThePrompt() async {
        let model = fixture()
        await model.loadAgentCatalogue()
        model.draft.setTitle("Fix the login form")
        let sheet = NewTaskSheet(model: model).seeded(step: 3)
        // The task's own body, and the shared frame's it hands its step to.
        let wholeSheet = { _ = sheet.body; _ = sheet.body.body }
        #expect(!invalidates(wholeSheet, by: { model.promptText = "g" }))
        #expect(!invalidates(wholeSheet, by: { model.draft.promptText = "go" }), "nor through the draft")
        #expect(model.draft.promptText == "go" && model.previewCommand.contains("go"))

        #expect(invalidates({ _ = CommandPreview(model: model).body }, by: { model.promptText = "go on" }))
        #expect(invalidates({ _ = PromptStep(text: Bindable(model).promptText, agent: .claude, completions: model.completions).body },
                            by: { model.draft.promptText = "" }))
        // The rest of the draft still redraws the sheet that shows it.
        #expect(invalidates(wholeSheet, by: { model.draft.setTitle("Fix the signup form") }))
    }

    /// The sheet's first load reuses the catalogue its draft was just built from: reading it again
    /// was a second catalogue build, and for PI a second launch of its CLI.
    @Test func theFirstLoadUsesTheCatalogueTheDraftWasBuiltFrom() async {
        let handed = [AgentModel(id: "sonnet", label: "Sonnet", detail: nil, efforts: ["high"], defaultEffort: "high")]
        let reads = ReadCounter()
        let defaults = ScratchDefaults.make()
        let model = fixture(catalogue: { _ in reads.increment(); return handed }, initialCatalogue: handed, defaults: defaults)
        await model.loadAgentCatalogue()
        #expect(reads.value == 0)
        #expect(model.models == handed)
        #expect(model.selectedModelIsCurrent)

        model.selectAgent(.codex)
        await model.loadAgentCatalogue()
        model.selectAgent(.claude)
        await model.loadAgentCatalogue()
        #expect(reads.value == 2, "only the first load of the draft's own agent is handed its catalogue")
    }

    /// The Jira connection is read once, when the sheet is prepared, and every query uses it.
    @Test func withoutAJiraConnectionASearchSaysSo() async {
        let project = Project(id: UUID(), name: "Repo", path: "/tmp/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let search = TaskCreationModel.jiraSearcher(for: project, jira: nil)
        await #expect { try await search("login") } throws: {
            ($0 as? ActionUnavailable)?.message == "Connect Jira in Settings › Integrations, or continue without a ticket."
        }
    }

    /// The ticket field says what it searches: every linked Jira project, or every project there is.
    @Test func theTicketFieldNamesTheLinkedJiraProjectsItSearches() {
        let site = URL(string: "https://example.atlassian.net")!
        let linked = [JiraProjectRef(id: "1", key: "SHOP", name: "Storefront", siteURL: site),
                      JiraProjectRef(id: "2", key: "PAY", name: "Payments", siteURL: site)]
        func placeholder(_ jiraProjects: [JiraProjectRef]) -> String {
            let project = Project(id: UUID(), name: "Repo", path: "/tmp/repo", provider: .git, remoteUrl: nil,
                                  addedAt: Date(), collapsed: false, jiraProjects: jiraProjects)
            return TaskCreationModel(project: project, draft: TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil),
                                     home: ScratchHome.bare, catalogue: ScratchHome.catalogue, defaults: ScratchDefaults.make(), git: .hermetic(),
                                     searchIssues: { _ in [] }, createTask: { _ in }).ticketPlaceholder
        }
        #expect(placeholder(linked) == "Search SHOP and PAY by key or title")
        #expect(placeholder([linked[1]]) == "Search PAY by key or title")
        #expect(placeholder([]) == "Search by key or title")
    }

    /// The sheet names the directory create will make: past one that is already there, the
    /// same `-2` create picks — so the preview and the checkout cannot disagree.
    @Test func thePreviewedWorktreeIsTheOneCreateWillMake() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo + "/.worktrees/login", withIntermediateDirectories: true)
        let project = Project(id: UUID(), name: "Repo", path: repo, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setBranch("fix/login")
        let model = TaskCreationModel(project: project, draft: draft, home: ScratchHome.bare, catalogue: ScratchHome.catalogue,
                                      defaults: ScratchDefaults.make(), git: .hermetic(), searchIssues: { _ in [] }, createTask: { _ in })
        #expect(model.worktreeSlug == "login-2")
        #expect(model.worktreeSlug == BranchNaming.unused(draft.worktreeSlug, in: repo))
        model.draft.setBranch("fix/logout")
        #expect(model.worktreeSlug == "logout")

        let review = ReviewCreationModel(project: project, draft: ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil),
                                         home: ScratchHome.bare, catalogue: ScratchHome.catalogue, defaults: ScratchDefaults.make(), git: .hermetic(),
                                         searchMergeRequests: { _ in [] }, createReview: { _ in }, recover: { _ in })
        try FileManager.default.createDirectory(atPath: repo + "/.worktrees/review-card", withIntermediateDirectories: true)
        review.draft.setBranch("feat/card")
        #expect(review.worktreeSlug == "review-card-2")
    }

    /// The command both sheets preview is the model's, and a task's carries its ticket only while
    /// "Include Jira ticket details" is kept — the same composition `create` hands the agent.
    @Test func thePreviewedCommandCarriesTheTicketOnlyWhenItIsIncluded() {
        let model = fixture()
        let ticket = JiraTicket(key: "ML-7", summary: "Drain the queue", description: nil,
                                issueType: "Task", status: "To Do", url: "https://example/ML-7")
        model.draft.apply(ticket: ticket)
        model.draft.promptText = "Start here."
        model.draft.appendTicket = true
        #expect(model.previewCommand.contains("ML-7: Drain the queue"))
        #expect(model.previewCommand.contains("Start here."))
        model.draft.appendTicket = false
        #expect(!model.previewCommand.contains("ML-7"))
        #expect(model.previewCommand.contains("Start here."))
    }

    private func fixture(search: @escaping @MainActor (String) async throws -> [JiraTicket] = { _ in [] },
                         agent: AgentKind = .claude, model: String = "sonnet",
                         available: Set<AgentKind> = Set(AgentKind.allCases),
                         catalogue: @escaping @Sendable (AgentKind) -> [AgentModel] = ScratchHome.catalogue,
                         initialCatalogue: [AgentModel]? = nil,
                         defaults: UserDefaults = ScratchDefaults.make(),
                         create: @escaping @MainActor (TaskDraft) async throws -> Void = { _ in }) -> TaskCreationModel {
        let project = Project(id: UUID(), name: "Repo", path: "/tmp/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: agent, model: model, reasoning: nil)
        draft.setTitle("Keep this draft")
        return TaskCreationModel(project: project, draft: draft, home: ScratchHome.bare, availableAgents: { available },
                                 catalogue: catalogue, initialCatalogue: initialCatalogue, defaults: defaults, git: .hermetic(),
                                 searchIssues: search, createTask: create)
    }
}

private final class ReadCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
