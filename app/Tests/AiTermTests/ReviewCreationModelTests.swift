import Testing
import Foundation
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct ReviewCreationModelTests {
    let project = Project(id: UUID(), name: "acme-web", path: "/tmp/p", provider: .gitlab,
                          remoteUrl: "git@git.example.net:web/acme-web.git", addedAt: Date(), collapsed: false)
    let mr = MergeRequest(iid: 4, title: "Add gift card", sourceBranch: "feat-gift-card",
                          targetBranch: "main", author: "L", state: "opened", draft: false,
                          url: "https://git.example.net/web/acme-web/-/merge_requests/4")

    private func model(search: @escaping @MainActor (String) async throws -> [MergeRequest] = { _ in [] },
                       agent: AgentKind = .claude, modelID: String = "sonnet", available: Set<AgentKind>? = nil,
                       catalogue: @escaping @Sendable (AgentKind) -> [AgentModel] = ScratchHome.catalogue,
                       defaults: UserDefaults = ScratchDefaults.make(),
                       create: @escaping @MainActor (ReviewDraft) async throws -> Void = { _ in }) -> ReviewCreationModel {
        ReviewCreationModel(project: project, draft: ReviewDraft(mr: nil, agent: agent, model: modelID, reasoning: nil),
                            home: ScratchHome.bare, availableAgents: available ?? [agent], catalogue: catalogue, defaults: defaults,
                            searchMergeRequests: search, createReview: create)
    }

    /// The GitLab connection and the project's remote are read once, when the sheet is prepared —
    /// a Keychain read and a look at the checkout — and every query uses what was read then.
    @Test func aSearchUsesTheConnectionAndRemoteItWasPreparedWith() async {
        let remote = ProviderDetector.detect(remoteUrl: project.remoteUrl)
        let disconnected = ReviewCreationModel.searcher(gitLab: nil, remote: remote)
        await #expect { try await disconnected("card") } throws: {
            ($0 as? ActionUnavailable)?.message == "Connect GitLab in Settings › Integrations, or pick a branch instead."
        }
        let elsewhere = ReviewCreationModel.searcher(gitLab: GitLabConfig(hostURL: URL(string: "https://gitlab.com")!, token: "t"),
                                                     remote: remote)
        await #expect { try await elsewhere("card") } throws: {
            ($0 as? ActionUnavailable)?.message == "This project’s remote is git.example.net; GitLab is configured for gitlab.com."
        }
    }

    let gitHubRemote = ProviderDetector.detect(remoteUrl: "git@github.com:octocat/hello.git")

    @Test func aGitHubProjectSearchesGitHubWithItsToken() async {
        let disconnected = ReviewCreationModel.searcher(gitLab: nil, gitHub: nil, remote: gitHubRemote)
        await #expect { try await disconnected("x") } throws: {
            ($0 as? ActionUnavailable)?.message == "Connect GitHub in Settings › Integrations, or pick a branch instead."
        }
        let pathless = ReviewCreationModel.searcher(gitLab: nil, gitHub: GitHubConfig(token: "t"),
                                                    remote: RemoteInfo(host: "github.com", path: "", provider: .github))
        await #expect { try await pathless("x") } throws: {
            ($0 as? ActionUnavailable)?.message == "Couldn’t read a GitHub repository from this repository’s remote."
        }
    }

    /// Review focus 1: a self-hosted GitLab the detector calls plain git still lists merge
    /// requests when Settings' GitLab is that host — the GitHub branch takes only `.github`.
    @Test func aPlainGitRemoteOnTheConfiguredGitLabHostStillSearchesGitLab() async {
        let remote = ProviderDetector.detect(remoteUrl: "https://code.example.com/a/b.git", repoPath: "/nonexistent")
        #expect(remote.provider == .git)
        let search = ReviewCreationModel.searcher(gitLab: GitLabConfig(hostURL: URL(string: "https://gitlab.com")!, token: "t"),
                                                  gitHub: GitHubConfig(token: "t"), remote: remote)
        await #expect { try await search("x") } throws: {
            ($0 as? ActionUnavailable)?.message == "This project’s remote is code.example.com; GitLab is configured for gitlab.com."
        }
    }

    /// The picker clears its query after a pick, which re-searches; the refusal must outlive that.
    @Test func pickingAForksPullRequestIsRefusedWithTheFork() async {
        let m = model()
        let before = m.draft.branch
        let fork = MergeRequest(iid: 5, title: "Fix typo", sourceBranch: "patch-1", targetBranch: "main", author: "someone",
                                state: "open", draft: false, url: "https://github.com/octocat/hello/pull/5", forkHead: "someone:patch-1")
        let refusal = "This pull request’s branch is in a fork (someone:patch-1). AiTerm reviews branches on origin."
        m.pick(fork)
        await m.search(text: "")
        #expect(m.pickRefusal == refusal)
        #expect(m.draft.mr == nil)
        #expect(m.draft.branch == before)
        m.pick(mr)
        #expect(m.pickRefusal == nil)
        #expect(m.draft.mr == mr)
        m.pick(fork)
        m.clearPick()
        #expect(m.pickRefusal == nil)
        #expect(m.draft.mr == nil)
    }

    @Test func testResultsLandAndClearTheError() async {
        let m = model(search: { _ in [self.mr] })
        await m.search(text: "")
        #expect(m.results == [mr])
        #expect(m.searchError == nil)
    }

    @Test func testUnauthorizedBecomesAnInstruction() async {
        let m = model(search: { _ in throw GitLabError.unauthorized })
        await m.search(text: "")
        #expect(m.searchError == "Check your GitLab access token in Settings › Integrations.")
        #expect(m.results.isEmpty)
    }

    /// A failed create leaves the draft intact so the branch can be corrected and retried, and
    /// renders a GitError the way the task sheet and the banner do: git’s failure line as a
    /// sentence, and its whole output in the tooltip.
    @Test func testFailedCreateKeepsTheDraftAndShowsGitsOwnMessage() async {
        let m = model(create: { _ in throw GitError(args: ["worktree", "add"], code: 128, stderr: "fatal: already used by worktree") })
        m.draft.apply(mr: mr)
        await m.loadAgentCatalogue()
        #expect(await m.create() == false)
        #expect(m.error == CreationFailure(reason: "Already used by worktree.",
                                           detail: "git worktree add failed:\nfatal: already used by worktree"))
        #expect(m.draft.branch == "feat-gift-card")
    }

    /// Where a review will open is decided by its branch, and the sheet has to know before
    /// anything is created: a branch that is a task's opens in that task, not a worktree of its own.
    @Test func testTheOwningTaskFollowsTheBranch() {
        let owner = TaskItem(id: UUID(), projectId: project.id, title: "Gift card", branch: "feat-gift-card",
                             worktreePath: "/tmp/p/.worktrees/gift-card", baseBranch: "main", jira: nil,
                             agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: true,
                             createdAt: Date(), windowId: nil)
        let m = ReviewCreationModel(project: project, draft: ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil),
                                    home: ScratchHome.bare, catalogue: ScratchHome.catalogue, defaults: ScratchDefaults.make(),
                                    owningTask: { branch, _ in branch == owner.branch ? owner : nil },
                                    searchMergeRequests: { _ in [] }, createReview: { _ in })
        #expect(m.owningTask == nil)
        m.draft.apply(mr: mr)
        #expect(m.owningTask == owner)
        m.draft.setBranch("feat-someone-else")
        #expect(m.owningTask == nil)
    }

    /// Finding the owner reads the workspace, so it happens when the branch or the checkouts
    /// change: a render that did it would redraw the sheet on every change to the workspace, and
    /// the sheet reads `owningTask` three times a render.
    @Test func theOwningTaskIsFoundOnceABranchIsPickedNotOnEachRead() {
        var lookups = 0
        let m = ReviewCreationModel(project: project, draft: ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil),
                                    home: ScratchHome.bare, catalogue: ScratchHome.catalogue, defaults: ScratchDefaults.make(),
                                    owningTask: { _, _ in lookups += 1; return nil },
                                    searchMergeRequests: { _ in [] }, createReview: { _ in })
        let before = lookups
        _ = (m.owningTask, m.owningTask, m.owningTask)
        m.draft.promptText = "/code-review"
        #expect(lookups == before, "reads and prompt edits look nothing up")
        m.draft.setBranch("feat-gift-card")
        _ = (m.owningTask, m.owningTask)
        #expect(lookups == before + 1)
    }

    @Test func testCreateRefusesAnUnavailableAgent() async {
        let m = model()
        m.draft.setAgent(.codex, state: AppState.empty, home: ScratchHome.bare, defaults: ScratchDefaults.make())
        m.draft.setTitle("Review")
        #expect(await m.create() == false)
    }

    /// The branch field's matches are kept with the model and filtered when the query or the list
    /// changes, so a render reads them rather than filtering every branch again.
    @Test func testBranchMatchesFollowTheQueryAndTheBranchList() {
        let m = model()
        m.branches = ["main", "feat/gift-card", "fix/hero-spacing"]
        #expect(m.branchMatches == ["main", "feat/gift-card", "fix/hero-spacing"])
        m.branchQuery = "hero"
        #expect(m.branchMatches == ["fix/hero-spacing"])
        m.branches = ["main", "fix/hero-spacing", "feat/hero-card"]
        #expect(m.branchMatches == ["fix/hero-spacing", "feat/hero-card"])
        m.branchQuery = ""
        #expect(m.branchMatches == m.branches)
    }

    @Test func testBranchesAreFilteredBySubstring() {
        let m = model()
        m.branches = ["main", "feat/gift-card", "fix/hero-spacing"]
        #expect(m.filteredBranches(query: "") == ["main", "feat/gift-card", "fix/hero-spacing"])
        #expect(m.filteredBranches(query: "hero") == ["fix/hero-spacing"])
        #expect(m.filteredBranches(query: "FEAT") == ["feat/gift-card"])
    }

    /// Mirrors `TaskCreationModelTests.lateSearchCannotReplaceNewerResultsOrAPickedTicket`: a slow
    /// earlier search landing after a fast later one must not overwrite the newer results, and a
    /// search abandoned by `cancelSearch()` must not clobber a merge request picked afterward.
    @Test func lateSearchCannotReplaceNewerResultsOrAPickedMergeRequest() async throws {
        var pending: [String: CheckedContinuation<[MergeRequest], Error>] = [:]
        let m = model(search: { text in try await withCheckedThrowingContinuation { pending[text] = $0 } })
        let first = Task { await m.search(text: "old") }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { await m.search(text: "new") }
        try await Task.sleep(for: .milliseconds(20))
        let newest = MergeRequest(iid: 9, title: "Newest", sourceBranch: "feat-newest", targetBranch: "main",
                                  author: "L", state: "opened", draft: false,
                                  url: "https://git.example.net/web/acme-web/-/merge_requests/9")
        try #require(pending["new"]).resume(returning: [newest])
        await second.value
        try #require(pending["old"]).resume(returning: [])
        await first.value
        #expect(m.results == [newest])
        let third = Task { await m.search(text: "abandoned") }
        try await Task.sleep(for: .milliseconds(20))
        m.cancelSearch()
        m.draft.apply(mr: newest)
        try #require(pending["abandoned"]).resume(throwing: GitLabError.unauthorized)
        await third.value
        #expect(m.draft.mr == newest)
        #expect(m.searchError == nil)
    }

    /// The window a double press slips through: the destination check reads git before the submit,
    /// and a second press during that read must be refused, not submitted as well.
    @Test func aSecondPressDuringTheDestinationCheckIsRefused() async throws {
        var calls = 0
        let m = model(create: { _ in calls += 1 })
        m.draft.setTitle("Review")
        await m.loadAgentCatalogue()
        async let first = m.create()
        async let second = m.create()
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1)
        #expect(calls == 1)
    }

    /// Mirrors `TaskCreationModelTests.duplicateSubmissionIsBlockedAndFailureKeepsDraft`: `create()`'s
    /// `!creating` guard must block a second submission while the first is still in flight, and a
    /// failed create must leave the draft intact.
    @Test func duplicateSubmissionIsBlockedAndFailureKeepsDraft() async throws {
        var calls = 0
        var completion: CheckedContinuation<Void, Error>?
        let m = model(create: { _ in
            calls += 1
            try await withCheckedThrowingContinuation { completion = $0 }
        })
        m.draft.setTitle("Keep this draft")
        await m.loadAgentCatalogue()
        let first = Task { await m.create() }
        // A review re-reads git's checkouts before submitting, so wait for the submit itself
        // rather than a fixed moment. `creating` is set before that read: a press during it is
        // as blocked as one during the submit. The read resumes on the main actor, which the
        // suite's pixel tests hold for seconds at a time, so the deadline is generous: it only
        // bounds a hang, and the loop leaves as soon as the submit lands.
        let deadline = Date().addingTimeInterval(30)
        while calls == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.creating)
        #expect(await m.create() == false)
        #expect(calls == 1)
        try #require(completion).resume(throwing: GitError(args: ["worktree", "add"], code: 1, stderr: "branch already exists"))
        #expect(await first.value == false)
        #expect(!m.creating)
        #expect(m.draft.title == "Keep this draft")
        #expect(m.error?.reason == "Branch already exists.")
    }

    @Test func staleDefaultCannotCreateAReviewUntilCurrentModelIsSelected() async {
        let defaults = ScratchDefaults.make()
        ModelSettings.save(ModelPreference(model: "openai/model-x", reasoning: "high"), for: .pi, defaults: defaults)
        let current = AgentModel(id: "anthropic/model-x", label: "anthropic / model-x", detail: nil,
                                 efforts: [], defaultEffort: nil)
        var created = 0
        let m = model(agent: .pi, modelID: "openai/model-x", catalogue: { _ in [current] },
                      defaults: defaults, create: { _ in created += 1 })
        m.draft.setTitle("Review")
        m.draft.setBranch("main")

        await m.loadAgentCatalogue()
        #expect(m.draft.model.isEmpty)
        #expect(!m.selectedModelIsCurrent)
        #expect(await m.create() == false)
        #expect(created == 0)
        m.draft.setModel(current.id, catalog: m.models)
        #expect(m.selectedModelIsCurrent)
        #expect(await m.create())
        #expect(created == 1)
    }

    /// Mirrors `TaskCreationModelTests.reselectingTheCurrentAgentKeepsTheLoadedCatalogue`: a click
    /// on the already-selected agent segment must not wipe the loaded catalogue.
    @Test func reselectingTheCurrentAgentKeepsTheLoadedCatalogue() async {
        let defaults = ScratchDefaults.make()
        let current = AgentModel(id: "anthropic/model-x", label: "anthropic / model-x", detail: nil,
                                 efforts: [], defaultEffort: nil)
        let m = model(agent: .pi, modelID: "anthropic/model-x", catalogue: { _ in [current] },
                      defaults: defaults)
        await m.loadAgentCatalogue()
        #expect(m.selectedModelIsCurrent)
        m.selectAgent(.pi)
        #expect(m.catalogueLoaded)
        #expect(m.models == [current])
        #expect(m.selectedModelIsCurrent)
    }

    @Test func agentStepCannotContinueWithoutASelectableCurrentModel() async {
        let m = model(agent: .pi, modelID: "", catalogue: { _ in [] })
        m.draft.setTitle("Review")
        m.draft.setBranch("main")
        await m.loadAgentCatalogue()
        let sheet = NewReviewSheet(model: m, previewStep: 2, previewMergeRequests: [], previewOpen: false)
        #expect(!sheet.canAdvance)
    }

    /// No agent CLI at all — a fresh Mac. The review can be named on step 1, but the agent step
    /// cannot continue, even with the catalogue of the agent the draft remembers.
    @Test func agentStepCannotContinueWithNoAgentInstalled() async {
        let m = model(available: [])
        m.draft.setTitle("Review")
        m.draft.setBranch("main")
        await m.loadAgentCatalogue()
        #expect(m.selectedModelIsCurrent)
        #expect(NewReviewSheet(model: m, previewStep: 1, previewMergeRequests: [], previewOpen: false).canAdvance)
        #expect(!NewReviewSheet(model: m, previewStep: 2, previewMergeRequests: [], previewOpen: false).canAdvance)
    }
}
