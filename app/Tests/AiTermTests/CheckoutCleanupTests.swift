import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

extension AppControllerTests {
    /// A checkout removed outside AiTerm while its window is open: the row and its badge stay until
    /// the window closes. (AiTerm's own Remove closes the window first; see below.)
    @Test(arguments: [false, true])
    func diffRemainsUntilRemovalCompletesOrFails(closeFails: Bool) async throws {
        let fixture = try CheckoutFixture(windowOpen: true)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let changedFile = URL(fileURLWithPath: fixture.task.worktreePath).appendingPathComponent("change.txt")
        try "one\n".write(to: changedFile, atomically: true, encoding: .utf8)
        try fixture.git.run(["add", "change.txt"], in: fixture.task.worktreePath)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "change"], in: fixture.task.worktreePath)
        await controller.checkouts.refresh().value
        let diff = try #require(controller.checkouts.diffByTask[fixture.task.id])
        #expect(diff == DiffStat(added: 1, removed: 0))

        let server = RecordingDaemon(failing: closeFails ? ["window.close": "temporary_failure"] : [:], holding: "window.close")
        defer { server.release(); controller.shutdown() }
        controller.helper.setDaemonClient(server)
        try fixture.git.run(["worktree", "remove", fixture.task.worktreePath], in: fixture.repo.path)
        controller.checkouts.refresh()
        await eventually { controller.checkouts.missingCheckouts.contains(fixture.task.id) && !server.closedWindowIds.isEmpty }
        #expect(controller.state.tasks == [fixture.task])
        #expect(controller.checkouts.diffByTask[fixture.task.id] == diff)

        // A later scan cannot confirm deletion while the worktree parent is temporarily offline.
        // The window close is still in flight, so the badge must remain unchanged.
        let parent = URL(fileURLWithPath: fixture.task.worktreePath).deletingLastPathComponent()
        let offlineParent = fixture.root.appendingPathComponent("offline-worktrees")
        try FileManager.default.moveItem(at: parent, to: offlineParent)
        defer { try? FileManager.default.moveItem(at: offlineParent, to: parent) }
        await controller.checkouts.refresh().value
        #expect(controller.state.tasks == [fixture.task])
        #expect(controller.checkouts.diffByTask[fixture.task.id] == diff)
        try FileManager.default.moveItem(at: offlineParent, to: parent)

        server.release()
        await eventually { closeFails ? controller.checkouts.diffByTask[fixture.task.id] == nil : controller.state.tasks.isEmpty }
        if closeFails {
            #expect(controller.state.tasks == [fixture.task])
            #expect(controller.checkouts.diffByTask[fixture.task.id] == nil)
        } else {
            #expect(controller.state.tasks.isEmpty)
        }
    }

    /// Remove closes the task's window before git deletes anything: a process still running there —
    /// a dev server's watcher — writes files back into a checkout being deleted, and git then gives
    /// up halfway. The row stays until the removal is done.
    @Test func removingATaskClosesItsWindowBeforeDeletingItsWorktree() async throws {
        let fixture = try CheckoutFixture(windowOpen: true, prompter: ScriptedPrompter(answering: "Remove"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); controller.shutdown() }
        controller.helper.setDaemonClient(server)

        let removal = controller.confirmRemove(task: fixture.task)
        try await server.received("window.close")
        try #require(server.closedWindowIds == ["alive"])
        #expect(FileManager.default.fileExists(atPath: fixture.task.worktreePath), "nothing is deleted while the window is open")
        // The window's own `window.closed` must not take the row while the removal runs.
        controller.handleWindowClosed("alive")
        #expect(controller.state.tasks.map(\.id) == [fixture.task.id])
        #expect(try controller.workspace.file.load().tasks.map(\.windowId) == [nil],
                "on disk windowless before the close was sent, in case the app dies before the removal ends")

        server.release()
        await removal?.value
        #expect(controller.state.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.task.worktreePath))
        #expect(server.closedWindowIds == ["alive"], "closed once")
        #expect(controller.issue == nil)
        #expect(controller.toastState.toast?.message == "Task removed.")
    }

    /// The row's going is saved before "Task removed." says so: a removal whose save fails says
    /// nothing of the kind, and the workspace locks with the save's error instead.
    @Test func aRemovalWhoseSaveFailsDoesNotSayItWasRemoved() async throws {
        let fixture = try CheckoutFixture(windowOpen: true, prompter: ScriptedPrompter(answering: "Remove"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); controller.shutdown() }
        controller.helper.setDaemonClient(server)

        let removal = controller.confirmRemove(task: fixture.task)
        try await server.received("window.close")
        // Saving breaks while the window closes: a directory stands where the backup goes.
        let backup = controller.workspace.file.backupURL
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        server.release()
        await removal?.value

        #expect(controller.state.tasks.isEmpty)
        #expect(controller.persistenceError != nil)
        #expect(controller.toastState.toast == nil)
    }

    /// A window that will not close keeps its worktree: nothing was deleted, so nothing is half done.
    @Test func aWindowThatWillNotCloseKeepsTheWorktree() async throws {
        let fixture = try CheckoutFixture(windowOpen: true, prompter: ScriptedPrompter(answering: "Remove"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let server = RecordingDaemon(failing: ["window.close": "temporary_failure"])
        defer { controller.shutdown() }
        controller.helper.setDaemonClient(server)

        await controller.confirmRemove(task: fixture.task)?.value

        #expect(server.closedWindowIds == ["alive"])
        #expect(FileManager.default.fileExists(atPath: fixture.task.worktreePath + "/.git"))
        #expect(controller.state.tasks == [fixture.task], "the row keeps its window")
        #expect(controller.issue == OperationIssue(
            title: "Couldn’t remove the task.", reason: "Its iTerm2 window did not close (test failure), so nothing was deleted.",
            subject: fixture.task.id))
    }

    /// Unsaved work is asked about before the window closes, so keeping the task leaves the agent
    /// running in it.
    @Test func keepingATaskWithUnsavedWorkLeavesItsWindowOpen() async throws {
        let fixture = try CheckoutFixture(windowOpen: true, prompter: ScriptedPrompter(answering: "Remove", "Keep Task"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let server = RecordingDaemon()
        defer { controller.shutdown() }
        controller.helper.setDaemonClient(server)
        try "draft\n".write(toFile: fixture.task.worktreePath + "/notes.txt", atomically: true, encoding: .utf8)

        await controller.confirmRemove(task: fixture.task)?.value

        #expect(server.closedWindowIds.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.task.worktreePath + "/notes.txt"))
        #expect(controller.state.tasks == [fixture.task])
    }

    /// Keep Task is the default and the safe choice both: ↩ and ⎋ keep it, and the button that
    /// deletes is the plain grey one beside it.
    @Test func returnAndEscapeBothKeepATaskWithUnsavedWork() async throws {
        for key in ["↩", "⎋"] {
            let prompter = ScriptedPrompter(answering: "Remove", key)
            let fixture = try CheckoutFixture(windowOpen: true, prompter: prompter)
            defer { fixture.cleanUp() }
            let controller = fixture.controller
            let server = RecordingDaemon()
            defer { controller.shutdown() }
            controller.helper.setDaemonClient(server)
            try "draft\n".write(toFile: fixture.task.worktreePath + "/notes.txt", atomically: true, encoding: .utf8)

            await controller.confirmRemove(task: fixture.task)?.value

            let asked = try #require(prompter.asked.last)
            #expect(asked.buttons == ["Keep Task", "Delete Changes and Remove"])
            #expect(!asked.defaultDeletes)
            #expect(server.closedWindowIds.isEmpty, "\(key) keeps the task")
            #expect(FileManager.default.fileExists(atPath: fixture.task.worktreePath + "/notes.txt"))
            #expect(controller.state.tasks == [fixture.task])
        }
    }

    /// Deleting the unsaved work closes the window first too, once the question is answered.
    @Test func deletingUnsavedWorkClosesTheWindowBeforeTheWorktree() async throws {
        let prompter = ScriptedPrompter(answering: "Remove", "Delete Changes and Remove")
        let fixture = try CheckoutFixture(windowOpen: true, prompter: prompter)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); controller.shutdown() }
        controller.helper.setDaemonClient(server)
        try "draft\n".write(toFile: fixture.task.worktreePath + "/notes.txt", atomically: true, encoding: .utf8)

        let removal = controller.confirmRemove(task: fixture.task)
        try await server.received("window.close")
        #expect(FileManager.default.fileExists(atPath: fixture.task.worktreePath + "/notes.txt"))

        server.release()
        await removal?.value
        #expect(prompter.asked.map(\.message).last == "The worktree has uncommitted changes")
        #expect(controller.state.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.task.worktreePath))
    }

    /// A snapshot landing while the removal closes the window — the helper re-attaching — leaves the
    /// window let go: re-attached, its `window.closed` would take the row mid-removal.
    @Test func aSnapshotDuringTheCloseDoesNotReattachTheWindow() async throws {
        let fixture = try CheckoutFixture(windowOpen: true, prompter: ScriptedPrompter(answering: "Remove"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); controller.shutdown() }
        controller.helper.setDaemonClient(server)

        let removal = controller.confirmRemove(task: fixture.task)
        try await server.received("window.close")
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [SessionInfo.stub(window: "alive", task: fixture.task)], usage: .empty)))
        #expect(controller.state.tasks.first?.windowId == nil)
        controller.handleWindowClosed("alive")
        #expect(controller.state.tasks.map(\.id) == [fixture.task.id])

        server.release()
        await removal?.value
        #expect(controller.state.tasks.isEmpty)
        #expect(controller.issue == nil)
    }

    /// Unsaved work written once the check has passed — the agent, or a watcher exiting as its
    /// window closes — is only found after the window has gone. Kept then, the task says so.
    @Test func keepingATaskWhoseWindowAlreadyClosedSaysSo() async throws {
        let fixture = try CheckoutFixture(windowOpen: true, prompter: ScriptedPrompter(answering: "Remove", "Keep Task"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); controller.shutdown() }
        controller.helper.setDaemonClient(server)

        let removal = controller.confirmRemove(task: fixture.task)
        try await server.received("window.close")
        try "late\n".write(toFile: fixture.task.worktreePath + "/late.txt", atomically: true, encoding: .utf8)
        server.release()
        await removal?.value

        #expect(FileManager.default.fileExists(atPath: fixture.task.worktreePath + "/late.txt"))
        #expect(controller.state.tasks.map(\.id) == [fixture.task.id])
        #expect(controller.state.tasks.first?.windowId == nil)
        #expect(controller.issue == OperationIssue(title: "Task kept. Its window had already closed.", subject: fixture.task.id))
        #expect(controller.removals[fixture.task.id] == .stopped(note: "Kept; choose Reopen Window", worktreeRemoved: false))

        // Dismissed, nothing is half done: the row is a windowless task again.
        controller.dismissIssue()
        #expect(controller.removals.isEmpty)
    }

    @Test func deletedCheckoutKeepsWindowIdentityWhileDaemonIsUnavailable() async throws {
        let fixture = try CheckoutFixture(windowOpen: true)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        try fixture.git.run(["worktree", "remove", fixture.task.worktreePath], in: fixture.repo.path)
        controller.checkouts.refresh()
        await eventually { controller.checkouts.projectBranch[fixture.project.id] != nil }
        #expect(controller.state.tasks == [fixture.task])
        #expect(try controller.savedWorkspace().tasks == [fixture.task])
        let server = RecordingDaemon()
        defer { controller.shutdown() }
        controller.helper.setDaemonClient(server)
        await eventually { controller.state.tasks.isEmpty }
        #expect(controller.state.tasks.isEmpty)
        #expect(server.closedWindowIds == ["alive"])
    }

    @Test(arguments: [SessionState.working, .needsInput])
    func aRemovedTaskWaitsForItsTurnToEnd(active: SessionState) async throws {
        let fixture = try CheckoutFixture(windowOpen: true)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let server = RecordingDaemon()
        defer { controller.shutdown() }
        controller.helper.setDaemonClient(server)
        let windowId = try #require(fixture.task.windowId)
        controller.live.sessions = [SessionInfo.stub("s1", window: windowId, task: fixture.task, state: active)]

        try fixture.git.run(["worktree", "remove", fixture.task.worktreePath], in: fixture.repo.path)
        await controller.checkouts.refresh().value
        // A close would have marked the row closing within the pass.
        #expect(controller.removals.isEmpty)
        #expect(controller.state.tasks == [fixture.task])

        controller.live.sessions[0].state = .done
        await controller.checkouts.refresh().value
        await controller.closingTask?.value
        #expect(server.closedWindowIds == [windowId])
        #expect(controller.state.tasks.isEmpty)
    }

    /// A close iTerm2 refuses is retried by the next pass, and the row says "Closing…" throughout
    /// rather than flickering back to "Worktree missing" between tries.
    @Test(arguments: ["temporary_failure", "not_found"])
    func checkoutCleanupRetriesFailedWindowCloseAndAcceptsAlreadyClosedWindow(errorCode: String) async throws {
        let fixture = try CheckoutFixture(windowOpen: true)
        let server = RecordingDaemon(failing: ["window.close": errorCode])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        try fixture.git.run(["worktree", "remove", fixture.task.worktreePath], in: fixture.repo.path)
        await controller.checkouts.refresh().value
        await controller.closingTask?.value
        try #require(server.closedWindowIds == ["alive"])
        if errorCode == "temporary_failure" {
            #expect(controller.state.tasks == [fixture.task])
            #expect(try controller.savedWorkspace().tasks == [fixture.task])
            #expect(controller.removals == [fixture.task.id: .closing])
            server.failing = [:]
            await controller.checkouts.refresh().value
            await controller.closingTask?.value
        }
        #expect(controller.state.tasks.isEmpty)
        #expect(controller.removals.isEmpty)
        #expect(try controller.savedWorkspace().tasks.isEmpty)
        #expect(server.closedWindowIds == (errorCode == "temporary_failure" ? ["alive", "alive"] : ["alive"]))
    }

    /// Closing stops once the checkout comes back: the row is only missing no more.
    @Test func aCheckoutThatComesBackStopsClosing() async throws {
        let fixture = try CheckoutFixture(windowOpen: true)
        let server = RecordingDaemon(failing: ["window.close": "temporary_failure"])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let parent = URL(fileURLWithPath: fixture.task.worktreePath).deletingLastPathComponent()
        let aside = fixture.root.appendingPathComponent("aside")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: fixture.task.worktreePath), to: aside)
        await controller.checkouts.refresh().value
        await controller.closingTask?.value
        try #require(controller.removals == [fixture.task.id: .closing])

        try FileManager.default.moveItem(at: aside, to: parent.appendingPathComponent("work"))
        await controller.checkouts.refresh().value

        #expect(controller.removals.isEmpty)
        #expect(controller.state.tasks == [fixture.task])
    }

    @Test func checkoutMonitorDetectsDeletionWithoutSessionChangesAndStopsOnShutdown() async throws {
        let fixture = try CheckoutFixture(windowOpen: true, pollInterval: .milliseconds(10))
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        controller.checkouts.startMonitoring()
        controller.checkouts.startMonitoring() // Must not create a second poll lifetime.
        await eventually { controller.checkouts.projectBranch[fixture.project.id] != nil }
        try #require(controller.checkouts.projectBranch[fixture.project.id] == "main")
        try fixture.git.run(["worktree", "remove", fixture.task.worktreePath], in: fixture.repo.path)
        // Deliver no events and call no refresh: the production timer must find it.
        await eventually { controller.state.tasks.isEmpty }
        #expect(controller.state.tasks.isEmpty)
        #expect(server.closedWindowIds == ["alive"])
        // The removal's trailing branch refresh, and the poll's own pass, finish before a task is restored.
        await controller.checkouts.refreshTask?.value
        controller.shutdown()
        controller.workspace.mutate { $0.tasks = [fixture.task] }
        // Absence: ten poll intervals, in which a poll that outlived shutdown would have run.
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.state.tasks == [fixture.task])
    }

    @Test(arguments: [false, true])
    func filesystemRefreshRemovesDeletedCheckoutWithoutHook(windowOpen: Bool) async throws {
        let fixture = try CheckoutFixture(windowOpen: windowOpen)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        controller.focus.browse(.task(fixture.task.id))
        // Exercise actual Git removal. No hook or synthetic removal event is delivered.
        try fixture.git.run(["worktree", "remove", fixture.task.worktreePath], in: fixture.repo.path)
        controller.checkouts.refresh()
        await eventually { controller.state.tasks.isEmpty }
        #expect(controller.state.tasks.isEmpty)
        #expect(controller.focus.selectedTaskId == nil)
        #expect(try controller.savedWorkspace().tasks.isEmpty)
        #expect(!controller.checkouts.missingCheckouts.contains(fixture.task.id))
        #expect(server.closedWindowIds == (windowOpen ? ["alive"] : []))
        // Observing removal must never delete the remaining branch.
        #expect(try fixture.git.run(["rev-parse", "--verify", "feat/work"], in: fixture.repo.path).isEmpty == false)
    }

    @Test(arguments: ["existing", "project-unavailable", "parent-unavailable", "permission-denied"])
    func filesystemRefreshRetainsUnconfirmedDeletion(scenario: String) async throws {
        // No window: a disconnected daemon must not mask a broken filesystem guard.
        let fixture = try CheckoutFixture(windowOpen: false)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let parent = fixture.repo.appendingPathComponent(".worktrees")
        switch scenario {
        case "project-unavailable":
            try FileManager.default.moveItem(at: fixture.repo, to: fixture.root.appendingPathComponent("offline"))
        case "parent-unavailable":
            try FileManager.default.moveItem(at: parent, to: fixture.repo.appendingPathComponent("offline"))
        case "permission-denied":
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: parent.path)
        default: break
        }
        defer { if scenario == "permission-denied" { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) } }
        // A missing session cwd is not evidence that the saved checkout was removed.
        controller.live.sessions = [SessionInfo(sessionId: "s", windowId: "alive", tabIndex: 0,
            taskId: fixture.task.id.uuidString, projectId: nil, agent: .codex, model: nil,
            state: .idle, title: "", cwd: fixture.task.worktreePath + "/deleted-subdirectory")]
        controller.checkouts.refresh()
        await eventually { controller.checkouts.projectBranch[fixture.project.id] != nil || !controller.checkouts.missingCheckouts.isEmpty }
        #expect(controller.state.tasks == [fixture.task])
        #expect(try controller.savedWorkspace().tasks == [fixture.task])
    }
}

