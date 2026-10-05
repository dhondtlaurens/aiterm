import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

/// The banner a failed operation raises: what it says, the ways out it offers, and how long it
/// stays. Removing a task whose branch has commits its base lacks is the case with ways out.
extension AppControllerTests {
    @Test func aBranchKeptForUnmergedWorkIsReportedWithItsWaysOut() async throws {
        let (fixture, task) = try await removedWithUnmergedBranch(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        #expect(fixture.controller.issue == OperationIssue(
            title: "Branch feat/work kept.", reason: "It has commits that aren’t on main.",
            actions: [.keepBranch(task.id), .deleteBranch(task.id)], subject: task.id))
        #expect(fixture.controller.removals[task.id] == .stopped(note: "Not removed: branch kept", worktreeRemoved: true))
        #expect(fixture.controller.state.tasks.map(\.id) == [task.id], "the row stays for the answer")
    }

    @Test func keepBranchFinishesTheRemovalAndLeavesTheBranch() async throws {
        let (fixture, task) = try await removedWithUnmergedBranch(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        await fixture.controller.perform(.keepBranch(task.id))?.value

        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(fixture.controller.issue == nil)
        #expect(try fixture.hasBranch("feat/work"))
        #expect(fixture.prompter.asked.count == 1, "keeping loses nothing, so it asks nothing")
    }

    @Test func deleteBranchAsksFirstThenDropsTheBranch() async throws {
        let (fixture, task) = try await removedWithUnmergedBranch(answering: "Remove", "Delete Branch")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        await fixture.controller.perform(.deleteBranch(task.id))?.value

        #expect(fixture.prompter.asked.last?.message == "Delete branch feat/work?")
        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(fixture.controller.issue == nil)
        #expect(try !fixture.hasBranch("feat/work"))
    }

    @Test func cancellingDeleteBranchChangesNothing() async throws {
        let (fixture, task) = try await removedWithUnmergedBranch(answering: "Remove", "Cancel")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let before = fixture.controller.issue

        #expect(fixture.controller.perform(.deleteBranch(task.id)) == nil)

        #expect(fixture.controller.state.tasks.map(\.id) == [task.id])
        #expect(fixture.controller.issue == before)
        #expect(try fixture.hasBranch("feat/work"))
    }

    /// Retrying from the row's menu, without the checkbox, removes the task; the banner about it
    /// goes with it rather than asking for a retry that already happened.
    @Test func theIssueGoesWithTheTaskItIsAbout() async throws {
        let (fixture, task) = try await removedWithUnmergedBranch(answering: "Remove", "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.prompter.checksTheCheckbox = false

        await fixture.controller.confirmRemove(task: task)?.value

        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(fixture.controller.issue == nil)
        #expect(fixture.controller.removals.isEmpty)
        #expect(fixture.controller.perform(.keepBranch(task.id)) == nil, "nothing is left to keep")
    }

    /// Dismissing hides the banner, but the removal still waits on a retry, and its row says so.
    @Test func dismissingClearsTheIssueButNotTheRowsNote() async throws {
        let (fixture, task) = try await removedWithUnmergedBranch(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        fixture.controller.dismissIssue()

        #expect(fixture.controller.issue == nil)
        #expect(fixture.controller.removals[task.id]?.awaitsRetry == true)
    }

    /// A report that cannot outrank the question leaves it up; the row keeps its note, and the kept branch its answer.
    @Test func aLaterReportLeavesTheRowWaitingOnItsRetry() async throws {
        let (fixture, task) = try await removedWithUnmergedBranch(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        fixture.controller.report("Couldn’t show the window.")
        #expect(fixture.controller.removals[task.id] == .stopped(note: "Not removed: branch kept", worktreeRemoved: true))
        await fixture.controller.perform(.keepBranch(task.id))?.value

        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(fixture.controller.removals.isEmpty)
    }

    /// A background report with nothing to offer — an activation that failed, a send that did not
    /// go — does not take the banner from a question that still waits on its answer.
    @Test func aReportWithNoActionsLeavesAPendingQuestionShowing() async throws {
        let (fixture, task) = try await removedWithUnmergedBranch(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let question = fixture.controller.issue
        #expect(question?.actions.isEmpty == false)

        fixture.controller.report("Couldn’t show the window.")
        fixture.controller.report(OperationIssue(title: "Couldn’t reopen the window.", reason: "Nope.", subject: task.id))

        #expect(fixture.controller.issue == question)
    }

    /// Anything else still replaces: no question, another question, or a plain message over one.
    @Test func aNewerReportReplacesWhatItDoesNotOutrank() async throws {
        let (fixture, task) = try await removedWithUnmergedBranch(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let rebase = OperationIssue(title: "Couldn’t pull the default branch.", actions: [.rebaseDefault(fixture.project.id)])

        controller.report(rebase)
        #expect(controller.issue == rebase, "a question replaces a question")
        controller.dismissIssue()
        controller.report("First.")
        controller.report("Second.")
        #expect(controller.issue == OperationIssue(title: "Second."), "a message replaces a message")
        #expect(controller.removals[task.id]?.awaitsRetry == true, "the row's retry never rode on the banner")
    }

    /// A removal that stopped with nothing deleted says so on its row only while its banner is up.
    /// Once another report takes the banner the row is a task again, not an amber note for good.
    @Test func aReportThatReplacesAnIssueClearsItsTasksStoppedNote() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: nil)
        controller.seedSnapshotRemoval(.stopped(note: "Not removed", worktreeRemoved: false), of: task.id)
        controller.report(OperationIssue(title: "Couldn’t remove the task.", reason: "Busy.", subject: task.id))

        controller.report("Something else.")

        #expect(controller.issue?.title == "Something else.")
        #expect(controller.removals[task.id] == nil)
    }

    /// The removal that fails again reports the same task: its new note must not go with its old banner.
    @Test func aRepeatedFailureForTheSameTaskKeepsItsNewNote() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: nil)
        controller.report(OperationIssue(title: "Couldn’t remove the task.", reason: "Busy.", subject: task.id))
        let note = TaskRemoval.stopped(note: "Not removed", worktreeRemoved: false)
        controller.seedSnapshotRemoval(note, of: task.id)

        controller.report(OperationIssue(title: "Couldn’t remove the task.", reason: "Still busy.", subject: task.id))

        #expect(controller.issue?.reason == "Still busy.")
        #expect(controller.removals[task.id] == note)
    }

    /// A report that is dropped replaces nothing, so the row's note stays: it is still true.
    @Test func aDroppedReportLeavesAStoppedNoteBe() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: nil)
        let note = TaskRemoval.stopped(note: "Not removed", worktreeRemoved: false)
        controller.seedSnapshotRemoval(note, of: task.id)
        controller.report(OperationIssue(title: "Rebase?", actions: [.rebaseDefault(fixture.project.id)]))

        controller.report(OperationIssue(title: "Couldn’t remove the task.", reason: "Busy.", subject: task.id))

        #expect(controller.removals[task.id] == note)
    }

    /// Reopening is doing what "Kept; choose Reopen Window" said, so the note has done its job.
    @Test func reopeningATaskClearsItsKeptNote() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: nil)
        controller.seedSnapshotRemoval(.stopped(note: "Kept; choose Reopen Window", worktreeRemoved: false), of: task.id)

        await controller.reopen(task: task)?.value

        #expect(controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(controller.removals[task.id] == nil)
    }

    /// A reopen that fails changed nothing about why the removal stopped.
    @Test func aFailedReopenKeepsTheNote() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon(failing: ["window.createTask": "temporary_failure"]))
        let task = try fixture.addTask(windowId: nil)
        let note = TaskRemoval.stopped(note: "Kept; choose Reopen Window", worktreeRemoved: false)
        controller.seedSnapshotRemoval(note, of: task.id)

        await controller.reopen(task: task)?.value

        #expect(controller.state.task(id: task.id)?.windowId == nil)
        #expect(controller.removals[task.id] == note)
    }

    /// The row can go by other ways than its removal's; the banner about it and its note go too.
    @Test func theIssueGoesWhenItsRowsWindowCloses() async throws {
        let (fixture, task) = try await removedWithUnmergedBranch(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.state.tasks[0].windowId = "w"

        fixture.controller.handleWindowClosed("w")

        #expect(fixture.controller.state.task(id: task.id) == nil)
        #expect(fixture.controller.issue == nil)
        #expect(fixture.controller.removals.isEmpty)
    }

    @Test func theIssueGoesWithItsProject() async throws {
        let (fixture, _) = try await removedWithUnmergedBranch(answering: "Remove", "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        fixture.controller.confirmRemove(project: fixture.project)

        #expect(fixture.controller.state.projects.isEmpty)
        #expect(fixture.controller.issue == nil)
        #expect(fixture.controller.removals.isEmpty)
    }

    @Test func theIssueGoesWhenABackupWithoutItsRowIsRestored() async throws {
        let (fixture, _) = try await removedWithUnmergedBranch(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        var without = fixture.controller.state
        without.tasks = []
        // Saved twice, so the backup — the file as it was before a save — has no task either.
        try fixture.controller.store.save(without)
        try fixture.controller.store.save(without)

        try fixture.controller.restoreWorkspace()

        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(fixture.controller.issue == nil)
        #expect(fixture.controller.removals.isEmpty)
    }

    /// A refusal AiTerm has no words of its own for keeps git's, and offers only Keep Branch: `-D`
    /// would not answer it.
    @Test func anyOtherRefusalKeepsGitsReasonAndOffersOnlyKeep() {
        let id = UUID()
        let issue = OperationIssue.branchKept("feat/work", of: id, because: .other(reason: "Cannot delete branch 'feat/work'."))
        #expect(issue == OperationIssue(title: "Branch feat/work kept.", reason: "Cannot delete branch 'feat/work'.",
                                        actions: [.keepBranch(id)], subject: id))
    }

    /// A failure's own words go in the title and the error's in the reason, never joined: git's by
    /// its sentence rule, anything else by its description.
    @Test func anErrorIsTheReasonNotPartOfTheTitle() {
        let daemon = OperationIssue(title: "Couldn’t reopen the window.", error: DaemonError(code: "x", message: "iTerm2 is busy"))
        #expect(daemon == OperationIssue(title: "Couldn’t reopen the window.", reason: "iTerm2 is busy"))
        let git = GitError(args: ["worktree", "remove"], code: 128, stderr: "fatal: not a working tree")
        #expect(OperationIssue(title: "Couldn’t remove the task.", error: git).reason == "Not a working tree.")
    }

    /// A task, its worktree removed with "Also delete branch" ticked, and its branch kept because it
    /// has a commit `main` lacks. `answers` start with the Remove alert's.
    private func removedWithUnmergedBranch(answering answers: String...) async throws -> (RaceFixture, TaskItem) {
        let prompter = ScriptedPrompter(answering: answers)
        prompter.checksTheCheckbox = true
        let fixture = try RaceFixture(prompter: prompter)
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: nil)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "work"],
                            in: task.worktreePath)
        await fixture.controller.confirmRemove(task: task)?.value
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        return (fixture, task)
    }
}

private extension RaceFixture {
    func hasBranch(_ name: String) throws -> Bool {
        try !git.run(["for-each-ref", "--format=%(refname)", "refs/heads/" + name], in: repo.path).isEmpty
    }
}
