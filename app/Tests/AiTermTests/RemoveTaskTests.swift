import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The person's Remove: every question first, while the window is open and the worktree there, then
/// the window, the worktree, the branch when asked for, and the row, in one go. A branch git keeps
/// is said in the toast; the row goes either way.
@MainActor @Suite(.blocking) struct RemoveTaskControllerTests {
    /// With "Delete local branch" ticked on a branch holding a commit its base lacks, Delete Branch is
    /// asked before anything closes or goes; answered, the row, the worktree and the branch go.
    @Test func anUnmergedBranchIsAskedAboutFirstAndDeleteBranchDeletesItWithTheRow() async throws {
        let (fixture, server, task) = try await removing(answering: "Remove", "Delete Branch")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        try fixture.commit(in: task.worktreePath)
        let controller = fixture.controller
        var untouchedWhileAsked = false
        fixture.prompter.whileAsking = { prompt in
            guard prompt.message == "Delete branch feat/work?" else { return }
            untouchedWhileAsked = controller.state.task(id: task.id)?.windowId == "alive"
                && server.requests("window.close").isEmpty && FileManager.default.fileExists(atPath: task.worktreePath)
        }

        await controller.remover.confirmRemove(task: task)

        #expect(fixture.prompter.asked.map(\.message) == ["Remove task “Work”?", "Delete branch feat/work?"])
        let question = try #require(fixture.prompter.asked.last)
        #expect(question.detail == "It has commits that aren’t on main. Deleting the branch deletes them too.")
        #expect(question.buttons == ["Delete Branch", "Keep Branch"] && question.defaultDeletes && question.escapeButton == 1)
        #expect(untouchedWhileAsked, "asked with the window open and the worktree there")
        #expect(controller.state.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(try !fixture.hasBranch("feat/work"))
        #expect(controller.toastState.toast?.message == "Task removed.")
        #expect(controller.issue == nil)
    }

    /// Keep Branch, or ⎋, is no cancel: the row and the worktree go, the branch stays, and the toast
    /// says nothing about a branch the person chose to keep.
    @Test(arguments: ["Keep Branch", "⎋"])
    func answeringKeepRemovesTheRowAndTheWorktreeAndLeavesTheBranch(answer: String) async throws {
        let (fixture, _, task) = try await removing(answering: "Remove", answer)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        try fixture.commit(in: task.worktreePath)

        await fixture.controller.remover.confirmRemove(task: task)

        #expect(fixture.prompter.asked.count == 2)
        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(try fixture.hasBranch("feat/work"))
        #expect(fixture.controller.toastState.toast?.message == "Task removed.")
    }

    /// Merged into its base, with the project folder on another branch, the branch has nothing to
    /// lose: no question, and it goes.
    @Test func aBranchMergedIntoItsBaseIsDeletedWithoutAsking() async throws {
        let (fixture, _, task) = try await removing(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        try fixture.commit(in: task.worktreePath)
        try fixture.git.run(["merge", "-q", "--ff-only", "feat/work"], in: fixture.repo.path)
        try fixture.git.run(["checkout", "-q", "-b", "feat/elsewhere", "main~1"], in: fixture.repo.path)

        await fixture.controller.remover.confirmRemove(task: task)

        #expect(fixture.prompter.asked.count == 1)
        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(try !fixture.hasBranch("feat/work"))
    }

    /// Pushed to its upstream and nowhere else, the branch has nothing to lose either.
    @Test func aBranchOnItsUpstreamOnlyIsDeletedWithoutAsking() async throws {
        let (fixture, _, task) = try await removing(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        try fixture.commit(in: task.worktreePath)
        let remote = fixture.root.appendingPathComponent("remote.git").path
        try fixture.git.run(["init", "-q", "--bare", remote], in: fixture.root.path)
        try fixture.git.run(["remote", "add", "origin", remote], in: fixture.repo.path)
        try fixture.git.run(["push", "-q", "-u", "origin", "feat/work"], in: task.worktreePath)

        await fixture.controller.remover.confirmRemove(task: task)

        #expect(fixture.prompter.asked.count == 1)
        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(try !fixture.hasBranch("feat/work"))
    }

    /// Delete Branch answered, git can still refuse: here the branch is checked out in the project
    /// folder, its worktree switched to another. The branch is kept, the toast says so in git's words,
    /// and the row goes.
    @Test func aBranchGitStillRefusesIsKeptAndSaidSoAndTheRowGoes() async throws {
        let (fixture, _, task) = try await removing(answering: "Remove", "Delete Branch")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        try fixture.commit(in: task.worktreePath)
        try fixture.git.run(["switch", "-q", "-c", "feat/next"], in: task.worktreePath)
        try fixture.git.run(["checkout", "-q", "feat/work"], in: fixture.repo.path)

        await fixture.controller.remover.confirmRemove(task: task)

        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(try fixture.hasBranch("feat/work"))
        let toast = try #require(fixture.controller.toastState.toast?.message)
        #expect(toast.hasPrefix("Task removed. Branch feat/work kept: "), "\(toast)")
        #expect(toast.hasSuffix(".") && !toast.hasSuffix(".."))
        #expect(fixture.controller.issue == nil)
    }

    /// A row with a window needs the helper to close it: without, nothing is deleted, and the row
    /// and the banner say why.
    @Test func aRowWithAWindowAndNoHelperIsNotRemoved() async throws {
        let fixture = try await RaceFixture(prompter: ScriptedPrompter(answering: "Remove"))
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try await fixture.addTask(windowId: "alive")

        await fixture.controller.remover.confirmRemove(task: task)

        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"])
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(try fixture.hasBranch("feat/work"))
        #expect(fixture.controller.remover.removal(of: task.id) == .stopped(note: "Not removed: iTerm2 isn’t connected"))
        #expect(fixture.controller.issue == OperationIssue(
            title: "Couldn’t remove the task.",
            reason: "iTerm2 isn’t connected, so its window couldn’t close and nothing was deleted.", subject: task.id))
    }

    /// A row without a window has nothing to close, and is removed without the helper.
    @Test func aRowWithoutAWindowIsRemovedWithoutTheHelper() async throws {
        let fixture = try await RaceFixture(prompter: ScriptedPrompter(answering: "Remove"))
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try await fixture.addTask(windowId: nil)

        await fixture.controller.remover.confirmRemove(task: task)

        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
    }

    /// A task with a window and the helper connected, "Delete local branch" ticked. `answers` start
    /// with the Remove alert's.
    private func removing(answering answers: String...) async throws -> (RaceFixture, RecordingDaemon, TaskItem) {
        let prompter = ScriptedPrompter(answering: answers)
        prompter.checksTheCheckbox = true
        let fixture = try await RaceFixture(prompter: prompter)
        let server = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        return (fixture, server, task)
    }
}

private extension RaceFixture {
    func hasBranch(_ name: String) throws -> Bool {
        try !git.run(["for-each-ref", "--format=%(refname)", "refs/heads/" + name], in: repo.path).isEmpty
    }

    func commit(in checkout: String) throws {
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "work"], in: checkout)
    }
}