extension RecordingDaemon {
    /// The windows the controller asked to close, in order.
    var closedWindowIds: [String] { requests("window.close").compactMap { $0.params["windowId"] as? String } }
}

@MainActor
private struct CheckoutFixture {
    let root: URL
    let repo: URL
    let git = GitRunner.hermetic()
    let project: Project
    let task: TaskItem
    let controller: AppController

    init(windowOpen: Bool, prompter: Prompter = ScriptedPrompter(), pollInterval: Duration = .seconds(2)) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "init"], in: repo.path)
        let checkout = repo.appendingPathComponent(".worktrees/work").path
        try git.run(["worktree", "add", "-b", "feat/work", checkout], in: repo.path)
        project = Project(id: UUID(), name: "Repo", path: repo.path, provider: .git,
                          remoteUrl: nil, addedAt: Date(), collapsed: false)
        task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work",
                        worktreePath: checkout, baseBranch: "main", jira: nil, agent: .codex,
                        model: "model", reasoning: nil, firstPrompt: nil, appendTicket: false,
                        createdAt: Date(timeIntervalSince1970: 0), windowId: windowOpen ? "alive" : nil)
        controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(), prompter: prompter,
                                checkoutPollInterval: pollInterval)
        try controller.loadWorkspace()
        controller.workspace.mutate { state in
            state.items = [.project(project)]
            state.tasks = [task]
        }
        #expect(controller.workspace.flush())
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// What a task row shows while it is being removed, and once the removal stops: the row says it is
/// going for as long as it is, and a removal that stops says why on the row it left.
extension AppControllerTests {
    @Test func aRemovalShowsOnItsRowUntilTheRowGoes() async throws {
        let fixture = try CheckoutFixture(windowOpen: true, prompter: ScriptedPrompter(answering: "Remove"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); controller.shutdown() }
        controller.helper.setDaemonClient(server)
        #expect(controller.removals.isEmpty)

        let removal = controller.confirmRemove(task: fixture.task)
        try await server.received("window.close")
        #expect(controller.removals == [fixture.task.id: .removing])

        server.release()
        await removal?.value
        #expect(controller.state.tasks.isEmpty)
        #expect(controller.removals.isEmpty)
    }

