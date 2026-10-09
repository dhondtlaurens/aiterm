import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A review of a branch that is already a task's opens in that task: a tab in its window running
/// the reviewer, and nothing on disk. Git would refuse a second worktree on the branch anyway, and
/// with nothing created there is nothing a later removal could take from the task.
extension AppControllerTests {
    @Test func aReviewOfATasksBranchOpensAsATabInItsWindow() async throws {
        let fixture = try ReviewFixture(windowOpen: true)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)

        try await fixture.controller.createReview(draft: fixture.draft, project: fixture.project)

        let tab = try #require(server.requests.first { $0.method == "tab.create" })
        #expect(tab.params["windowId"] as? String == "alive")
        #expect(tab.params["cwd"] as? String == fixture.task.worktreePath, "in the task's worktree, whatever the active tab is doing")
        #expect((tab.params["agentCommand"] as? String)?.hasSuffix("'/code-review'") == true)
        #expect(server.requests.contains { $0.method == "window.activate" && $0.params["windowId"] as? String == "alive" })
        #expect(!server.requests.contains { $0.method == "window.createTask" })

        // No second row, no worktree: the review is the tab.
        #expect(fixture.controller.state.tasks.map(\.id) == [fixture.task.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.repo.path + "/.worktrees") == ["work"])
        #expect(fixture.controller.focus.selectedTaskId == fixture.task.id)
        // The task now has a merge request, so its row shows the badge.
        let saved = try #require(try fixture.controller.savedWorkspace().tasks.first)
        #expect(saved.mr == MergeRequestRef(iid: 7, title: "Work", url: "https://gitlab/x/-/merge_requests/7"))
        #expect(saved.kind == .task && saved.branch == "feat/work" && saved.worktreePath == fixture.task.worktreePath)
        #expect(fixture.controller.state.lastAgentByProject[fixture.project.id] == .claude)
    }

    /// A task whose window is closed gets it back, with the reviewer as its first tab.
    @Test func aReviewOfATaskWithoutAWindowReopensItWithTheReviewer() async throws {
        let fixture = try ReviewFixture(windowOpen: false)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)

        try await fixture.controller.createReview(draft: fixture.draft, project: fixture.project)

        let window = try #require(server.requests.first { $0.method == "window.createTask" })
        #expect(window.params["taskId"] as? String == fixture.task.id.uuidString)
        #expect(window.params["cwd"] as? String == fixture.task.worktreePath)
        #expect((window.params["agentCommand"] as? String)?.hasSuffix("'/code-review'") == true)
        #expect(!server.requests.contains { $0.method == "tab.create" })
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["reopened"])
    }

    /// The saved window id can outlive the window by a poll. iTerm2's "no such window" means it
    /// is gone, so the task gets a new one rather than the sheet an error.
    @Test func aReviewWhoseWindowJustClosedReopensIt() async throws {
        let fixture = try ReviewFixture(windowOpen: true)
        let server = RecordingDaemon(failing: ["tab.create": .notFound])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)

        try await fixture.controller.createReview(draft: fixture.draft, project: fixture.project)

        #expect(server.requests.map(\.method).filter { $0 != "sessions.setTitles" }
                == ["tab.create", "window.createTask"])
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["reopened"])
    }

    /// The task was created on `feat/work`, then its worktree moved to another branch. A review of
    /// `feat/work` must not open in that worktree — the reviewer would be looking at the other
    /// branch — and the worktree is not switched back under the task: the review gets its own.
    @Test func aReviewOfTheBranchADriftedTaskLeftGetsAWorktreeOfItsOwn() async throws {
        let fixture = try ReviewFixture(windowOpen: true)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        try fixture.git.run(["switch", "-q", "-c", "feat/other"], in: fixture.task.worktreePath)

        try await fixture.controller.createReview(draft: fixture.draft, project: fixture.project)

        #expect(!server.requests.contains { $0.method == "tab.create" })
        let window = try #require(server.requests.first { $0.method == "window.createTask" })
        let review = try #require(fixture.controller.state.tasks.first { $0.kind == .review })
        #expect(review.branch == "feat/work" && review.worktreePath != fixture.task.worktreePath)
        #expect(window.params["cwd"] as? String == review.worktreePath)
        #expect(try fixture.git.run(["branch", "--show-current"], in: fixture.task.worktreePath) == "feat/other",
                "the task's worktree stays on the branch it moved to")
    }

    /// The other direction: the branch the task's worktree moved to is that task's to review in.
    @Test func aReviewOfTheBranchADriftedTaskMovedToOpensInThatTask() async throws {
        let fixture = try ReviewFixture(windowOpen: true)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        try fixture.git.run(["switch", "-q", "-c", "feat/other"], in: fixture.task.worktreePath)
        var draft = fixture.draft
        draft.setBranch("feat/other")

        try await fixture.controller.createReview(draft: draft, project: fixture.project)

        let tab = try #require(server.requests.first { $0.method == "tab.create" })
        #expect(tab.params["cwd"] as? String == fixture.task.worktreePath)
        #expect(!server.requests.contains { $0.method == "window.createTask" })
        #expect(fixture.controller.state.tasks.map(\.id) == [fixture.task.id])
    }

    /// The sheet names the destination before anything is created. If the branch moves off the
    /// task it named, the press that would have opened it elsewhere stops and says where it goes now.
    @Test func theSheetRefusesADestinationThatMovedSinceItWasShown() async throws {
        let fixture = try ReviewFixture(windowOpen: true)
        defer { fixture.cleanUp() }
        var submitted = false
        let controller = fixture.controller, projectId = fixture.project.id
        let model = ReviewCreationModel(
            project: fixture.project, draft: fixture.draft, home: ScratchHome.bare,
            catalogue: { _ in [AgentModel(id: "sonnet", label: "Sonnet", detail: nil, efforts: [], defaultEffort: nil)] },
            defaults: ScratchDefaults.make(), git: .hermetic(),
            owningTask: { branch, checkouts in controller.state.task(checkingOut: branch, in: projectId, worktrees: checkouts) },
            searchMergeRequests: { _ in [] }, createReview: { _ in submitted = true }, recover: { _ in })
        await model.loadAgentCatalogue()
        await model.loadCheckouts()
        #expect(model.owningTask?.id == fixture.task.id)
        try fixture.git.run(["switch", "-q", "-c", "feat/other"], in: fixture.task.worktreePath)

        #expect(await model.create() == false)
        #expect(!submitted)
        #expect(model.owningTask == nil, "the sheet now shows a worktree of its own")
        #expect(model.error?.reason.contains("no longer has feat/work checked out") == true)
        // Nothing moved since: the next press goes ahead, to the destination now shown.
        #expect(await model.create() == true)
        #expect(submitted)
    }

    /// Nothing has been created when this fails, so it is the sheet's error and the draft survives
    /// for a retry — unlike a new worktree, whose recovery the workspace owns.
    @Test func aReviewInATaskWhileDisconnectedFailsWithoutTouchingTheTask() async throws {
        let fixture = try ReviewFixture(windowOpen: true)
        defer { fixture.cleanUp() }
        await #expect(throws: ActionUnavailable.self) {
            try await fixture.controller.createReview(draft: fixture.draft, project: fixture.project)
        }
        #expect(fixture.controller.state.tasks == [fixture.task])
        #expect(try fixture.controller.savedWorkspace().tasks == [fixture.task])
    }
}

