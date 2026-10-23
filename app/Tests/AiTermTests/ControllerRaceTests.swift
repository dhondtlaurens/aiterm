import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Work the controller awaits — a daemon reply, git, a modal question — lets anything else run
/// meanwhile. Each test here makes something happen in that gap and checks the work that resumes
/// acts on the workspace as it is then, not as it was when the work started.
extension AppControllerTests {
    /// A terminal row whose project is gone fails every save (`StateStore.validate`), so the project
    /// stays until its terminal has opened — and says why it cannot go yet.
    @Test func aProjectCannotBeRemovedWhileItsTerminalOpens() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "OK", "Cancel"))
        let server = RecordingDaemon(holding: "window.createTerminal")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)

        let first = controller.newTerminal(project: fixture.project, name: "Shell")
        try await server.received("window.createTerminal")
        await controller.confirmRemove(project: fixture.project)

        #expect(fixture.prompter.asked.map(\.message) == ["“Repo” can’t be removed yet"])
        #expect(fixture.prompter.asked.first?.detail.contains("A terminal is still opening in it.") == true)
        #expect(controller.state.projects == [fixture.project])
        // Two can open at once, and the project is busy until both have.
        let second = controller.newTerminal(project: fixture.project, name: "Shell 2")
        #expect(controller.issue == nil)
        server.release()
        await first?.value
        await second?.value
        #expect(controller.state.terminals.map(\.windowId) == ["terminal-window", "terminal-window-2"])
        #expect(controller.persistenceError == nil)
        await controller.confirmRemove(project: fixture.project)
        #expect(fixture.prompter.asked.last?.message == "Remove project “Repo”?", "free once both have opened")
    }

    /// A task's window opening — restored here, or for a review — holds the project too.
    @Test func aProjectCannotBeRemovedWhileATaskWindowOpensInIt() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "OK"))
        let server = RecordingDaemon(holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)

        // A restore opens only into an iTerm2 known to be there, and quiet.
        controller.helper.handle(.snapshot(AppControllerTests.emptySnapshot))
        let reopening = controller.windows.restore(.task(task.id))
        try await server.received("window.createTask")
        await controller.confirmRemove(project: fixture.project)

        #expect(fixture.prompter.asked.first?.detail.hasPrefix("A window is still opening for one of its tasks.") == true)
        server.release()
        await reopening?.value
        #expect(controller.state.tasks.first?.windowId == "reopened")
    }

    /// So does a terminal whose window is closing (or reopening).
    @Test func aProjectCannotBeRemovedWhileOneOfItsTerminalsCloses() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "OK"))
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "alive", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }

        let closing = controller.close(terminal: terminal)
        try await server.received("window.close")
        await controller.confirmRemove(project: fixture.project)

        #expect(fixture.prompter.asked.first?.detail.hasPrefix("One of its terminals is still opening or closing its window.") == true)
        server.release()
        await closing?.value
        #expect(controller.state.terminals.isEmpty)
    }

    /// Only work in the project holds it. A task being removed in "Repo" is no reason to refuse
    /// "Other"; it is a reason to refuse "Repo".
    @Test func aProjectIsNotHeldByAnotherProjectsTaskBeingChanged() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Remove", "Remove", "OK"))
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let other = Project(id: UUID(), name: "Other", path: fixture.root.appendingPathComponent("other").path, provider: .git,
                            remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.workspace.mutate { $0.append(project: other) }
        let task = try fixture.addTask(windowId: "alive")

        let removal = await controller.confirmRemove(task: task)
        try await server.received("window.close")
        await controller.confirmRemove(project: other)
        await controller.confirmRemove(project: fixture.project)

        #expect(fixture.prompter.asked.map(\.message).suffix(2) == ["Remove project “Other”?", "“Repo” can’t be removed yet"])
        #expect(fixture.prompter.asked.last?.detail.hasPrefix("A task is still being changed.") == true)
        #expect(controller.state.project(id: other.id) == nil, "Other went; Repo stayed")
        #expect(controller.state.projects == [fixture.project])
        server.release()
        await removal?.value
    }

    /// The project can still go while the window opens — a restored backup replaces the whole
    /// workspace. The window is then closed rather than adopted by a row nothing can save.
    @Test func aTerminalWhoseProjectWentWhileItOpenedIsClosed() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.createTerminal")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)

        let opening = controller.newTerminal(project: fixture.project, name: "Shell")
        try await server.received("window.createTerminal")
        controller.workspace.mutate { $0.removeItem(id: fixture.project.id) }
        server.release()
        await opening?.value

        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["terminal-window"])
        #expect(controller.state.terminals.isEmpty)
        #expect(controller.workspace.flush())
    }

    // -- removing a task: the alerts are reentrancy points ---------------------------------------

    /// ⌘⌫ on a selected task is its Remove Task…: the same question, and nothing without a yes.
    @Test func removingTheSelectionAsksBeforeATaskGoes() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Cancel"))
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: "alive")
        controller.focus.browse(.task(task.id))

        await controller.removeSelection()?.value

        #expect(fixture.prompter.asked.map(\.message) == ["Remove task “\(task.title)”?"])
        #expect(controller.state.task(id: task.id) != nil)
    }

    /// A terminal's Remove asks nothing, so ⌘⌫ closes its window straight away.
    @Test func removingTheSelectionClosesATerminal() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter())
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "alive", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }
        controller.focus.browse(.terminal(terminal.id))

        await controller.removeSelection()?.value

        #expect(fixture.prompter.asked.isEmpty)
        #expect(controller.state.terminals.isEmpty)
    }

    /// With nothing selected the key does nothing.
    @Test func removingNoSelectionDoesNothing() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter())
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        _ = try fixture.addTask(windowId: "alive")
        #expect(await fixture.controller.removeSelection() == nil)
        #expect(fixture.prompter.asked.isEmpty)
    }

    /// The row's copy of the task is as old as the click. By the time the alert is answered the
    /// window can have come back — a snapshot reattached it by its tag — and that is the window
    /// removal closes, not the none the click saw.
    @Test func removingATaskClosesTheWindowItHasWhenTheAlertIsAnswered() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Remove"))
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let clicked = try fixture.addTask(windowId: nil)
        fixture.prompter.whileAsking = { _ in controller.helper.handle(.snapshot(fixture.snapshot(tagging: clicked, in: "alive"))) }

        await controller.confirmRemove(task: clicked)?.value

        #expect(controller.state.tasks.isEmpty)
        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["alive"])
        #expect(!FileManager.default.fileExists(atPath: clicked.worktreePath))
    }

    /// A second Remove for the same row, started while the first alert was up, owns the removal;
    /// the first answer finds the task busy and does nothing, rather than running git twice.
    @Test func aRemovalStartedDuringTheAlertIsTheOnlyOneThatRuns() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Remove", "Remove"))
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        var nested = false, nestedRemoval: Task<Void, Never>?
        fixture.prompter.whileAsking = { _ in
            guard !nested else { return }
            nested = true
            nestedRemoval = await controller.confirmRemove(task: task)
        }

        #expect(await controller.confirmRemove(task: task) == nil, "the nested Remove owns the removal")
        await nestedRemoval?.value

        #expect(controller.state.tasks.isEmpty)
        #expect(fixture.prompter.asked.count == 2)
        #expect(server.requests("window.close").count == 1)
        #expect(controller.issue == nil)
    }

    /// The second alert — uncommitted changes — is a reentrancy point too: what it closes is the
    /// window the task has once it is answered.
    @Test func forcingARemovalClosesTheWindowTheTaskHasAfterTheSecondAlert() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Remove", "Delete Changes and Remove"))
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        try "draft\n".write(toFile: task.worktreePath + "/notes.txt", atomically: true, encoding: .utf8)
        fixture.prompter.whileAsking = { prompt in
            guard prompt.message == "The worktree has uncommitted changes" else { return }
            controller.helper.handle(.snapshot(fixture.snapshot(tagging: task, in: "alive")))
        }

        await controller.confirmRemove(task: task)?.value

        #expect(controller.state.tasks.isEmpty)
        #expect(fixture.prompter.asked.map(\.message).last == "The worktree has uncommitted changes")
        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["alive"])
    }

    /// Adding a project asks whether to import its worktrees. If the project goes while that is
    /// asked, nothing is imported: a task whose project is gone fails every save.
    @Test func worktreesAreNotImportedIntoAProjectRemovedDuringTheAlert() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Import"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.workspace.mutate { $0.items = [] }
        #expect(controller.workspace.flush())
        try fixture.git.run(["worktree", "add", "-q", "-b", "feat/old", fixture.repo.path + "/.worktrees/old"], in: fixture.repo.path)
        fixture.prompter.whileAsking = { _ in
            if let added = controller.state.projects.first { controller.workspace.mutate { $0.removeItem(id: added.id) } }
        }

        await controller.addProject(path: fixture.repo.path)

        #expect(fixture.prompter.asked.map(\.message) == ["Import 1 worktree?"])
        #expect(controller.state.tasks.isEmpty)
        #expect(controller.workspace.flush())
    }

    @Test func aNewTaskUsesTheSavedModelFromTheControllersPreferences() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let model = try #require(ScratchHome.catalogue(.claude).dropFirst().first).id
        ModelSettings.save(ModelPreference(model: model, reasoning: nil), for: .claude,
                           defaults: fixture.controller.preferences.defaults)
        fixture.controller.sheets.presentNewTask(project: fixture.project)
        await fixture.controller.sheets.preparingSheet?.value
        guard case .newTask(let creation)? = fixture.controller.sheets.sheet else {
            Issue.record("New Task did not open"); return
        }
        #expect(creation.draft.model == model)
    }

    @Test func aSuccessfulTerminalReopenClearsItsFailureBanner() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let daemon = RecordingDaemon(failing: ["window.createTerminal": "temporary_failure"])
        controller.helper.setDaemonClient(daemon)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }
        controller.helper.handle(.snapshot(AppControllerTests.emptySnapshot))
        await controller.windows.restore(.terminal(terminal.id))?.value
        #expect(controller.issue != nil)
        daemon.failing = [:]
        await controller.windows.choose(.terminal(terminal.id))?.value
        #expect(controller.state.terminal(id: terminal.id)?.windowId != nil)
        #expect(controller.issue == nil)
    }

    // -- terminals and windows -----------------------------------------------------------------

    /// Like a task's removal, a terminal's closes the window the terminal has now.
    @Test func removingATerminalClosesTheWindowItHasNow() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let clicked = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        var reopened = clicked
        reopened.windowId = "alive"
        controller.workspace.mutate { $0.terminals = [reopened] }

        await controller.close(terminal: clicked)?.value

        #expect(controller.state.terminals.isEmpty)
        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["alive"])
    }

    /// Remove while the terminal's window is still reopening says so; the restore then finishes.
    @Test func removingATerminalWhileItReopensSaysWhy() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.createTerminal")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }

        // A restore opens only into an iTerm2 known to be there, and quiet.
        controller.helper.handle(.snapshot(AppControllerTests.emptySnapshot))
        let reopening = controller.windows.restore(.terminal(terminal.id))
        try await server.received("window.createTerminal")
        #expect(controller.close(terminal: terminal) == nil)

        #expect(controller.issue?.title == "“Shell” is still reopening its window. Try Remove Terminal again once it has.")
        server.release()
        await reopening?.value
        #expect(controller.state.terminals.map(\.windowId) == ["terminal-window"])
        #expect(server.requests("window.close").isEmpty)
    }

    /// A second Remove while the first is still closing the window asks nothing of the daemon.
    @Test func aTerminalIsClosedOnceWhileItsCloseIsInFlight() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "alive", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }

        let closing = controller.close(terminal: terminal)
        try await server.received("window.close")
        #expect(controller.close(terminal: terminal) == nil)
        server.release()
        await closing?.value

        #expect(controller.state.terminals.isEmpty)
        #expect(server.requests("window.close").count == 1)
    }

    /// Restoring a terminal whose row went while its window opened closes that window.
    @Test func aWindowReopenedForATerminalThatWentMeanwhileIsClosed() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.createTerminal")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }

        // A restore opens only into an iTerm2 known to be there, and quiet.
        controller.helper.handle(.snapshot(AppControllerTests.emptySnapshot))
        let reopening = controller.windows.restore(.terminal(terminal.id))
        try await server.received("window.createTerminal")
        controller.workspace.mutate { $0.terminals = [] }
        server.release()
        await reopening?.value

        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["terminal-window"])
    }

    // -- creating a task -----------------------------------------------------------------------

    /// A second create in the same project while one runs used to return as though it had
    /// succeeded, closing its sheet with nothing made. It says why instead, and the sheet stays.
    @Test func aCreateWhileAnotherRunsInTheProjectSaysSo() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let first = Task { try await controller.createTask(draft: fixture.draft("First"), project: fixture.project) }
        try await server.received("window.createTask")

        await #expect {
            try await controller.createTask(draft: fixture.draft("Second"), project: fixture.project)
        } throws: { ($0 as? ActionUnavailable)?.message == "A task or review is already being created in Repo. Try again once it is." }
        server.release()
        try await first.value
        #expect(controller.state.tasks.map(\.title) == ["First"])
    }

    /// A create selects its new row, and a selection change makes an activation still in flight for
    /// the old row stale: that click's window must not take focus from the new task's.
    @Test func creatingATaskCancelsAnActivationStillInFlight() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.setFrame")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let old = try fixture.addTask(windowId: "old")
        let click = controller.focus.select(.task(old.id))
        try await server.received("window.setFrame")

        let create = Task { try await controller.createTask(draft: fixture.draft("New"), project: fixture.project) }
        await eventually(describing: "the created task to join the old one") { controller.state.tasks.count == 2 }
        server.release()
        try await create.value
        await click?.value

        let created = try #require(controller.state.tasks.first { $0.id != old.id })
        #expect(controller.focus.selectedTaskId == created.id)
        #expect(server.requests("window.activate").isEmpty)
    }

    /// iTerm2's background preference goes to the daemon once per iTerm2 connection, by the path that
    /// reports a failure — not also, unreported, whenever the socket connects.
    @Test func theBackgroundPreferenceIsSentOncePerItermConnection() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)

        controller.helper.handle(.itermConnected("3.6"))
        try await server.received("interface.setMatchItermBackground")
        try await Task.sleep(for: .milliseconds(100))

        #expect(server.requests("interface.setMatchItermBackground").count == 1)
    }

    /// Settings' Save hands the switch over whether or not it moved; only a move is stored and sent.
    @Test func settingsSendsTheBackgroundOnlyWhenItChanges() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)

        #expect(controller.helper.setMatchItermBackground(false) == nil)
        await controller.helper.setMatchItermBackground(true)?.value
        #expect(controller.helper.setMatchItermBackground(true) == nil)

        #expect(controller.preferences.matchItermBackground)
        #expect(server.requests("interface.setMatchItermBackground").map { $0.params["matchItermBackground"] as? Bool } == [true])
    }

    /// New Task, New Review, New Terminal and Settings each read something off the main actor
    /// before they open. A sheet the person opens in that gap — the menu is still enabled — is
    /// the one they are typing into: the late one is dropped, not put over it.
    enum SlowSheet: CaseIterable { case newTask, newReview, newTerminal, settings }

    @Test(arguments: SlowSheet.allCases) func aSheetOpenedWhileAnotherPreparesIsNotReplacedByIt(_ slow: SlowSheet) async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        switch slow {
        case .newTask: controller.presentNewTask(project: fixture.project)
        case .newReview: controller.presentNewReview(project: fixture.project)
        case .newTerminal: controller.presentNewTerminal(project: fixture.project)
        case .settings: controller.presentSettings()
        }
        let preparing = try #require(controller.sheets.preparingSheet)

        controller.presentNewDivider()
        await preparing.value

        #expect(controller.sheet?.id == "divider-new", "⌘N then ⌘D leaves the divider sheet up")
    }

    /// The same for a sheet the controller did not open itself: whatever fills the slot first keeps it.
    @Test(arguments: SlowSheet.allCases) func aPreparedSheetNeverReplacesOneAlreadyUp(_ slow: SlowSheet) async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        switch slow {
        case .newTask: controller.presentNewTask(project: fixture.project)
        case .newReview: controller.presentNewReview(project: fixture.project)
        case .newTerminal: controller.presentNewTerminal(project: fixture.project)
        case .settings: controller.presentSettings()
        }
        let preparing = try #require(controller.sheets.preparingSheet)

        controller.sheet = .newDivider
        await preparing.value

        #expect(controller.sheet?.id == "divider-new")
    }

    /// Opening another sheet by any route cancels the preparation, so nothing is left to finish.
    @Test func everySheetPresenterCancelsAPendingPreparation() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: nil)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }
        // With the project's branch read, New Terminal opens at once too.
        await controller.checkouts.refresh().value
        try #require(controller.checkouts.projectBranch[fixture.project.id] != nil)
        let presenters: [(String, () -> Void)] = [
            ("divider", { controller.presentNewDivider() }),
            ("new terminal", { controller.presentNewTerminal(project: fixture.project) }),
            ("rename divider", { controller.presentRename(divider: SidebarDivider(id: UUID(), name: "D")) }),
            ("rename task", { controller.presentRename(task: task) }),
            ("rename terminal", { controller.presentRename(terminal: terminal) }),
            ("jira projects", { controller.presentJiraProjects(for: fixture.project) }),
        ]
        for (name, present) in presenters {
            controller.sheet = nil
            controller.presentNewTask(project: fixture.project)
            let preparing = try #require(controller.sheets.preparingSheet)
            present()
            await preparing.value
            #expect(preparing.isCancelled, "\(name) cancels the preparation")
            #expect(controller.sheet?.id.hasPrefix("task-") == false, "\(name) is not replaced by New Task")
            #expect(controller.sheet != nil, "\(name) opened its own sheet")
        }
    }

    /// New Terminal names the branch the checkout monitor read for the project, the one the
    /// terminal's row and tab titles will show, and so opens at once. Only before the monitor's first
    /// pass does it ask git, off the main actor.
    @Test func newTerminalOpensAtOnceOnTheBranchTheCheckoutMonitorRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRunner.hermetic()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: root.path)
        let project = Project(id: UUID(), name: "Repo", path: root.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        // The monitor's answer differs from git's, so the sheet says which one it took.
        let seen = WorkspaceScan(branchByCwd: [:], projectBranch: [project.id: "feat/seen"], missingCheckouts: [], removedTasks: [], remotes: [:])
        let controller = AppController(preferences: .scratch(), git: git, scan: { _, _, _, _, _, _, _ in seen })
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        controller.workspace.mutate { $0.items = [.project(project)] }

        controller.presentNewTerminal(project: project)
        await (try #require(controller.sheets.preparingSheet)).value
        guard case .newTerminal(_, let name, let branch)? = controller.sheet else { Issue.record("expected New Terminal"); return }
        #expect(branch == "main", "git's answer, before the monitor has one")
        #expect(name == TerminalItem.defaultName)

        controller.sheet = nil
        await controller.checkouts.refresh().value
        controller.presentNewTerminal(project: project)
        #expect(controller.sheets.preparingSheet == nil)
        guard case .newTerminal(_, let name, let branch)? = controller.sheet else { Issue.record("expected New Terminal at once"); return }
        #expect(branch == "feat/seen")
        #expect(name == TerminalItem.defaultName)
    }

    /// The row can go while its window opens. The window is then closed, not left behind unowned.
    @Test func aWindowOpenedForATaskThatWentMeanwhileIsClosed() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let create = Task { try await controller.createTask(draft: fixture.draft("Gone"), project: fixture.project) }
        try await server.received("window.createTask")

        controller.workspace.mutate { $0.tasks = [] }
        server.release()
        try await create.value

        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(controller.state.tasks.isEmpty)
    }
}
