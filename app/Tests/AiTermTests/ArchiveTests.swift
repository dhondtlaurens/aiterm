import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore

extension AppControllerTests {
    @Test func archivingClosesTheWindowRemovesTheWorktreeKeepsTheBranchAndMovesTheRow() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")

        let archiving = await controller.archive(task: task)
        await archiving?.value

        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["alive"])
        #expect(controller.state.tasks.isEmpty)
        #expect(controller.state.archive.map(\.id) == [task.id])
        #expect(controller.state.archive.first?.task.windowId == nil)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(!(try fixture.git.run(["branch", "--list", "feat/work"], in: fixture.repo.path)).isEmpty, "the branch stays")
        #expect(controller.toastState.toast?.message == "Task archived.")
        #expect(try controller.savedWorkspace().archive.map(\.id) == [task.id], "on disk")
    }

    @Test func archivingADirtyWorktreeAsksAndKeepLeavesTheTaskAsItWas() async throws {
        let prompter = ScriptedPrompter(answering: "Keep Task")
        let fixture = try RaceFixture(prompter: prompter)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        try "wip".write(toFile: task.worktreePath + "/wip.txt", atomically: true, encoding: .utf8)

        await (await fixture.controller.archive(task: task))?.value

        let asked = try #require(prompter.asked.first)
        #expect(asked.buttons == ["Keep Task", "Delete Changes and Archive"])
        #expect(asked.detail == "Archiving deletes its uncommitted changes and untracked files. The branch is kept.")
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"])
        #expect(server.requests("window.close").isEmpty)
        #expect(fixture.controller.removal(of: task.id) == nil, "kept before anything moved: no note")
    }

    @Test func deleteChangesAndArchiveArchivesTheDirtyWorktree() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Delete Changes and Archive"))
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        try "wip".write(toFile: task.worktreePath + "/wip.txt", atomically: true, encoding: .utf8)
        await (await fixture.controller.archive(task: task))?.value
        #expect(fixture.controller.state.archive.map(\.id) == [task.id])
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func aDetachedWorktreeIsNotArchived() async throws {
        let prompter = ScriptedPrompter(answering: "OK")
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        try fixture.git.run(["checkout", "-q", "--detach"], in: task.worktreePath)
        await (await fixture.controller.archive(task: task))?.value
        #expect(prompter.asked.first?.message == "“Work” can’t be archived")
        #expect(fixture.controller.state.tasks.map(\.id) == [task.id])
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func withoutADaemonAWindowedTaskIsNotArchived() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try fixture.addTask(windowId: "alive")
        await (await fixture.controller.archive(task: task))?.value
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"])
        #expect(fixture.controller.removal(of: task.id) == .stopped(note: "Not archived: iTerm2 isn’t connected", worktreeRemoved: false))
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func aWindowThatWillNotCloseStopsTheArchiveAndIsGivenBack() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(failing: ["window.close": .itermUnavailable])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        await (await fixture.controller.archive(task: task))?.value
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"])
        #expect(fixture.controller.removal(of: task.id) == .stopped(note: "Not archived: its window did not close", worktreeRemoved: false))
    }

    @Test func anUnreadableProjectFolderStopsTheArchiveWithNothingMoved() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent(".git"))
        await (await fixture.controller.archive(task: task))?.value
        #expect(fixture.controller.state.tasks.map(\.id) == [task.id])
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"], "its window too")
        #expect(fixture.controller.state.archive.isEmpty)
        #expect(fixture.controller.removal(of: task.id) == .stopped(note: "Not archived", worktreeRemoved: false))
    }

    @Test func anArchiveThatCannotBeSavedLeavesTheWorktreeAndTheTask() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")

        let archiving = await controller.archive(task: task)
        try await server.received("window.close")
        // Saving breaks while the window closes: a directory stands where the backup goes.
        let backup = controller.workspace.file.backupURL
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        server.release()
        await archiving?.value

        #expect(controller.persistenceError != nil)
        #expect(controller.state.tasks.map(\.id) == [task.id], "a task again, owed its window")
        #expect(controller.state.archive.isEmpty)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath), "nothing deleted")
        #expect(controller.removal(of: task.id) == .stopped(note: "Not archived", worktreeRemoved: false))
        #expect(controller.toastState.toast == nil)
    }

    @Test func archivingTwiceAtOnceArchivesOnce() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        let first = await fixture.controller.archive(task: task)
        let second = await fixture.controller.archive(task: task)
        #expect(first != nil && second == nil)
        server.release()
        await first?.value
        #expect(fixture.controller.state.archive.count == 1)
    }

    @Test func aRowWaitingOnItsRemovalsRetryIsNotArchived() async throws {
        let prompter = ScriptedPrompter(answering: "Remove")
        prompter.checksTheCheckbox = true
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: nil)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "work"],
                            in: task.worktreePath)
        await controller.confirmRemove(task: task)?.value
        #expect(controller.removals[task.id]?.awaitsRetry == true, "removed up to its unmerged branch")

        #expect(await controller.archive(task: task) == nil)
        #expect(controller.removals[task.id] == .stopped(note: "Not removed: branch kept", worktreeRemoved: true), "its retry still held")
    }

    @Test func uncommittedWorkWrittenWhileTheWindowClosesIsAskedAboutAndKeepPutsTheTaskBack() async throws {
        // The first question is not asked: the worktree was clean when it was checked.
        let prompter = ScriptedPrompter(answering: "Keep Task")
        let fixture = try RaceFixture(prompter: prompter)
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")

        let archiving = await controller.archive(task: task)
        try await server.received("window.close")
        try "wip".write(toFile: task.worktreePath + "/wip.txt", atomically: true, encoding: .utf8)
        server.release()
        await archiving?.value

        #expect(prompter.asked.map(\.buttons) == [["Keep Task", "Delete Changes and Archive"]])
        #expect(controller.state.tasks.map(\.id) == [task.id])
        #expect(controller.state.tasks.map(\.windowId) == [nil], "owed its window")
        #expect(controller.removal(of: task.id) == .stopped(note: "Not archived", worktreeRemoved: false))
        #expect(controller.state.archive.isEmpty)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/wip.txt"))
    }

    @Test func uncommittedWorkWrittenWhileTheWindowClosesIsDeletedOnDeleteChangesAndArchive() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Delete Changes and Archive"))
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")

        let archiving = await controller.archive(task: task)
        try await server.received("window.close")
        try "wip".write(toFile: task.worktreePath + "/wip.txt", atomically: true, encoding: .utf8)
        server.release()
        await archiving?.value

        #expect(controller.state.archive.map(\.id) == [task.id])
        #expect(controller.state.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func restoringBringsTheWorktreeAndRowBackAndItsWindowWithItsConversations() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        var task = try fixture.addTask(windowId: "alive")
        controller.workspace.mutate { $0.tasks[0].conversations = [TaskConversation(agent: .codex, id: "conv-1")] }
        task = controller.state.tasks[0]
        await (await controller.archive(task: task))?.value
        controller.workspace.mutate { $0.updateProject(id: fixture.project.id) { $0.collapsed = true } }
        // iTerm2's windows read, so a chosen row's owed window can open: with no snapshot yet, AiTerm
        // waits for one instead.
        controller.helper.handle(.snapshot(AppControllerTests.emptySnapshot))

        await controller.restoreArchived(task.id)?.value
        await controller.windows.lastRestore?.value

        #expect(controller.state.archive.isEmpty)
        #expect(controller.state.tasks.map(\.id) == [task.id])
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(controller.state.project(id: fixture.project.id)?.collapsed == false, "its project opens")
        #expect(controller.focus.isSelected(task.id))
        let created = try #require(server.requests("window.createTask").first)
        #expect((created.params["agentCommand"] as? String)?.contains("conv-1") == true, "its conversation resumes")
        #expect(controller.toastState.toast?.message == "Task restored.")
    }

    @Test func aRestoreGitRefusesSaysWhyAndLeavesTheRowArchived() async throws {
        let prompter = ScriptedPrompter(answering: "OK")
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        await (await fixture.controller.archive(task: task))?.value
        try fixture.git.run(["branch", "-D", "feat/work"], in: fixture.repo.path)

        await fixture.controller.restoreArchived(task.id)?.value

        #expect(prompter.asked.last?.message == "“Work” can’t be restored")
        #expect(prompter.asked.last?.detail.contains("no longer exists here or on origin") == true)
        #expect(fixture.controller.state.archive.map(\.id) == [task.id])
        #expect(fixture.controller.state.tasks.isEmpty)
    }

    @Test func aProjectCannotBeRemovedWhileOneOfItsArchivedRowsIsRestoring() async throws {
        // "OK" answers "“Repo” can’t be removed yet": the refusal comes before the question.
        let prompter = ScriptedPrompter(answering: "OK")
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        await (await controller.archive(task: task))?.value
        let restoring = controller.restoreArchived(task.id)
        // The project cannot be removed while its archived row is restoring.
        await controller.confirmRemove(project: fixture.project)
        #expect(prompter.asked.map(\.message) == ["“Repo” can’t be removed yet"])
        #expect(controller.state.project(id: fixture.project.id) != nil)
        await restoring?.value
        #expect(controller.state.tasks.map(\.id) == [task.id])
    }

    /// Git's removal of the worktree has no seam to hold, so the row is put where an archive leaves it
    /// while git runs: in the archive, its `.archiving` work begun.
    @Test func aProjectCannotBeRemovedWhileOneOfItsRowsIsBeingArchived() async throws {
        let prompter = ScriptedPrompter(answering: "OK")
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: nil)
        controller.workspace.mutate { $0.moveToArchive(taskId: task.id, branch: task.branch, at: Date()) }
        let begun = controller.work.begin(.archiving(windowLetGo: true), onTask: task.id)
        let token = try #require(begun)
        defer { controller.work.end(token) }

        await controller.confirmRemove(project: fixture.project)

        #expect(prompter.asked.map(\.message) == ["“Repo” can’t be removed yet"])
        #expect(prompter.asked.first?.detail == "One of its archived tasks is still being archived, restored or removed. Try again in a moment.")
        #expect(controller.state.project(id: fixture.project.id) != nil)
        #expect(controller.state.archive.map(\.id) == [task.id])
    }

    @Test func restoringTwiceAtOnceRestoresOnce() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        await (await fixture.controller.archive(task: task))?.value
        let first = fixture.controller.restoreArchived(task.id), second = fixture.controller.restoreArchived(task.id)
        #expect(first != nil && second == nil)
        await first?.value
        #expect(fixture.controller.state.tasks.count == 1)
    }

    @Test func removingFromTheArchiveAsksRemovesQuestionAndForgetsTheRowKeepingTheBranchUnlessTicked() async throws {
        let prompter = ScriptedPrompter(answering: "Remove")
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: nil)
        await (await fixture.controller.archive(task: task))?.value

        await (await fixture.controller.confirmRemove(archived: task.id))?.value

        let asked = try #require(prompter.asked.last)
        #expect(asked.message == "Remove task “Work”?")
        #expect(asked.detail == "Forgets it and its conversations. Its worktree was deleted when it was archived.")
        #expect(asked.checkbox == "Delete local branch")
        #expect(fixture.controller.state.archive.isEmpty)
        #expect(!(try fixture.git.run(["branch", "--list", "feat/work"], in: fixture.repo.path)).isEmpty)
        #expect(fixture.controller.toastState.toast?.message == "Task removed.")
    }

    @Test func removingFromTheArchiveNeverTouchesWhatNowSitsInItsOldFolder() async throws {
        let prompter = ScriptedPrompter(answering: "Remove")
        prompter.checksTheCheckbox = true
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: nil)
        await (await fixture.controller.archive(task: task))?.value
        try FileManager.default.createDirectory(atPath: task.worktreePath, withIntermediateDirectories: true)
        try "someone else's".write(toFile: task.worktreePath + "/f.txt", atomically: true, encoding: .utf8)

        await (await fixture.controller.confirmRemove(archived: task.id))?.value

        #expect(try String(contentsOfFile: task.worktreePath + "/f.txt", encoding: .utf8) == "someone else's")
        #expect(fixture.controller.state.archive.isEmpty)
    }

    @Test func removingAnArchivedRowWhoseBranchHoldsUnmergedCommitsAsksBeforeDeletingIt() async throws {
        let prompter = ScriptedPrompter(answering: "Remove", "Delete Branch")
        prompter.checksTheCheckbox = true
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: nil)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "work"],
                            in: task.worktreePath)
        await (await fixture.controller.archive(task: task))?.value

        await (await fixture.controller.confirmRemove(archived: task.id))?.value

        let asked = try #require(prompter.asked.last)
        #expect(asked.message == "Delete branch feat/work?")
        #expect(fixture.controller.state.archive.isEmpty)
        #expect(try fixture.git.run(["branch", "--list", "feat/work"], in: fixture.repo.path).isEmpty)
    }

    @Test func decliningTheUnmergedBranchQuestionKeepsTheBranchAndStillForgetsTheRow() async throws {
        let prompter = ScriptedPrompter(answering: "Remove", "Cancel")
        prompter.checksTheCheckbox = true
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: nil)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "work"],
                            in: task.worktreePath)
        await (await fixture.controller.archive(task: task))?.value

        await (await fixture.controller.confirmRemove(archived: task.id))?.value

        #expect(fixture.controller.state.archive.isEmpty)
        #expect(!(try fixture.git.run(["branch", "--list", "feat/work"], in: fixture.repo.path)).isEmpty)
    }

    @Test func aBranchGitWillNotDeleteForAnotherReasonIsSaidKeptAndTheRowStillGoes() async throws {
        let prompter = ScriptedPrompter(answering: "Remove")
        prompter.checksTheCheckbox = true
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: nil)
        await (await fixture.controller.archive(task: task))?.value
        // Checked out in the project's own folder, the branch cannot be deleted — and not for want of a merge.
        try fixture.git.run(["checkout", "-q", "feat/work"], in: fixture.repo.path)

        await (await fixture.controller.confirmRemove(archived: task.id))?.value

        let issue = try #require(fixture.controller.issue)
        #expect(issue.title == "Branch feat/work kept.")
        #expect(issue.actions.isEmpty)
        #expect(fixture.controller.state.archive.isEmpty)
        #expect(!(try fixture.git.run(["branch", "--list", "feat/work"], in: fixture.repo.path)).isEmpty)
    }

    @Test func aBranchThatCannotBeDeletedAfterTheUnmergedQuestionSaysTheRemovalFailedAndLeavesTheRowArchived() async throws {
        let prompter = ScriptedPrompter(answering: "Remove", "Delete Branch")
        prompter.checksTheCheckbox = true
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: nil)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "work"],
                            in: task.worktreePath)
        await (await fixture.controller.archive(task: task))?.value
        // While the question is up the branch is checked out in the project's folder, so `-D` fails.
        let git = fixture.git, repo = fixture.repo
        prompter.whileAsking = { prompt in
            if prompt.message == "Delete branch feat/work?" { try? git.run(["checkout", "-q", "feat/work"], in: repo.path) }
        }

        await (await fixture.controller.confirmRemove(archived: task.id))?.value

        #expect(fixture.controller.issue?.title == "Couldn’t remove the task.")
        #expect(fixture.controller.state.archive.map(\.id) == [task.id], "nothing is forgotten when the removal failed")
    }

    @Test func removingAProjectSaysHowManyArchivedRowsItForgets() {
        func archived(_ kind: TaskKind) -> ArchivedTask {
            ArchivedTask(task: TaskItem(id: UUID(), projectId: UUID(), title: "t", branch: "b", worktreePath: "/w", baseBranch: "main",
                                        jira: nil, kind: kind, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil,
                                        appendTicket: false, createdAt: Date(), windowId: nil), archivedAt: Date())
        }
        #expect(ProjectActions.removalDetail(tasks: 0, archived: [])
                == "Removes the project from AiTerm. Files are kept and terminal windows stay open.")
        #expect(ProjectActions.removalDetail(tasks: 4, archived: [])
                == "Removes the project and its 4 tasks from AiTerm. Files, worktrees and windows are kept.")
        #expect(ProjectActions.removalDetail(tasks: 4, archived: Array(repeating: archived(.task), count: 12))
                == "Removes the project and its 4 tasks from AiTerm, and forgets its 12 archived tasks and reviews. Files, branches, worktrees and windows are kept.")
        #expect(ProjectActions.removalDetail(tasks: 0, archived: [archived(.review)])
                == "Removes the project from AiTerm, and forgets its archived review. Files are kept and terminal windows stay open.")
    }
}
