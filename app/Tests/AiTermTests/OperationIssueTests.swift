import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The banner a failed operation raises: what it says, the ways out it offers, and how long it
/// stays. A pull that found the default branch diverged is the case with a way out, Rebase.
@MainActor @Suite(.blocking) struct OperationIssueControllerTests {
    /// A background report with nothing to offer — an activation that failed, a send that did not
    /// go — does not take the banner from a question that still waits on its answer.
    @Test func aReportWithNoActionsLeavesAPendingQuestionShowing() async throws {
        let (fixture, task) = try await askingRebase()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let question = fixture.controller.issue
        #expect(question?.actions.isEmpty == false)

        fixture.controller.notices.report("Couldn’t show the window.")
        fixture.controller.notices.report(OperationIssue(title: "Couldn’t reopen the window.", reason: "Nope.", subject: task.id))

        #expect(fixture.controller.issue == question)
    }

    /// Anything else still replaces: no question, another question, or a plain message over one.
    @Test func aNewerReportReplacesWhatItDoesNotOutrank() async throws {
        let (fixture, _) = try await askingRebase()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let rebase = OperationIssue(title: "Couldn’t pull the default branch again.", actions: [.rebaseDefault(fixture.project.id)])

        controller.notices.report(rebase)
        #expect(controller.issue == rebase, "a question replaces a question")
        controller.notices.dismissIssue()
        controller.notices.report("First.")
        controller.notices.report("Second.")
        #expect(controller.issue == OperationIssue(title: "Second."), "a message replaces a message")
    }

    /// A removal that stopped with nothing deleted says so on its row only while its banner is up.
    /// Once another report takes the banner the row is a task again, not an amber note for good.
    @Test func aReportThatReplacesAnIssueClearsItsTasksStoppedNote() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try await fixture.addTask(windowId: nil)
        controller.remover.seedSnapshotRemoval(.stopped(note: "Not removed"), of: task.id)
        controller.notices.report(OperationIssue(title: "Couldn’t remove the task.", reason: "Busy.", subject: task.id))

        controller.notices.report("Something else.")

