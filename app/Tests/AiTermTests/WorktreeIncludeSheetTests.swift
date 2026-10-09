import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Step 1's "Copy files listed in .worktreeinclude": what the sheet reads when it opens, when it
/// offers the checkbox, and what its tooltip says.
@Suite(.blocking) @MainActor struct WorktreeIncludeSheetTests {
    private func taskModel(_ repo: String, git: any GitRunning = GitRunner.hermetic()) -> TaskCreationModel {
        let project = Project(id: UUID(), name: "Repo", path: repo, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle("With env")
        return TaskCreationModel(project: project, draft: draft, home: ScratchHome.bare, catalogue: ScratchHome.catalogue,
                                 defaults: ScratchDefaults.make(), git: git, searchIssues: { _ in [] }, createTask: { _ in })
    }

    @Test func theSheetOffersWhatTheProjectsWorktreeIncludeSelects() async throws {
        let repo = try GitFixture.makeRepo(prefix: "wis-")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try ".env\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        try ".env\n".write(toFile: repo + "/.worktreeinclude", atomically: true, encoding: .utf8)
        try "A=1\n".write(toFile: repo + "/.env", atomically: true, encoding: .utf8)
        let model = taskModel(repo)
        #expect(model.worktreeIncludes.isEmpty, "nothing until it is read")
        await model.loadWorktreeIncludes()
        #expect(model.worktreeIncludes == [".env"])
        #expect(model.draft.copiesWorktreeInclude, "ticked")
    }

    /// No file, no checkbox — and opening the sheet asks git nothing more than it did.
    @Test func aProjectWithoutTheFileOffersNothingAndAsksGitNothing() async throws {
        let repo = try GitFixture.makeRepo(prefix: "wis-")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let recording = RecordingGitRunner(forwardingTo: GitRunner.hermetic())
        let model = taskModel(repo, git: recording)
        await model.loadWorktreeIncludes()
        #expect(model.worktreeIncludes.isEmpty)
        #expect(recording.calls.isEmpty)
    }

    /// A review that opens in the task that has its branch makes no worktree, so it offers nothing.
    @Test func aReviewOffersTheFilesOnlyWhenItGetsAWorktree() {
        let owner = TaskItem(id: UUID(), projectId: UUID(), title: "Gift card", branch: "feat/gift-card",
                             worktreePath: "/p/.worktrees/gift-card", baseBranch: "main", jira: nil,
                             agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: true,
                             createdAt: Date(), windowId: nil)
        #expect(NewReviewSheet.worktreeIncludes([".env"], owner: nil) == [".env"])
        #expect(NewReviewSheet.worktreeIncludes([".env"], owner: owner).isEmpty)
    }

    /// The tooltip is the files, one a line; past `namedInHelp`, how many more.
    @Test func theTooltipListsTheFiles() {
        #expect(WorktreeIncludeToggle.help([".env", "certs/dev.pem"]) == ".env\ncerts/dev.pem")
        let many = (1...14).map { "f\($0)" }
        #expect(WorktreeIncludeToggle.help(many) == (1...12).map { "f\($0)" }.joined(separator: "\n") + "\nand 2 more")
    }
}
