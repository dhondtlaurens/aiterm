import Foundation
import Synchronization
import Testing
@testable import AiTermTestSupport
@testable import AiTerm
@testable import AiTermCore

@MainActor @Suite(.blocking) struct ArchiveControllerTests {
    @Test func archivingClosesTheWindowRemovesTheWorktreeKeepsTheBranchAndMovesTheRow() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")

        await controller.archiver.archive(task: task)

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
        let fixture = try await RaceFixture(prompter: prompter)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        try "wip".write(toFile: task.worktreePath + "/wip.txt", atomically: true, encoding: .utf8)

        await fixture.controller.archiver.archive(task: task)

        let asked = try #require(prompter.asked.first)
        #expect(asked.buttons == ["Keep Task", "Delete Changes and Archive"])
        #expect(asked.detail == "Archiving deletes its uncommitted changes and untracked files. The branch is kept.")
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"])
        #expect(server.requests("window.close").isEmpty)
        #expect(fixture.controller.remover.removal(of: task.id) == nil, "kept before anything moved: no note")
    }

    @Test func deleteChangesAndArchiveArchivesTheDirtyWorktree() async throws {
        let fixture = try await RaceFixture(prompter: ScriptedPrompter(answering: "Delete Changes and Archive"))
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: "alive")
        try "wip".write(toFile: task.worktreePath + "/wip.txt", atomically: true, encoding: .utf8)
        await fixture.controller.archiver.archive(task: task)
        #expect(fixture.controller.state.archive.map(\.id) == [task.id])
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func aDetachedWorktreeIsNotArchived() async throws {
        let prompter = ScriptedPrompter(answering: "OK")
        let fixture = try await RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: "alive")
        try fixture.git.run(["checkout", "-q", "--detach"], in: task.worktreePath)
        await fixture.controller.archiver.archive(task: task)
        #expect(prompter.asked.first?.message == "“Work” can’t be archived")
        #expect(fixture.controller.state.tasks.map(\.id) == [task.id])
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
    }

    /// Archive asks Remove's question about a folder git no longer lists: it may hold files AiTerm
    /// did not make. Keep, the safe default, keeps the folder and the task, and archives nothing.
    @Test(arguments: ["Keep", "Delete Folder", "↩", "⎋"])
    func archivingAnUnknownFolderKeepsItUnlessExplicitlyConfirmed(answer: String) async throws {
        let prompter = ScriptedPrompter(answering: answer)
        let fixture = try await RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: "alive")
        try fixture.git.run(["worktree", "remove", task.worktreePath], in: fixture.repo.path)
        try FileManager.default.createDirectory(atPath: task.worktreePath, withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: task.worktreePath).appendingPathComponent("unknown")
        try Data("keep me".utf8).write(to: file)

        await fixture.controller.archiver.archive(task: task)

        let deleted = answer == "Delete Folder"
        #expect(prompter.asked.map(\.buttons) == [["Keep", "Delete Folder"]])
        #expect(FileManager.default.fileExists(atPath: file.path) == !deleted)
        #expect(fixture.controller.state.tasks.map(\.id) == (deleted ? [] : [task.id]))
        #expect(fixture.controller.state.archive.map(\.id) == (deleted ? [task.id] : []))
        #expect(fixture.controller.remover.removal(of: task.id) == nil, "kept before anything moved: no note")
    }

    @Test func aWorktreeDetachedWhileTheWindowClosesIsNotArchived() async throws {
        // Clean and on its branch when the archive started; its agent detached it before the window
        // went, so removing it now would lose whatever that detached head holds.
        let prompter = ScriptedPrompter(answering: "OK")
        let fixture = try await RaceFixture(prompter: prompter)
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")

        let archiving = Task { await controller.archiver.archive(task: task) }
        try await server.received("window.close")
        try fixture.git.run(["checkout", "-q", "--detach"], in: task.worktreePath)
        server.release()
        await archiving.value

        #expect(prompter.asked.map(\.message) == ["“Work” can’t be archived"])
        #expect(controller.state.tasks.map(\.id) == [task.id])
        #expect(controller.state.tasks.map(\.windowId) == [nil], "owed its window")
        #expect(controller.state.archive.isEmpty)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func aWorktreeSwitchedWhileTheWindowClosesIsArchivedOnTheBranchItIsOnNow() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        try fixture.git.run(["branch", "feat/other"], in: fixture.repo.path)

        let archiving = Task { await controller.archiver.archive(task: task) }
        try await server.received("window.close")
        try fixture.git.run(["checkout", "-q", "feat/other"], in: task.worktreePath)
        server.release()
        await archiving.value

        #expect(controller.state.archive.map(\.task.branch) == ["feat/other"])
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func withoutADaemonAWindowedTaskIsNotArchived() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try await fixture.addTask(windowId: "alive")
        await fixture.controller.archiver.archive(task: task)
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"])
        #expect(fixture.controller.remover.removal(of: task.id) == .stopped(note: "Not archived: iTerm2 isn’t connected"))
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func aWindowThatWillNotCloseStopsTheArchiveAndIsGivenBack() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon(failing: ["window.close": .itermUnavailable])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        await fixture.controller.archiver.archive(task: task)
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"])
        #expect(fixture.controller.remover.removal(of: task.id) == .stopped(note: "Not archived: its window did not close"))
    }

    @Test func anUnreadableProjectFolderStopsTheArchiveWithNothingMoved() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: "alive")
        try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent(".git"))
        await fixture.controller.archiver.archive(task: task)
        #expect(fixture.controller.state.tasks.map(\.id) == [task.id])
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"], "its window too")
        #expect(fixture.controller.state.archive.isEmpty)
        #expect(fixture.controller.remover.removal(of: task.id) == .stopped(note: "Not archived"))
    }

    @Test func anArchiveThatCannotBeSavedLeavesTheWorktreeAndTheTask() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")

        let archiving = Task { await controller.archiver.archive(task: task) }
        try await server.received("window.close")
        // Saving breaks while the window closes: a directory stands where the backup goes.
        let backup = controller.workspace.file.backupURL
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        server.release()
        await archiving.value

        #expect(controller.persistenceError != nil)
        #expect(controller.state.tasks.map(\.id) == [task.id], "a task again, owed its window")
        #expect(controller.state.archive.isEmpty)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath), "nothing deleted")
        #expect(controller.remover.removal(of: task.id) == .stopped(note: "Not archived"))
        #expect(controller.toastState.toast == nil)
    }

    @Test func archivingTwiceAtOnceArchivesOnce() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        let first = Task { await fixture.controller.archiver.archive(task: task) }
        try await server.received("window.close")
        await fixture.controller.archiver.archive(task: task)
        server.release()
        await first.value
        #expect(fixture.controller.state.archive.count == 1)
        #expect(server.requests("window.close").count == 1)
    }

    @Test func uncommittedWorkWrittenWhileTheWindowClosesIsAskedAboutAndKeepPutsTheTaskBack() async throws {
        // The first question is not asked: the worktree was clean when it was checked.
        let prompter = ScriptedPrompter(answering: "Keep Task")
        let fixture = try await RaceFixture(prompter: prompter)
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")

        let archiving = Task { await controller.archiver.archive(task: task) }
        try await server.received("window.close")
        try "wip".write(toFile: task.worktreePath + "/wip.txt", atomically: true, encoding: .utf8)
        server.release()
        await archiving.value

        #expect(prompter.asked.map(\.buttons) == [["Keep Task", "Delete Changes and Archive"]])
        #expect(controller.state.tasks.map(\.id) == [task.id])
        #expect(controller.state.tasks.map(\.windowId) == [nil], "owed its window")
        #expect(controller.remover.removal(of: task.id) == .stopped(note: "Not archived"))
        #expect(controller.state.archive.isEmpty)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/wip.txt"))
    }

    @Test func uncommittedWorkWrittenWhileTheWindowClosesIsDeletedOnDeleteChangesAndArchive() async throws {
        let fixture = try await RaceFixture(prompter: ScriptedPrompter(answering: "Delete Changes and Archive"))
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")

        let archiving = Task { await controller.archiver.archive(task: task) }
        try await server.received("window.close")
        try "wip".write(toFile: task.worktreePath + "/wip.txt", atomically: true, encoding: .utf8)
        server.release()
        await archiving.value

        #expect(controller.state.archive.map(\.id) == [task.id])
        #expect(controller.state.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func restoringBringsTheWorktreeAndRowBackAndItsWindowWithItsConversations() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        var task = try await fixture.addTask(windowId: "alive")
        controller.workspace.mutate { $0.tasks[0].conversations = [TaskConversation(agent: .codex, id: "conv-1")] }
        task = controller.state.tasks[0]
        await controller.archiver.archive(task: task)
        controller.workspace.mutate { $0.updateProject(id: fixture.project.id) { $0.collapsed = true } }
        // iTerm2's windows read, so a chosen row's window can open: with no snapshot yet, AiTerm
        // waits for one instead.
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await controller.restoreFromArchive(task.id)

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
        let fixture = try await RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: "alive")
        await fixture.controller.archiver.archive(task: task)
        try fixture.git.run(["branch", "-D", "feat/work"], in: fixture.repo.path)

        await fixture.controller.archiver.restore(task.id)

        #expect(prompter.asked.last?.message == "“Work” can’t be restored")
        #expect(prompter.asked.last?.detail.contains("no longer exists here or on origin") == true)
        #expect(fixture.controller.state.archive.map(\.id) == [task.id])
        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(fixture.controller.focus.selection == nil)
    }

    @Test func aProjectCannotBeRemovedWhileOneOfItsArchivedRowsIsRestoring() async throws {
        // "OK" answers "“Repo” can’t be removed yet": the refusal comes before the question.
        let prompter = ScriptedPrompter(answering: "OK")
        let git = WorktreeAddHeldGit()
        let fixture = try await RaceFixture(prompter: prompter, controllerGit: git)
        defer { git.open(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: "alive")
        await controller.archiver.archive(task: task)
        let restoring = Task { await controller.archiver.restore(task.id) }
        await git.reached.wait()
        // The project cannot be removed while its archived row is restoring.
        await controller.projects.confirmRemove(project: fixture.project)
        #expect(prompter.asked.map(\.message) == ["“Repo” can’t be removed yet"])
        #expect(controller.state.project(id: fixture.project.id) != nil)
        git.open()
        await restoring.value
        #expect(controller.state.tasks.map(\.id) == [task.id])
        #expect(controller.focus.selection == nil, "the restore alone chooses nothing")
    }

    /// Git's removal of the worktree has no seam to hold, so the row is put where an archive leaves it
    /// while git runs: in the archive, its `.archiving` work begun.
    @Test func aProjectCannotBeRemovedWhileOneOfItsRowsIsBeingArchived() async throws {
        let prompter = ScriptedPrompter(answering: "OK")
        let fixture = try await RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try await fixture.addTask(windowId: nil)
        controller.workspace.mutate { $0.moveToArchive(taskId: task.id, branch: task.branch, at: Date()) }
        let begun = controller.work.begin(.archiving, onTask: task.id)
        let token = try #require(begun)
        defer { controller.work.end(token) }

        await controller.projects.confirmRemove(project: fixture.project)

        #expect(prompter.asked.map(\.message) == ["“Repo” can’t be removed yet"])
        #expect(prompter.asked.first?.detail == "One of its archived tasks is still being archived, restored or removed. Try again in a moment.")
        #expect(controller.state.project(id: fixture.project.id) != nil)
        #expect(controller.state.archive.map(\.id) == [task.id])
    }

    @Test func restoringTwiceAtOnceRestoresOnce() async throws {
        let git = WorktreeAddHeldGit()
        let fixture = try await RaceFixture(controllerGit: git)
        defer { git.open(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: "alive")
        await fixture.controller.archiver.archive(task: task)
        let first = Task { await fixture.controller.archiver.restore(task.id) }
        await git.reached.wait()
        await fixture.controller.archiver.restore(task.id)
        git.open()
        await first.value
        #expect(fixture.controller.state.tasks.count == 1)
        #expect(git.worktreeAdds == 1, "one worktree restored")
    }

    @Test func removingFromTheArchiveAsksRemovesQuestionAndForgetsTheRowKeepingTheBranchUnlessTicked() async throws {
        let prompter = ScriptedPrompter(answering: "Remove")
        let fixture = try await RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: nil)
        await fixture.controller.archiver.archive(task: task)

        await fixture.controller.archiver.confirmRemove(archived: task.id)

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
        let fixture = try await RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: nil)
        await fixture.controller.archiver.archive(task: task)
        try FileManager.default.createDirectory(atPath: task.worktreePath, withIntermediateDirectories: true)
        try "someone else's".write(toFile: task.worktreePath + "/f.txt", atomically: true, encoding: .utf8)

        await fixture.controller.archiver.confirmRemove(archived: task.id)

        #expect(try String(contentsOfFile: task.worktreePath + "/f.txt", encoding: .utf8) == "someone else's")
        #expect(fixture.controller.state.archive.isEmpty)
    }

    @Test func removingAnArchivedRowWhoseBranchHoldsUnmergedCommitsAsksBeforeDeletingIt() async throws {
        let prompter = ScriptedPrompter(answering: "Remove", "Delete Branch")
        prompter.checksTheCheckbox = true
        let fixture = try await RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: nil)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "work"],
                            in: task.worktreePath)
        await fixture.controller.archiver.archive(task: task)
        var archivedWhileAsked = false
        prompter.whileAsking = { prompt in
            if prompt.message == "Delete branch feat/work?" { archivedWhileAsked = fixture.controller.state.archived(id: task.id) != nil }
        }

        await fixture.controller.archiver.confirmRemove(archived: task.id)

        let asked = try #require(prompter.asked.last)
        #expect(asked.message == "Delete branch feat/work?")
        #expect(asked.buttons == ["Delete Branch", "Keep Branch"])
        #expect(archivedWhileAsked, "asked before the row is forgotten")
        #expect(fixture.controller.state.archive.isEmpty)
        #expect(try fixture.git.run(["branch", "--list", "feat/work"], in: fixture.repo.path).isEmpty)
        #expect(fixture.controller.toastState.toast?.message == "Task removed.")
    }

    @Test func decliningTheUnmergedBranchQuestionKeepsTheBranchAndStillForgetsTheRow() async throws {
        let prompter = ScriptedPrompter(answering: "Remove", "Keep Branch")
        prompter.checksTheCheckbox = true
        let fixture = try await RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: nil)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "work"],
                            in: task.worktreePath)
        await fixture.controller.archiver.archive(task: task)

        await fixture.controller.archiver.confirmRemove(archived: task.id)

        #expect(fixture.controller.state.archive.isEmpty)
        #expect(!(try fixture.git.run(["branch", "--list", "feat/work"], in: fixture.repo.path)).isEmpty)
        #expect(fixture.controller.toastState.toast?.message == "Task removed.", "kept as asked, nothing to say")
    }

    @Test func aBranchGitWillNotDeleteForAnotherReasonIsSaidKeptAndTheRowStillGoes() async throws {
        let prompter = ScriptedPrompter(answering: "Remove")
        prompter.checksTheCheckbox = true
        let fixture = try await RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: nil)
        await fixture.controller.archiver.archive(task: task)
        // Checked out in the project's own folder, the branch cannot be deleted — and not for want of a merge.
        try fixture.git.run(["checkout", "-q", "feat/work"], in: fixture.repo.path)

        await fixture.controller.archiver.confirmRemove(archived: task.id)

        #expect(fixture.controller.issue == nil, "said by the toast, with nothing to answer")
        let toast = try #require(fixture.controller.toastState.toast?.message)
        #expect(toast.hasPrefix("Task removed. Branch feat/work kept: "), "\(toast)")
        #expect(!toast.hasSuffix(".."))
        #expect(fixture.controller.state.archive.isEmpty)
        #expect(!(try fixture.git.run(["branch", "--list", "feat/work"], in: fixture.repo.path)).isEmpty)
    }

    /// Delete Branch answered, `-D` can still fail — the branch got checked out in the project's
    /// folder meanwhile. The branch is kept, the toast says so in git's words, and the row goes.
    @Test func aBranchThatCannotBeDeletedAfterTheUnmergedQuestionIsSaidKeptAndTheRowStillGoes() async throws {
        let prompter = ScriptedPrompter(answering: "Remove", "Delete Branch")
        prompter.checksTheCheckbox = true
        let fixture = try await RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: nil)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "work"],
                            in: task.worktreePath)
        await fixture.controller.archiver.archive(task: task)
        // While the question is up the branch is checked out in the project's folder, so `-D` fails.
        let git = fixture.git, repo = fixture.repo
        prompter.whileAsking = { prompt in
            if prompt.message == "Delete branch feat/work?" { _ = try? git.run(["checkout", "-q", "feat/work"], in: repo.path) }
        }

        await fixture.controller.archiver.confirmRemove(archived: task.id)

        #expect(fixture.controller.issue == nil)
        #expect(fixture.controller.toastState.toast?.message.hasPrefix("Task removed. Branch feat/work kept: ") == true)
        #expect(fixture.controller.state.archive.isEmpty)
        #expect(!(try fixture.git.run(["branch", "--list", "feat/work"], in: fixture.repo.path)).isEmpty)
    }

    @Test func removingAProjectSaysHowManyArchivedRowsItForgets() {
        func archived(_ kind: TaskKind) -> ArchivedTask {
            ArchivedTask(task: TaskItem.make(project: UUID(), title: "t", branch: "b", worktreePath: "/w", kind: kind, createdAt: Date()), archivedAt: Date())
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

/// Holds the first `git worktree add` until opened, so a restore can be caught while git recreates
/// its worktree. Counts every `worktree add` it is asked to run.
private final class WorktreeAddHeldGit: GitRunning {
    let reached = TestLatch()
    private let adds = Mutex(0)
    private let gate = DispatchSemaphore(value: 0)
    private let inner = GitRunner.hermetic()
    var worktreeAdds: Int { adds.withLock { $0 } }
    func open() { gate.signal() }
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if args.starts(with: ["worktree", "add"]), adds.withLock({ $0 += 1; return $0 == 1 }) {
            reached.signal()
            gate.wait()
        }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}