    @Test func aWindowThatWillNotCloseSaysSoOnTheRow() async throws {
        let fixture = try CheckoutFixture(windowOpen: true, prompter: ScriptedPrompter(answering: "Remove"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        defer { controller.shutdown() }
        controller.helper.setDaemonClient(RecordingDaemon(failing: ["window.close": "temporary_failure"]))

        await controller.confirmRemove(task: fixture.task)?.value

        #expect(controller.removals == [fixture.task.id: .stopped(note: "Not removed: its window did not close", worktreeRemoved: false)])
        #expect(controller.issue?.subject == fixture.task.id)
    }

    @Test func keepingATaskWithUnsavedWorkEndsItsRemoval() async throws {
        let fixture = try CheckoutFixture(windowOpen: true, prompter: ScriptedPrompter(answering: "Remove", "Keep Task"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        defer { controller.shutdown() }
        controller.helper.setDaemonClient(RecordingDaemon())
        try "draft\n".write(toFile: fixture.task.worktreePath + "/notes.txt", atomically: true, encoding: .utf8)

        await controller.confirmRemove(task: fixture.task)?.value

        #expect(controller.state.tasks == [fixture.task])
        #expect(controller.removals.isEmpty)
        #expect(controller.issue == nil, "keeping it was the person's answer; there is nothing to explain")
    }

    /// A checkout deleted outside AiTerm: its row says it is closing while its window closes.
    @Test func aCheckoutDeletedElsewhereShowsClosingWhileItsWindowCloses() async throws {
        let fixture = try CheckoutFixture(windowOpen: true)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); controller.shutdown() }
        controller.helper.setDaemonClient(server)

        try fixture.git.run(["worktree", "remove", fixture.task.worktreePath], in: fixture.repo.path)
        controller.checkouts.refresh()
        try await server.received("window.close")
        #expect(controller.removals == [fixture.task.id: .closing])

        server.release()
        await eventually { controller.state.tasks.isEmpty }
        #expect(controller.state.tasks.isEmpty)
        #expect(controller.removals.isEmpty)
    }
}
