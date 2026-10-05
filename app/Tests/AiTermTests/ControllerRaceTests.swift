import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

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
        controller.confirmRemove(project: fixture.project)

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
        controller.confirmRemove(project: fixture.project)
        #expect(fixture.prompter.asked.last?.message == "Remove project “Repo”?", "free once both have opened")
    }

    /// A task's window opening — reopened here, or for a review — holds the project too.
    @Test func aProjectCannotBeRemovedWhileATaskWindowOpensInIt() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "OK"))
        let server = RecordingDaemon(holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)

        let reopening = controller.reopen(task: task)
        try await server.received("window.createTask")
        controller.confirmRemove(project: fixture.project)

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
        controller.state.terminals = [terminal]

        let closing = controller.close(terminal: terminal)
        try await server.received("window.close")
        controller.confirmRemove(project: fixture.project)

        #expect(fixture.prompter.asked.first?.detail.hasPrefix("One of its terminals is still opening or closing its window.") == true)
        server.release()
        await closing?.value
        #expect(controller.state.terminals.isEmpty)
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
        controller.state.removeItem(id: fixture.project.id)
        server.release()
        await opening?.value

        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["terminal-window"])
        #expect(controller.state.terminals.isEmpty)
        #expect(controller.persist())
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
        controller.state.terminals = [terminal]
        controller.focus.browse(.terminal(terminal.id))

        await controller.removeSelection()?.value

        #expect(fixture.prompter.asked.isEmpty)
        #expect(controller.state.terminals.isEmpty)
    }

    /// With nothing selected the key does nothing.
    @Test func removingNoSelectionDoesNothing() throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter())
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        _ = try fixture.addTask(windowId: "alive")
        #expect(fixture.controller.removeSelection() == nil)
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
            nestedRemoval = controller.confirmRemove(task: task)
        }

        #expect(controller.confirmRemove(task: task) == nil, "the nested Remove owns the removal")
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
        controller.state.projects = []
        #expect(controller.persist())
        try fixture.git.run(["worktree", "add", "-q", "-b", "feat/old", fixture.repo.path + "/.worktrees/old"], in: fixture.repo.path)
        fixture.prompter.whileAsking = { _ in
            if let added = controller.state.projects.first { controller.state.removeItem(id: added.id) }
        }

        await controller.addProject(path: fixture.repo.path)

        #expect(fixture.prompter.asked.map(\.message) == ["Import 1 worktree?"])
        #expect(controller.state.tasks.isEmpty)
        #expect(controller.persist())
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
        controller.state.terminals = [reopened]

        await controller.close(terminal: clicked)?.value

        #expect(controller.state.terminals.isEmpty)
        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["alive"])
    }

    /// Remove while the terminal's window is still reopening says so; the reopen then finishes.
    @Test func removingATerminalWhileItReopensSaysWhy() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.createTerminal")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        controller.state.terminals = [terminal]

        let reopening = controller.reopen(terminal: terminal, project: fixture.project)
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
        controller.state.terminals = [terminal]

        let closing = controller.close(terminal: terminal)
        try await server.received("window.close")
        #expect(controller.close(terminal: terminal) == nil)
        server.release()
        await closing?.value

        #expect(controller.state.terminals.isEmpty)
        #expect(server.requests("window.close").count == 1)
    }

    /// Reopening a terminal whose row went while its window opened closes that window.
    @Test func aWindowReopenedForATerminalThatWentMeanwhileIsClosed() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.createTerminal")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        controller.state.terminals = [terminal]

        let reopening = controller.reopen(terminal: terminal, project: fixture.project)
        try await server.received("window.createTerminal")
        controller.state.terminals = []
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
        try await fixture.until { controller.state.tasks.count == 2 }
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
        let preparing = try #require(controller.preparingSheet)

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
        let preparing = try #require(controller.preparingSheet)

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
        controller.state.terminals = [terminal]
        let presenters: [(String, () -> Void)] = [
            ("divider", { controller.presentNewDivider() }),
            ("rename divider", { controller.presentRename(divider: SidebarDivider(id: UUID(), name: "D")) }),
            ("rename task", { controller.presentRename(task: task) }),
            ("rename terminal", { controller.presentRename(terminal: terminal) }),
            ("jira projects", { controller.presentJiraProjects(for: fixture.project) }),
        ]
        for (name, present) in presenters {
            controller.sheet = nil
            controller.presentNewTask(project: fixture.project)
            let preparing = try #require(controller.preparingSheet)
            present()
            await preparing.value
            #expect(preparing.isCancelled, "\(name) cancels the preparation")
            #expect(controller.sheet?.id.hasPrefix("task-") == false, "\(name) is not replaced by New Task")
            #expect(controller.sheet != nil, "\(name) opened its own sheet")
        }
    }

    /// Reopen Window stays on the menu while the daemon is away, so it says why nothing happens.
    @Test func reopeningATaskWhileDisconnectedSaysSo() throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try fixture.addTask(windowId: nil)

        #expect(fixture.controller.reopen(task: task) == nil)

        #expect(fixture.controller.issue == .disconnected("Reopen Window again"))
        #expect(fixture.controller.issue?.title == "Disconnected. Try Reopen Window again once AiTerm reconnects.")
    }

    /// The refusal leaves the row unlocked: once the daemon is back, the same click goes through.
    @Test func aReopenRefusedWhileDisconnectedDoesNotLockTheRow() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try fixture.addTask(windowId: nil)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        fixture.controller.state.terminals = [terminal]
        #expect(fixture.controller.reopen(task: task) == nil)
        #expect(fixture.controller.reopen(terminal: terminal, project: fixture.project) == nil)

        fixture.controller.helper.setDaemonClient(server)
        await fixture.controller.reopen(task: task)?.value
        await fixture.controller.reopen(terminal: terminal, project: fixture.project)?.value

        #expect(fixture.controller.state.tasks.first?.windowId == "reopened")
        #expect(fixture.controller.state.terminals.first?.windowId == "terminal-window")
    }

    @Test func reopeningATerminalWhileDisconnectedSaysSo() throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        fixture.controller.state.terminals = [terminal]

        #expect(fixture.controller.reopen(terminal: terminal, project: fixture.project) == nil)

        #expect(fixture.controller.issue == .disconnected("Reopen Window again"))
    }

    /// A stale click — the row already has its window — is ignored whether or not the daemon is there.
    @Test func reopeningARowThatHasItsWindowStaysSilentWhileDisconnected() throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try fixture.addTask(windowId: "alive")

        #expect(fixture.controller.reopen(task: task) == nil)
        #expect(fixture.controller.issue == nil)
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

        controller.state.tasks = []
        server.release()
        try await create.value

        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(controller.state.tasks.isEmpty)
    }
}