@MainActor
private struct ReviewFixture {
    let root: URL
    let repo: URL
    let git = GitRunner.hermetic()
    let project: Project
    let task: TaskItem
    let draft: ReviewDraft
    let controller: AppController

    init(windowOpen: Bool) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "init"], in: repo.path)
        let checkout = repo.appendingPathComponent(".worktrees/work").path
        try git.run(["worktree", "add", "-q", "-b", "feat/work", checkout], in: repo.path)
        project = Project(id: UUID(), name: "Repo", path: repo.path, provider: .gitlab,
                          remoteUrl: nil, addedAt: Date(), collapsed: false)
        task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work",
                        worktreePath: checkout, baseBranch: "main", jira: nil, agent: .codex,
                        model: "model", reasoning: nil, firstPrompt: nil, appendTicket: false,
                        createdAt: Date(timeIntervalSince1970: 0), windowId: windowOpen ? "alive" : nil)
        var draft = ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil)
        draft.apply(mr: MergeRequest(iid: 7, title: "Work", sourceBranch: "feat/work", targetBranch: "main",
                                     author: "me", state: "opened", draft: false, url: "https://gitlab/x/-/merge_requests/7"))
        draft.promptText = "/code-review"
        self.draft = draft
        controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        controller.workspace.mutate { state in
            state.items = [.project(project)]
            state.tasks = [task]
        }
        #expect(controller.workspace.flush())
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