        #expect(controller.issue?.title == "Something else.")
        #expect(controller.remover.removals[task.id] == nil)
    }

    /// The removal that fails again reports the same task: its new note must not go with its old banner.
    @Test func aRepeatedFailureForTheSameTaskKeepsItsNewNote() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try await fixture.addTask(windowId: nil)
        controller.notices.report(OperationIssue(title: "Couldn’t remove the task.", reason: "Busy.", subject: task.id))
        let note = TaskRemoval.stopped(note: "Not removed")
        controller.remover.seedSnapshotRemoval(note, of: task.id)

        controller.notices.report(OperationIssue(title: "Couldn’t remove the task.", reason: "Still busy.", subject: task.id))

        #expect(controller.issue?.reason == "Still busy.")
        #expect(controller.remover.removals[task.id] == note)
    }

    /// A report held back replaces nothing, so the row's note stays while it waits: it is still true.
    @Test func aHeldBackReportLeavesAStoppedNoteBe() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try await fixture.addTask(windowId: nil)
        let note = TaskRemoval.stopped(note: "Not removed")
        controller.remover.seedSnapshotRemoval(note, of: task.id)
        controller.notices.report(OperationIssue(title: "Rebase?", actions: [.rebaseDefault(fixture.project.id)]))

        controller.notices.report(OperationIssue(title: "Couldn’t remove the task.", reason: "Busy.", subject: task.id))

        #expect(controller.remover.removals[task.id] == note)
    }

    /// What a click failed with while a question was up is not lost: it takes the banner when the
    /// question goes, and its row note then goes with it by the usual rule.
    @Test func aHeldBackReportAppearsOnceTheQuestionIsDismissed() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try await fixture.addTask(windowId: nil)
        controller.remover.seedSnapshotRemoval(.stopped(note: "Not removed"), of: task.id)
        controller.notices.report(OperationIssue(title: "Rebase?", actions: [.rebaseDefault(fixture.project.id)]))
        let failure = OperationIssue(title: "Couldn’t remove the task.", reason: "Busy.", subject: task.id)
        controller.notices.report(failure)

        controller.notices.dismissIssue()
        #expect(controller.issue == failure)
        #expect(controller.remover.removals[task.id] != nil, "its note stays while its banner shows")

        controller.notices.dismissIssue()
        #expect(controller.issue == nil)
        #expect(controller.remover.removals[task.id] == nil)
    }

    @Test func theNewestHeldBackReportIsTheOneShown() async throws {
        let (fixture, _) = try await askingRebase()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        fixture.controller.notices.report("First.")
        fixture.controller.notices.report("Second.")
        fixture.controller.notices.dismissIssue()

        #expect(fixture.controller.issue == OperationIssue(title: "Second."))
        fixture.controller.notices.dismissIssue()
        #expect(fixture.controller.issue == nil, "only the newest was kept")
    }

    /// A held-back report about a row that has gone meanwhile is not worth showing.
    @Test func aHeldBackReportForARowThatWentIsDropped() async throws {
        let (fixture, _) = try await askingRebase()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let other = TaskItem.make(project: fixture.project.id, title: "Other", branch: "feat/other",
            worktreePath: fixture.root.path + "/other", agent: .codex, model: "model", windowId: "w")
        fixture.controller.workspace.mutate { $0.tasks.append(other) }
        fixture.controller.notices.report(OperationIssue(title: "Couldn’t reopen the window.", subject: other.id))

        fixture.controller.workspace.mutate { state in state.tasks.removeAll { $0.id == other.id } }
        fixture.controller.notices.dismissIssue()

        #expect(fixture.controller.issue == nil)
    }

    /// A task's window opened takes down the banner that said the task was kept.
    @Test func openingATaskTakesDownTheBannerAboutIt() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: nil)
        controller.notices.report(OperationIssue(title: "Couldn’t remove the task.", subject: task.id))

        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        await controller.choose(.task(task.id))?.value

        #expect(controller.issue == nil)
    }

    /// A failure about the task held back behind a question about it is as answered by the open:
    /// taking the question down must not put the failure up in its place.
    @Test func openingATaskDropsAReportAboutItHeldBehindTheBanner() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: nil)
        controller.notices.report(OperationIssue(title: "Rebase?", actions: [.rebaseDefault(fixture.project.id)], subject: task.id))
        controller.notices.report(OperationIssue(title: "Couldn’t reopen the window.", reason: "Busy.", subject: task.id))

        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        await controller.choose(.task(task.id))?.value

        #expect(controller.issue == nil)
    }

    @Test func theIssueGoesWithItsProject() async throws {
        let (fixture, _) = try await askingRebase(answering: "Remove")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        await fixture.controller.projects.confirmRemove(project: fixture.project)

        #expect(fixture.controller.state.projects.isEmpty)
        #expect(fixture.controller.issue == nil)
    }

    @Test func theIssueGoesWhenABackupWithoutItsRowIsRestored() async throws {
        let (fixture, _) = try await askingRebase()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        var without = fixture.controller.state
        without.tasks = []
        // Saved twice, so the backup — the file as it was before a save — has no task either.
        try fixture.controller.workspace.file.save(without)
        try fixture.controller.workspace.file.save(without)

        try fixture.controller.workspace.restoreBackup()

        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(fixture.controller.issue == nil)
        #expect(fixture.controller.remover.removals.isEmpty)
    }

    /// A task, and the banner asking whether to rebase the project's default branch, about the task
    /// so that it goes with its row. `answers` are for what the test asks after.
    private func askingRebase(answering answers: String...) async throws -> (RaceFixture, TaskItem) {
        let fixture = try await RaceFixture(prompter: ScriptedPrompter(answering: answers))
        let task = try await fixture.addTask(windowId: nil)
        fixture.controller.notices.report(OperationIssue(title: "Couldn’t pull the default branch.",
                                                         actions: [.rebaseDefault(fixture.project.id)], subject: task.id))
        return (fixture, task)
    }
}