/// A saved project in a real repository, a controller over it, and the prompter it asks.
@MainActor
struct RaceFixture {
    let root: URL
    let repo: URL
    let git = GitRunner()
    let project: Project
    let prompter: ScriptedPrompter
    let controller: AppController

    /// The root is resolved with `realpath(3)`: git reports the physical path of a repository under
    /// `/var/folders`, and adding the unresolved one adds it as "the repository around" that path.
    init(prompter: ScriptedPrompter? = nil, activateIterm: @escaping @MainActor () -> Void = {}) throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: realpath(raw, nil).map { defer { free($0) }; return String(cString: $0) } ?? raw)
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo.path)
        project = Project(id: UUID(), name: "Repo", path: repo.path, provider: .git,
                          remoteUrl: nil, addedAt: Date(), collapsed: false)
        let prompter = prompter ?? ScriptedPrompter()
        self.prompter = prompter
        controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(), prompter: prompter,
                                   activateIterm: activateIterm)
        try controller.loadWorkspace()
        controller.state.projects = [project]
        #expect(controller.persist())
    }

    /// A task with a real worktree, saved.
    func addTask(windowId: String?) throws -> TaskItem {
        let checkout = repo.appendingPathComponent(".worktrees/work").path
        try git.run(["worktree", "add", "-q", "-b", "feat/work", checkout], in: repo.path)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work",
                            worktreePath: checkout, baseBranch: "main", jira: nil, agent: .codex,
                            model: "model", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(timeIntervalSince1970: 0), windowId: windowId)
        controller.state.tasks.append(task)
        #expect(controller.persist())
        return task
    }

    /// A connected snapshot with one tab tagged with `task`, in window `windowId`.
    func snapshot(tagging task: TaskItem, in windowId: String) -> DaemonSnapshot {
        DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            SessionInfo(sessionId: "s", windowId: windowId, tabIndex: 0, taskId: task.id.uuidString, projectId: nil,
                        agent: .shell, model: nil, state: .idle, title: "", cwd: task.worktreePath),
        ], usage: .empty)
    }

    func draft(_ title: String) -> TaskDraft {
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle(title)
        return draft
    }

    /// Waits up to `TestDeadline` for `condition`, checked on the main actor between turns.
    func until(_ condition: () -> Bool) async throws {
        let deadline = TestDeadline.fromNow()
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
