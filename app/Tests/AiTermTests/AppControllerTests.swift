import AppKit
import Foundation
import Observation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
@Suite(.serialized) struct AppControllerTests {
    @Test func failedLoadCannotSaveEmptyState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let original = Data("{broken".utf8)
        try original.write(to: url)
        let controller = AppController(store: StateStore(url: url), preferences: .scratch())
        #expect(throws: (any Error).self) { try controller.workspace.load() }
        #expect(!controller.canChangeWorkspace)
        #expect(!controller.workspace.flush())
        controller.start()
        #expect(controller.helper.daemon == nil)
        #expect(controller.helper.itermConnection.banner == .info("Starting AiTerm’s helper…"))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func retrySavesCurrentStateAndClearsOnlyStorageError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.workspace.load()
        #expect(controller.workspace.flush())
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        controller.workspace.mutate { $0.lastModelByAgent[.claude] = "sonnet" }
        #expect(!controller.workspace.flush())
        #expect(controller.persistenceError != nil)
        #expect(!controller.canChangeWorkspace)
        controller.helper.itermConnection = .itermReconnecting
        controller.workspace.mutate { $0.lastModelByAgent[.claude] = "opus" }
        try FileManager.default.removeItem(at: store.backupURL)
        #expect(controller.workspace.flush())
        #expect(try store.load().lastModelByAgent[.claude] == "opus")
        #expect(controller.persistenceError == nil)
        #expect(controller.helper.itermConnection == .itermReconnecting)
    }

    @Test func restoreLoadsWorkspaceAndLoadDoesNotReplaceUnsavedEdits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        var saved = AppState.empty
        saved.lastModelByAgent[.claude] = "sonnet"
        try store.save(saved)
        try store.save(.empty)
        try Data("{broken".utf8).write(to: store.url)
        let controller = AppController(store: store, preferences: .scratch())
        try controller.workspace.restoreBackup()
        #expect(controller.state == saved)
        #expect(controller.workspaceLoaded)
        #expect(controller.canChangeWorkspace)
        controller.workspace.mutate { $0.lastModelByAgent[.claude] = "opus" }
        try controller.workspace.load()
        #expect(controller.state.lastModelByAgent[.claude] == "opus")
    }

    @Test func unsavedWorkspaceRejectsNewCommands() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.workspace.load()
        let project = Project(id: UUID(), name: "Repo", path: dir.path, provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.workspace.mutate { $0.items = [.project(project)] }
        #expect(controller.workspace.flush())
        try controller.breakSaving()
        let original = controller.state
        controller.projects.toggleCollapsed(project)
        controller.sheets.presentNewTask(project: project)
        controller.sheets.presentNewTerminal(project: project)
        #expect(controller.terminals.newTerminal(project: project, name: "Shell") == nil)
        await controller.projects.confirmRemove(project: project)
        #expect(controller.sheet == nil)
        #expect(controller.state == original)
        let draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        do {
            try await controller.launcher.createTask(draft: draft, project: project)
            Issue.record("An unsaved workspace must reject creation before invoking Git")
        } catch {
            #expect(error.localizedDescription == "Save or recover the workspace before creating a task.")
        }
    }

    /// An empty project draws collapsed and cannot be opened, so a click on its header must not
    /// flip the stored state underneath — the project would otherwise open on its first task.
    @Test func togglingAProjectWithNoRowsDoesNothing() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = fixtureProject("Empty")
        let busy = fixtureProject("Busy")
        controller.workspace.mutate { state in
            state.items = [.project(empty), .project(busy)]
            state.terminals = [TerminalItem(id: UUID(), projectId: busy.id, name: "Shell", windowId: nil, createdAt: Date())]
        }

        controller.projects.toggleCollapsed(empty)
        controller.projects.toggleCollapsed(busy)
        #expect(controller.state.projects.map(\.collapsed) == [false, true])
    }

    /// Focus View (⌘F) reads the rows' live statuses, as the sidebar draws them: the project whose agent is done
    /// opens, the one only working folds, and the result is saved.
    @Test func focusViewOpensOnlyWaitingProjectsAndPersists() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        var waiting = fixtureProject("Waiting"); waiting.collapsed = true
        let busy = fixtureProject("Busy")
        controller.workspace.mutate { state in
            state.append(project: waiting)
            state.append(project: busy)
        }
        let done = TaskItem.stub(in: waiting, title: "Done"), working = TaskItem.stub(in: busy, title: "Working")
        controller.workspace.mutate { $0.tasks = [done, working] }
        #expect(controller.canShowFocusView)

        controller.live.sessions = [SessionInfo.stub("a", window: "w1", task: done, state: .done, agent: .claude),
                                    SessionInfo.stub("b", window: "w2", task: working, state: .working, agent: .claude)]
        #expect(controller.canShowFocusView)
        controller.showFocusView()

        #expect(controller.state.projects.map(\.collapsed) == [false, true])
        #expect(try controller.savedWorkspace().projects.map(\.collapsed) == [false, true])
    }

    /// ⌘F again, with every project already where it would put it, writes nothing and saves nothing.
    @Test func focusViewSavesNothingWhenTheLayoutIsUnchanged() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let waiting = fixtureProject("Waiting")
        controller.workspace.mutate { $0.append(project: waiting) }
        let done = TaskItem.stub(in: waiting, title: "Done")
        controller.workspace.mutate { $0.tasks = [done] }
        controller.live.sessions = [SessionInfo.stub(window: "w", task: done, state: .done)]
        controller.showFocusView()
        #expect(controller.workspace.flush())
        try FileManager.default.removeItem(at: controller.workspace.file.url)

        controller.showFocusView()

        #expect(!FileManager.default.fileExists(atPath: controller.workspace.file.url.path))
    }

    /// Focus View also goes to the first row waiting on you, in the order the sidebar draws them:
    /// projects top to bottom, and within one its terminals above its tasks. With nothing waiting it
    /// leaves the selection where it was.
    @Test func focusViewSelectsTheFirstRowNeedingAttention() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let busy = fixtureProject("Busy"), waiting = fixtureProject("Waiting")
        controller.workspace.mutate { state in
            state.append(project: busy)
            state.append(project: waiting)
        }
        let working = TaskItem(id: UUID(), projectId: busy.id, title: "Busy", branch: "feat/x", worktreePath: busy.path,
                               baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                               appendTicket: false, createdAt: Date(), windowId: nil)
        let done = TaskItem(id: UUID(), projectId: waiting.id, title: "Done", branch: "feat/y", worktreePath: waiting.path,
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(), windowId: nil)
        let asking = TerminalItem(id: UUID(), projectId: waiting.id, name: "Shell", windowId: "w3", createdAt: Date())
        controller.workspace.mutate { state in
            state.tasks = [working, done]
            state.terminals = [asking]
        }
        func session(_ id: String, window: String, task: TaskItem?, state: SessionState) -> SessionInfo {
            SessionInfo(sessionId: id, windowId: window, tabIndex: 0, taskId: task?.id.uuidString, projectId: task == nil ? waiting.id.uuidString : nil,
                        agent: .claude, model: nil, state: state, title: "", cwd: "/")
        }

        controller.live.sessions = [session("a", window: "w1", task: working, state: .working),
                                    session("b", window: "w2", task: done, state: .done),
                                    session("c", window: "w3", task: nil, state: .needsInput)]
        controller.showFocusView()
        #expect(controller.focus.selection == .terminal(asking.id))

        controller.live.sessions = [session("a", window: "w1", task: working, state: .working),
                                    session("b", window: "w2", task: done, state: .done)]
        controller.showFocusView()
        #expect(controller.focus.selection == .task(done.id))

        controller.live.sessions = [session("a", window: "w1", task: working, state: .working)]
        controller.showFocusView()
        #expect(controller.focus.selection == .task(done.id))
    }

    /// Greyed out while a sheet is up — its search fields are where ⌘F would otherwise land — and
    /// while the workspace cannot be saved, when it must change nothing even if called.
    @Test func focusViewIsOffBehindASheetAndInALockedWorkspace() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = fixtureProject("Busy")
        controller.workspace.mutate { state in
            state.append(project: project)
            state.terminals = [TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "w", createdAt: Date())]
        }
        controller.live.sessions = [SessionInfo(sessionId: "a", windowId: "w", tabIndex: 0, taskId: nil, projectId: project.id.uuidString,
                                                agent: .claude, model: nil, state: .needsInput, title: "", cwd: project.path)]
        controller.workspace.mutate { state in state.updateProject(id: project.id) { $0.collapsed = true } }
        #expect(controller.canShowFocusView)

        controller.sheet = .jiraProjects(project)
        #expect(!controller.canShowFocusView)
        controller.sheet = nil

        try controller.breakSaving()
        #expect(!controller.canShowFocusView)
        controller.showFocusView()
        #expect(controller.state.projects.map(\.collapsed) == [true])
    }

    /// List View (⌘L) opens every project with rows and saves it; like Focus View it is off behind
    /// a sheet and in a locked workspace, and with no project to open.
    @Test func listViewOpensEveryProjectWithRowsAndIsOffWhenItCannotSave() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!controller.canShowListView)
        var folded = fixtureProject("Folded"); folded.collapsed = true
        var empty = fixtureProject("Empty"); empty.collapsed = true
        controller.workspace.mutate { state in
            state.append(project: folded)
            state.append(project: empty)
            state.terminals = [TerminalItem(id: UUID(), projectId: folded.id, name: "Shell", windowId: nil, createdAt: Date())]
        }
        #expect(controller.canShowListView)

        controller.sheet = .jiraProjects(folded)
        #expect(!controller.canShowListView)
        controller.sheet = nil

        controller.showListView()
        #expect(controller.state.projects.map(\.collapsed) == [false, true])
        #expect(try controller.savedWorkspace().projects.map(\.collapsed) == [false, true])

        controller.workspace.mutate { state in state.updateProject(id: folded.id) { $0.collapsed = true } }
        try controller.breakSaving()
        #expect(!controller.canShowListView)
        controller.showListView()
        #expect(controller.state.projects.map(\.collapsed) == [true, true])
    }

    @Test func movingAProjectSwapsItWithItsNeighbourAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.workspace.load()
        let first = Project(id: UUID(), name: "First", path: "/first", provider: .git,
                            remoteUrl: nil, addedAt: Date(), collapsed: true)
        let moved = Project(id: UUID(), name: "Moved", path: "/moved", provider: .git,
                            remoteUrl: nil, addedAt: Date(), collapsed: false)
        let last = Project(id: UUID(), name: "Last", path: "/last", provider: .git,
                           remoteUrl: nil, addedAt: Date(), collapsed: true)
        let child = TaskItem(id: UUID(), projectId: moved.id, title: "Child", branch: "feat/child",
                             worktreePath: "/moved/.worktrees/child", baseBranch: "main", jira: nil,
                             agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil,
                             appendTicket: false, createdAt: Date(), windowId: nil)
        let terminal = TerminalItem(id: UUID(), projectId: moved.id, name: "Shell", windowId: nil,
                                    createdAt: Date())
        controller.workspace.mutate { state in
            state.items = [.project(first), .project(moved), .project(last)]
            state.tasks = [child]
            state.terminals = [terminal]
        }

        #expect(controller.projects.move(itemId: moved.id, .up))
        #expect(controller.state.projects.map(\.id) == [moved.id, first.id, last.id])
        #expect(controller.state.projects.first?.collapsed == false)
        #expect(controller.state.tasks == [child])
        #expect(controller.state.terminals == [terminal])
        let saved = try controller.savedWorkspace()
        #expect(saved.projects.map(\.id) == [moved.id, first.id, last.id])
        #expect(saved.tasks.map(\.projectId) == [moved.id])
        #expect(saved.terminals.map(\.projectId) == [moved.id])

        #expect(controller.projects.move(itemId: moved.id, .down))
        #expect(controller.projects.move(itemId: moved.id, .down))
        #expect(controller.state.projects.map(\.id) == [first.id, last.id, moved.id])
        #expect(try controller.savedWorkspace().projects.map(\.id) == [first.id, last.id, moved.id])
    }

    @Test func aProjectKeepsTheJiraProjectsItIsGivenOnceEach() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.workspace.load()
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let jiraSite = URL(string: "https://example.atlassian.net")!
        let frontend = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: jiraSite)
        let portal = JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: jiraSite)
        controller.workspace.mutate { $0.items = [.project(project)] }
        #expect(controller.workspace.flush())

        controller.sheets.presentJiraProjects(for: project)
        #expect(controller.sheet?.id == "project-jira-\(project.id)")

        controller.projects.setJiraProjects([frontend, portal, frontend], on: project)
        #expect(controller.state.projects[0].jiraProjects == [frontend, portal], "a project is linked once")
        #expect(try controller.savedWorkspace().projects[0].jiraProjects == [frontend, portal])

        controller.projects.setJiraProjects([], on: project)
        #expect(controller.state.projects[0].jiraProjects.isEmpty)
        #expect(try controller.savedWorkspace().projects[0].jiraProjects.isEmpty)
    }

    /// A workspace that could not be read is locked, and linking changes it.
    @Test func aLockedWorkspaceNeitherOpensNorSavesJiraProjects() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.workspace.mutate { $0.items = [.project(project)] }
        #expect(!controller.canChangeWorkspace)

        controller.sheets.presentJiraProjects(for: project)
        #expect(controller.sheet == nil)
        controller.projects.setJiraProjects([JiraProjectRef(id: "1", key: "SHOP", name: "Storefront",
                                                   siteURL: URL(string: "https://example.atlassian.net")!)], on: project)
        #expect(controller.state.projects[0].jiraProjects.isEmpty)
    }

    /// Picking a nested folder adds its repository and names that choice in a toast.
    @Test(arguments: [false, true]) func pickingARepositoryOrItsChildAddsTheRepository(inside: Bool) async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.workspace.mutate { $0.items = [] }
        #expect(controller.workspace.flush())
        let folder = inside ? fixture.repo.appendingPathComponent("app") : fixture.repo
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fixture.prompter.folder = folder

        await controller.projects.addProject()

        #expect(controller.sheet == nil)
        #expect(fixture.prompter.asked.isEmpty)
        #expect(controller.state.projects.map(\.path) == [fixture.repo.path])
        #expect(controller.state.projects.first?.jiraProjects == [])
        #expect(try controller.savedWorkspace().projects.map(\.path) == [fixture.repo.path])
        #expect(controller.toastState.toast?.message == (inside ? "Added repo, the repository around the folder you picked." : nil))
    }

    /// A completion toast comes down by itself once its lifetime has passed, and is up until then.
    @Test func aToastIsTakenDownAfterItsLifetime() async {
        let controller = AppController(preferences: .scratch(), toastLifetime: .milliseconds(30))
        controller.notices.showToast("Task removed.")
        #expect(controller.toastState.toast?.message == "Task removed.")

        await eventually { controller.toastState.toast == nil }
        #expect(controller.toastState.toast == nil)
    }

    /// The "already in your projects" alert stays.
    @Test func pickingAProjectAlreadyAddedSaysSoAndAddsNothing() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "OK"))
        defer { fixture.cleanUp() }
        fixture.prompter.folder = fixture.repo

        await fixture.controller.projects.addProject()

        #expect(fixture.prompter.asked.map(\.message) == ["Repo is already in your projects"])
        #expect(fixture.controller.state.projects == [fixture.project])
    }

    @Test func aProjectCannotMovePastTheEdgesOrInALockedWorkspace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.workspace.load()
        let first = Project(id: UUID(), name: "First", path: "/first", provider: .git,
                            remoteUrl: nil, addedAt: Date(), collapsed: false)
        let last = Project(id: UUID(), name: "Last", path: "/last", provider: .git,
                           remoteUrl: nil, addedAt: Date(), collapsed: false)
        let stranger = Project(id: UUID(), name: "Stranger", path: "/elsewhere", provider: .git,
                               remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.workspace.mutate { $0.items = [.project(first), .project(last)] }
        #expect(controller.workspace.flush())

        #expect(!controller.state.canMove(id: first.id, .up))
        #expect(controller.state.canMove(id: first.id, .down))
        #expect(controller.state.canMove(id: last.id, .up))
        #expect(!controller.state.canMove(id: last.id, .down))
        #expect(!controller.state.canMove(id: stranger.id, .up))
        #expect(!controller.projects.move(itemId: first.id, .up))
        #expect(!controller.projects.move(itemId: last.id, .down))
        #expect(!controller.projects.move(itemId: stranger.id, .down))
        #expect(controller.state.projects.map(\.id) == [first.id, last.id])

        try controller.breakSaving()
        #expect(!controller.projects.move(itemId: first.id, .down))
        #expect(controller.state.projects.map(\.id) == [first.id, last.id])
    }

    @Test func startupRecoveryUsesNativeRestoreAction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        var saved = AppState.empty
        saved.lastModelByAgent[.claude] = "sonnet"
        try store.save(saved)
        try store.save(.empty)
        try Data("{broken".utf8).write(to: store.url)
        let prompter = ScriptedPrompter(answering: "Restore Backup")
        let controller = AppController(store: store, preferences: .scratch(), prompter: prompter)
        let app = AiTermApp(controller: controller)
        #expect(app.prepareWorkspace())
        #expect(prompter.asked.map(\.message) == ["AiTerm couldn’t open your workspace"])
        #expect(controller.state == saved)
        #expect(controller.canChangeWorkspace)
        #expect(try store.load() == saved)
    }

    /// ⎋ on the workspace that won't open is Quit: nothing is changed, and AiTerm doesn't launch.
    @Test func escapeOnTheWorkspaceAlertQuits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: store.url)
        let prompter = ScriptedPrompter(answering: "⎋")
        let app = AiTermApp(controller: AppController(store: store, preferences: .scratch(), prompter: prompter))
        #expect(!app.prepareWorkspace())
        let asked = try #require(prompter.asked.first)
        #expect(asked.buttons[try #require(asked.escapeButton)] == "Quit")
        #expect(try Data(contentsOf: store.url) == Data("{broken".utf8))
    }

    @Test func failedQuitCanBeCancelledAndRetried() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        // ⎋ is Cancel Quit, the default and the safe choice.
        let prompter = ScriptedPrompter(answering: "⎋", "Quit Without Saving")
        let controller = AppController(store: store, preferences: .scratch(), prompter: prompter)
        let app = AiTermApp(controller: controller)
        #expect(app.prepareWorkspace())
        #expect(controller.workspace.flush())
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        controller.workspace.mutate { $0.lastModelByAgent[.claude] = "opus" }
        #expect(!controller.workspace.flush())
        // Closing the last window triggers quit too; Cancel must make Retry reachable again.
        app.window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled, .closable])
        app.window.isReleasedWhenClosed = false
        defer { app.window.orderOut(nil) }
        #expect(app.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(app.window.isVisible)
        #expect(controller.state.lastModelByAgent[.claude] == "opus")
        #expect(app.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(try store.load().lastModelByAgent[.claude] == nil)
        try FileManager.default.removeItem(at: store.backupURL)
        #expect(app.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(try store.load().lastModelByAgent[.claude] == "opus")
    }

    /// A controller that goes away takes its workspace with it: nothing the workspace tells of a
    /// change holds on to it, so a test's store does not live on to save into a deleted folder.
    @Test func aControllerThatGoesAwayTakesItsWorkspace() throws {
        weak var workspace: WorkspaceStore?
        weak var live: LiveSessions?
        weak var notices: Notices?
        do {
            let (controller, dir) = try loadedController()
            defer { try? FileManager.default.removeItem(at: dir) }
            workspace = controller.workspace; live = controller.live; notices = controller.notices
        }
        #expect(workspace == nil)
        #expect(live == nil)
        #expect(notices == nil)
    }

    /// A change still waiting on its save when the app quits is saved before it does.
    @Test func quittingSavesAChangeStillWaitingOnItsSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        let app = AiTermApp(controller: controller)
        #expect(app.prepareWorkspace())
        controller.workspace.mutate { $0.lastModelByAgent[.claude] = "opus" }
        #expect((try? store.load())?.lastModelByAgent[.claude] == nil, "still waiting")

        #expect(app.applicationShouldTerminate(NSApplication.shared) == .terminateNow)

        #expect(try store.load().lastModelByAgent[.claude] == "opus")
    }

    /// A window found gone leaves its row owed it — a task's and a terminal's alike — and its
    /// selection and checkout where they were.
    @Test func observedClosesLeaveRowsOwedAndPreserveCheckouts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.workspace.load()
        let worktree = dir.appendingPathComponent("repo/.worktrees/work")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let project = Project(id: UUID(), name: "Repo", path: dir.appendingPathComponent("repo").path, provider: .git,
                              remoteUrl: nil, addedAt: Date(timeIntervalSince1970: 0), collapsed: false)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work",
                            worktreePath: worktree.path, baseBranch: "main", jira: nil,
                            agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: "Do the work",
                            appendTicket: false, createdAt: Date(timeIntervalSince1970: 0),
                            windowId: "w1")
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "w2",
                                    createdAt: Date(timeIntervalSince1970: 0))
        var state = AppState.empty
        state.items = [.project(project)]; state.tasks = [task]; state.terminals = [terminal]
        controller.workspace.mutate { $0 = state }
        controller.focus.browse(.task(task.id))
        controller.windows.handleWindowClosed("w1")
        #expect(controller.focus.selectedTaskId == task.id, "the row stays, and so does its selection")
        #expect(controller.state.tasks.map(\.windowId) == [nil])
        #expect(try controller.savedWorkspace().tasks.map(\.windowId) == [nil])
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        // A stale not_found response for the old window cannot clear its replacement.
        var replacement = task
        replacement.windowId = "w3"
        controller.workspace.mutate { $0.tasks = [replacement] }
        controller.windows.handleWindowClosed(task.windowId)
        #expect(controller.state.tasks[0].windowId == "w3")
        controller.focus.browse(.terminal(terminal.id))
        // Observations still update memory when saving is blocked.
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        controller.windows.handleWindowClosed("w2")
        #expect(controller.state.terminals.map(\.windowId) == [nil], "the terminal stays, owed")
        #expect(controller.focus.selectedTerminalId == terminal.id)
        #expect(!controller.workspace.flush())
        #expect(controller.persistenceError != nil)
        controller.windows.handleWindowClosed("w2")
        controller.windows.handleWindowClosed(nil)
        try FileManager.default.removeItem(at: store.backupURL)
        #expect(controller.workspace.flush())
        #expect(try store.load() == controller.state)
    }

    @Test func disconnectedSnapshotPreservesAssociationsAndConnectedSnapshotReattachesOrClears() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        let task = TaskItem(id: UUID(), projectId: UUID(), title: "Ongoing", branch: "feat/ongoing",
                            worktreePath: "/wt", baseBranch: "main", jira: nil, agent: .codex,
                            model: "model", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(), windowId: "old")
        controller.workspace.mutate { $0.append(project: Project(id: task.projectId, name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)) }
        controller.workspace.mutate { $0.tasks = [task] }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: false, sessions: [], usage: .empty)))
        #expect(controller.state.tasks[0].windowId == "old")
        let session = SessionInfo(sessionId: "s", windowId: "recovered", tabIndex: 0, taskId: task.id.uuidString,
                                  projectId: nil, agent: .shell, model: nil, state: .idle, title: "", cwd: "/wt")
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [session], usage: .empty)))
        #expect(controller.state.tasks[0].windowId == "recovered")
        controller.focus.browse(.task(task.id))
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
        #expect(controller.state.tasks.map(\.windowId) == [nil], "the task stays, windowless")
        #expect(controller.focus.selectedTaskId == task.id)
        #expect(try controller.savedWorkspace().tasks.map(\.windowId) == [nil])
    }

    @Test func providerContextsSurviveTabChangesAndHideOutsideTasks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work",
                            worktreePath: "/repo/.worktrees/work", baseBranch: "main", jira: nil,
                            agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(), windowId: "w1")
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "w2",
                                    createdAt: Date())
        controller.workspace.mutate { state in
            state.items = [.project(project)]
            state.tasks = [task]
            state.terminals = [terminal]
        }
        controller.focus.browse(.task(task.id))

        let first = SessionInfo(sessionId: "a", windowId: "w1", tabIndex: 0,
                                taskId: task.id.uuidString, projectId: project.id.uuidString,
                                agent: .claude, model: "sonnet", state: .idle, title: "a", cwd: task.worktreePath,
                                active: true, contextPercent: 42)
        let second = SessionInfo(sessionId: "b", windowId: "w1", tabIndex: 1,
                                 taskId: task.id.uuidString, projectId: project.id.uuidString,
                                 agent: .claude, model: "sonnet", state: .idle, title: "b", cwd: task.worktreePath,
                                 active: false, contextPercent: 18)
        let codex = SessionInfo(sessionId: "c", windowId: "w1", tabIndex: 2,
                                taskId: task.id.uuidString, projectId: project.id.uuidString,
                                agent: .codex, model: "gpt-5.6", state: .idle, title: "c", cwd: task.worktreePath,
                                active: false, contextPercent: 64)
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: false,
                                                               sessions: [first, second, codex], usage: .empty)))
        #expect(controller.live.contextPercents(for: controller.focus.selection) == [.claude: 42, .codex: 64])

        var firstInactive = first
        firstInactive.active = false
        var secondActive = second
        secondActive.active = true
        controller.helper.handle(.sessionChanged(firstInactive))
        controller.helper.handle(.sessionChanged(secondActive))
        #expect(controller.live.contextPercents(for: controller.focus.selection) == [.claude: 42, .codex: 64],
                "Changing tabs keeps the task's latest telemetry until that tab reports")

        var propagatedFirst = firstInactive
        propagatedFirst.contextPercent = 18
        controller.helper.handle(.sessionChanged(propagatedFirst))
        #expect(controller.live.contextPercents(for: controller.focus.selection) == [.claude: 18, .codex: 64],
                "A tab re-reporting its old percentage still replaces the task's value")

        secondActive.contextPercent = 27
        controller.helper.handle(.sessionChanged(secondActive))
        #expect(controller.live.contextPercents(for: controller.focus.selection) == [.claude: 27, .codex: 64])
        secondActive.contextPercent = nil
        controller.helper.handle(.sessionChanged(secondActive))
        #expect(controller.live.contextPercents(for: controller.focus.selection) == [.claude: 27, .codex: 64],
                "Missing telemetry never erases a known value")

        var updatedCodex = codex
        updatedCodex.contextPercent = 71
        controller.helper.handle(.sessionChanged(updatedCodex))
        #expect(controller.live.contextPercents(for: controller.focus.selection) == [.claude: 27, .codex: 71])

        controller.focus.browse(.terminal(terminal.id))
        #expect(controller.live.contextPercents(for: controller.focus.selection).isEmpty, "A terminal no agent has reported in has none")
        controller.focus.browse(.task(task.id))
        #expect(controller.live.contextPercents(for: controller.focus.selection) == [.claude: 27, .codex: 71])

        controller.workspace.mutate { $0.tasks = [] }
        controller.workspace.mutate { $0.tasks = [task] }
        #expect(controller.live.contextPercents(for: controller.focus.selection).isEmpty, "Removing a task evicts its cached context")
    }

    /// A terminal carries no task tag, so its tabs are matched on the window — the same way its
    /// sidebar row finds its avatars. Starting an agent in a plain terminal must light up `ctx`.
    @Test func terminalContextFollowsTheAgentStartedInIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "w2",
                                    createdAt: Date())
        let other = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal 2", windowId: "w3",
                                 createdAt: Date())
        controller.workspace.mutate { state in
            state.items = [.project(project)]
            state.terminals = [terminal, other]
        }
        controller.focus.browse(.terminal(terminal.id))

        let shell = SessionInfo(sessionId: "t", windowId: "w2", tabIndex: 0, taskId: nil,
                                projectId: project.id.uuidString, agent: .shell, model: nil, state: .idle,
                                title: "zsh", cwd: "/repo", active: true)
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: false,
                                                               sessions: [shell], usage: .empty)))
        #expect(controller.live.contextPercents(for: controller.focus.selection).isEmpty)

        var claude = shell
        claude.agent = .claude
        controller.helper.handle(.sessionChanged(claude))
        #expect(controller.live.contextPercents(for: controller.focus.selection).isEmpty, "The agent has not reported yet")
        claude.contextPercent = 12
        controller.helper.handle(.sessionChanged(claude))
        #expect(controller.live.contextPercents(for: controller.focus.selection) == [.claude: 12])

        var tab = claude
        tab.sessionId = "u"; tab.tabIndex = 1; tab.contextPercent = nil
        claude.active = false
        controller.helper.handle(.sessionChanged(claude))
        controller.helper.handle(.sessionOpened(tab))
        #expect(controller.live.contextPercents(for: controller.focus.selection) == [.claude: 12], "A new tab keeps the terminal's last value")

        controller.focus.browse(.terminal(other.id))
        #expect(controller.live.contextPercents(for: controller.focus.selection).isEmpty, "Another terminal's window is not this one")

        controller.workspace.mutate { $0.terminals = [other] }
        controller.workspace.mutate { $0.terminals = [terminal, other] }
        controller.focus.browse(.terminal(terminal.id))
        #expect(controller.live.contextPercents(for: controller.focus.selection).isEmpty, "Closing a terminal evicts its cached context")
    }

    @Test(arguments: [false, true]) func createdTaskSurvivesDisconnectedLaunchAndSaveFailure(failSave: Bool) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = GitRunner.hermetic()
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "init"], in: repo.path)
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        let project = Project(id: UUID(), name: "Repo", path: repo.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.workspace.mutate { $0.items = [.project(project)] }
        #expect(controller.workspace.flush())
        if failSave { try FileManager.default.createDirectory(at: controller.workspace.file.backupURL, withIntermediateDirectories: false) }
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle("Create once")
        try await controller.launcher.createTask(draft: draft, project: project)
        let created = try #require(controller.state.tasks.first)
        #expect(controller.state.tasks.count == 1)
        #expect(created.windowId == nil)
        #expect(FileManager.default.fileExists(atPath: created.worktreePath))
        if failSave {
            #expect(controller.persistenceError != nil)
            try FileManager.default.removeItem(at: controller.workspace.file.backupURL)
            #expect(controller.workspace.flush())
        } else { #expect(controller.issue?.title.contains("Task created") == true) }
        let saved = try controller.savedWorkspace().tasks
        #expect(saved.map(\.id) == [created.id])
        #expect(saved.first?.worktreePath == created.worktreePath)
        #expect(saved.first?.branch == created.branch)
        #expect(saved.first?.windowId == nil)
    }

    /// The controller hands its git to what it builds, so a test's fixtures never run the developer's
    /// own: creating a task makes its checkout through the controller's runner, and the agent
    /// command's `.aiterm/` exclusion too.
    @Test func aControllerRunsTheGitItWasGiven() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try GitRunner.hermetic().run(["init", "-q", "-b", "main"], in: repo.path)
        try GitRunner.hermetic().run(["commit", "--allow-empty", "-m", "init"], in: repo.path)
        let recording = RecordingGitRunner(forwardingTo: .hermetic())
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch(), git: recording)
        try controller.workspace.load()
        let project = Project(id: UUID(), name: "Repo", path: repo.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.workspace.mutate { $0.items = [.project(project)] }
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle("Through the runner")
        draft.promptText = String(repeating: "long ", count: 400)
        try await controller.launcher.createTask(draft: draft, project: project)
        let asked = recording.calls.map(\.args)
        #expect(asked.contains { $0.starts(with: ["worktree", "add"]) })
        #expect(asked.filter { $0.contains("info/exclude") }.count == 2, "`.worktrees/` and the first-prompt exclusion are asked of the same runner")
    }

    /// A project whose `.worktreeinclude` selects an `.env` that cannot be read, so cannot be copied.
    private func projectWithAnUnreadableEnv(in dir: URL) throws -> (controller: AppController, project: Project) {
        let repo = dir.appendingPathComponent("repo"), env = repo.appendingPathComponent(".env").path
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = GitRunner.hermetic()
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try ".env\n".write(toFile: repo.path + "/.gitignore", atomically: true, encoding: .utf8)
        try ".env\n".write(toFile: repo.path + "/.worktreeinclude", atomically: true, encoding: .utf8)
        try git.run(["add", ".gitignore", ".worktreeinclude"], in: repo.path)
        try git.run(["commit", "-q", "-m", "init"], in: repo.path)
        try "SECRET=1\n".write(toFile: env, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: env)
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch(), git: git)
        try controller.workspace.load()
        let project = Project(id: UUID(), name: "Repo", path: repo.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.workspace.mutate { $0.items = [.project(project)] }
        #expect(controller.workspace.flush())
        return (controller, project)
    }

    /// A file `.worktreeinclude` selects that could not be copied costs the task nothing: it is
    /// created, its window opens, its worktree is there, and the banner names the file — about the
    /// task, so it goes when the task does.
    @Test func aFileThatCouldNotBeCopiedIsNamedInTheBanner() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("repo/.env").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let (controller, project) = try projectWithAnUnreadableEnv(in: dir)
        defer { controller.shutdown() }
        let server = RecordingDaemon()
        controller.helper.setDaemonClient(server)
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle("Unreadable env")
        try await controller.launcher.createTask(draft: draft, project: project)
        let created = try #require(controller.state.tasks.first)
        #expect(FileManager.default.fileExists(atPath: created.worktreePath))
        #expect(server.requests.map(\.method).last == "window.createTask", "the window opens all the same")
        #expect(controller.issue == OperationIssue(title: "Couldn’t copy .env into the new worktree.", subject: created.id))
        #expect(controller.toastState.toast == nil)
    }

    /// The banner holds one report: when the window's own report replaces it, that one says the
    /// files too, so the person is not left thinking everything came.
    @Test func aWindowReportAfterACopyThatLeftFilesOutSaysSoToo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("repo/.env").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let (controller, project) = try projectWithAnUnreadableEnv(in: dir)
        defer { controller.shutdown() }
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle("Unreadable env")
        try await controller.launcher.createTask(draft: draft, project: project)   // no daemon
        #expect(controller.issue?.title == "Task created. Its window opens once AiTerm reconnects; start the agent there manually.")
        #expect(controller.issue?.reason == "Couldn’t copy .env into the new worktree.")
    }

    /// A copy that left nothing out says nothing: no banner for the task it made.
    @Test func aCompleteWorktreeIncludeCopyHasNoBanner() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        try await fixture.controller.launcher.createTask(draft: fixture.draft("Plain"), project: fixture.project)
        #expect(fixture.controller.issue == nil)
    }

    /// The alert-level courtesy. The guarantee is `TaskWorkflow.remove`'s own refusal, tested in
    /// `TaskWorkflowTests`; this only proves the checkbox is never offered for a review.
    @Test @MainActor func reviewRemovalNeverOffersToDeleteTheBranch() {
        let review = TaskItem(id: UUID(), projectId: UUID(), title: "Review gift card", branch: "feat-gift",
                              worktreePath: "/tmp/wt", baseBranch: "main", jira: nil, kind: .review, mr: nil,
                              agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: false,
                              createdAt: Date(), windowId: nil)
        let task = TaskItem(id: UUID(), projectId: UUID(), title: "Add gift card", branch: "feat/gift",
                            worktreePath: "/tmp/wt2", baseBranch: "main", jira: nil,
                            agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(), windowId: nil)
        #expect(TaskRemover.offersBranchDeletion(for: review) == false)
        #expect(TaskRemover.offersBranchDeletion(for: task) == true)
    }

    /// Removing a project deliberately leaves its worktrees on disk, so re-adding it re-imports
    /// them — and before this test the import built every one of them as a `.task`. A review that
    /// came back as a task gets a "Delete local branch" checkbox over a merge request's branch,
    /// which is the one thing the app must never offer. The marker is the lock reason
    /// a review's worktree is made with; `managedWorktrees()` now carries it through.
    @Test func importingWorktreesKeepsAReviewAReview() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let prompter = ScriptedPrompter(answering: "Import")
        let controller = AppController(store: store, preferences: .scratch(), prompter: prompter)
        try controller.workspace.load()

        let repo = try Self.repoWithATaskAndAReviewWorktree(git: controller.git)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: repo).deletingLastPathComponent()) }

        await controller.projects.addProject(path: repo)
        #expect(prompter.asked.map(\.message) == ["Import 2 worktrees?"])

        #expect(controller.state.projects.count == 1)
        let imported = Dictionary(uniqueKeysWithValues: controller.state.tasks.map { ($0.branch, $0.kind) })
        #expect(imported.count == 2, "both worktrees import: \(controller.state.tasks.map(\.branch))")
        #expect(imported["feat/mr-branch"] == .review, "the review's lock reason survives the round trip")
        #expect(imported["feat/a-task"] == .task, "a task stays a task")
        #expect(controller.state.tasks.filter { $0.kind == .review }.allSatisfy { !TaskRemover.offersBranchDeletion(for: $0) })
    }

    /// The base branch of an imported worktree is what git said the default branch is. When git
    /// could not be asked (a timeout under load), writing "main" into every task would keep a
    /// transient failure in the saved state for good, so nothing is offered and nothing is imported.
    @Test func importingWorktreesIsNotOfferedWhenTheDefaultBranchCannotBeRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompter = ScriptedPrompter(answering: "Import")
        let flaky = DefaultBranchFailingGit()
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch(),
                                        prompter: prompter, git: flaky)
        try controller.workspace.load()
        let repo = try Self.repoWithATaskAndAReviewWorktree(git: controller.git)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: repo).deletingLastPathComponent()) }

        await controller.projects.addProject(path: repo)
        #expect(controller.state.projects.count == 1, "the project itself is added")
        #expect(prompter.asked.isEmpty)
        #expect(controller.state.tasks.isEmpty, "no task is saved with a guessed base branch")
        // The offer is made only now, so the person is told it was not.
        #expect(controller.issue?.title == "Couldn’t check repo for worktrees to import.")
        #expect(controller.issue?.reason == "Git timed out after \(GitRunner.localTimeout) s.")
    }

    /// Once the workspace can no longer be saved, no import could be made either,
    /// so a check for worktrees that fails meanwhile is not reported: the banner over the failed
    /// save is what matters, as a pick that fails then is not reported either.
    @Test func aFailedImportCheckIsNotReportedOnceTheWorkspaceCannotChange() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let git = GatedDefaultBranchGit()
        let controller = AppController(store: store, preferences: .scratch(), prompter: ScriptedPrompter(), git: git)
        try controller.workspace.load()
        let repo = try Self.repoWithATaskAndAReviewWorktree(git: GitRunner.hermetic())
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: repo).deletingLastPathComponent()) }

        let adding = Task { await controller.projects.addProject(path: repo) }
        await eventually { git.isWaiting }
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        controller.workspace.mutate { $0.lastModelByAgent[.claude] = "sonnet" }
        #expect(!controller.workspace.flush())
        git.open()
        await adding.value

        #expect(controller.state.projects.count == 1)
        #expect(controller.issue == nil, "got \(String(describing: controller.issue))")
    }

    /// A git that cannot say whether the folder is a repository — it timed out, or would
    /// not start — is not a folder outside one. Nothing is added, and the banner says why, where
    /// the pick used to do nothing at all.
    @Test func aProjectGitCannotInspectIsReportedNotSilentlyDropped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompter = ScriptedPrompter()
        let git = FlakyGitRunner()
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch(),
                                        prompter: prompter, git: git)
        try controller.workspace.load()
        let repo = try Self.repoWithATaskAndAReviewWorktree(git: GitRunner.hermetic())
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: repo).deletingLastPathComponent()) }

        git.failing = true
        await controller.projects.addProject(path: repo)
        #expect(controller.state.projects.isEmpty)
        #expect(prompter.asked.isEmpty)
        #expect(controller.issue == OperationIssue(title: "Couldn’t add the project.",
                                                   reason: "Git timed out after \(GitRunner.localTimeout) s.",
                                                   detail: "git rev-parse --show-toplevel failed:\ngit timed out after \(GitRunner.localTimeout) s"))
    }

    /// A repository holding one worktree of each kind, made by the same calls the app makes: a
    /// task's through `addTaskWorktree` and a review's through `addReviewWorktree`.
    /// Resolved with POSIX `realpath(3)`, as `WorktreesTests` does: git reports the physical path
    /// for a repository under `/var/folders`, and an unresolved one is added as "the repository
    /// around the folder you picked", a path the project would then not match.
    private static func repoWithATaskAndAReviewWorktree(git: any GitRunning) throws -> String {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let root = realpath(raw, nil).map { defer { free($0) }; return String(cString: $0) } ?? raw
        let repo = root + "/repo"
        try git.run(["init", "-q", "-b", "main", repo], in: root)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try git.run(["branch", "feat/mr-branch"], in: repo)
        _ = try Repository(repo, git: git).addTaskWorktree(slug: "a-task", branch: "feat/a-task", base: "main")
        _ = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        return repo
    }

    func loadedController() throws -> (AppController, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        return (controller, dir)
    }

    private func fixtureProject(_ name: String) -> Project {
        Project(id: UUID(), name: name, path: "/" + name, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
    }

    /// The checkout monitor re-runs the refresh pass every two seconds. A pass that learns
    /// nothing new must not tell observers anything changed: each notification re-renders the
    /// whole sidebar, which idled at 1.5 renders a second before this was guarded.
    @Test func aRefreshPassThatFindsNothingNewPublishesNothing() async throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkout = dir.appendingPathComponent("repo/.worktrees/a")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let project = Project(id: UUID(), name: "repo", path: dir.appendingPathComponent("repo").path, provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "a", branch: "feat/a",
                            worktreePath: checkout.path, baseBranch: "main", jira: nil, agent: .claude,
                            model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: true,
                            createdAt: Date(), windowId: nil)
        controller.workspace.mutate { state in
            state.append(project: project)
            state.tasks.append(task)
        }
        controller.live.sessions = [SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: nil, projectId: nil,
                                           agent: .shell, model: nil, state: .idle, title: "", cwd: checkout.path)]
        await controller.checkouts.refresh().value

        let changed = Mutex(false)
        withObservationTracking {
            _ = (controller.state, controller.live.sessions, controller.checkouts.branchByCwd, controller.checkouts.projectBranch, controller.checkouts.missingCheckouts)
        } onChange: { changed.withLock { $0 = true } }
        await controller.checkouts.refresh().value
        #expect(!changed.withLock { $0 })
    }

    /// Most session events are a context fill, a model or a Codex spinner title, none of which a
    /// sidebar row draws: the rows' projection of the tabs moves only for what they read, and
    /// matches the full list in everything they read.
    @Test func theSidebarsRowsReadOnlyWhatTheyDraw() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = fixtureProject("repo")
        let task = TaskItem(id: UUID(), projectId: project.id, title: "a", branch: "feat/a", worktreePath: "/repo/.worktrees/a",
                            baseBranch: "main", jira: nil, agent: .codex, model: "gpt-5.6", reasoning: nil,
                            firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w")
        controller.workspace.mutate { state in
            state.append(project: project)
            state.tasks = [task]
        }
        let tab = SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: task.id.uuidString, projectId: nil,
                              agent: .codex, model: "gpt-5.6", state: .working, title: "⠋ repo", cwd: "/repo", contextPercent: 12)
        controller.live.sessions = [tab]
        func rowsChange(_ change: (inout SessionInfo) -> Void) -> Bool {
            let changed = Mutex(false)
            withObservationTracking { _ = controller.live.rowSessions } onChange: { changed.withLock { $0 = true } }
            var next = controller.live.sessions[0]
            change(&next)
            controller.live.handle(.sessionChanged(next))
            return changed.withLock { $0 }
        }
        #expect(!rowsChange { $0.contextPercent = 40 })
        #expect(!rowsChange { $0.title = "⠙ repo" })
        #expect(!rowsChange { $0.model = "gpt-5.7"; $0.reasoning = "high" })
        #expect(rowsChange { $0.state = .done })
        #expect(rowsChange { $0.agentCwd = "/repo/.worktrees/a" })
        #expect(rowsChange { $0.active = true })
        let state = controller.state, branches = ["/repo/.worktrees/a": "feat/a"]
        #expect(SidebarModel.entries(state: state, sessions: controller.live.rowSessions, branchByCwd: branches, projectBranch: [:])
                == SidebarModel.entries(state: state, sessions: controller.live.sessions, branchByCwd: branches, projectBranch: [:]))
    }

    /// Session events arrive several a second, most of them a context fill or a state. Only a
    /// change the scan or the tab titles read — where a tab is, which row it belongs to — runs a
    /// pass; the checkout monitor catches everything else.
    @Test func onlyASessionChangeTheScanReadsRunsAScan() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scans = ScanCounter()
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch(),
                                       scan: { cwds, projects, tasks, branches, remotes, diffs, defaultBranches in
                                           scans.increment()
                                           return WorkspaceScan.run(cwds: cwds, projects: projects, tasks: tasks,
                                                                    branches: branches, remotes: remotes, diffs: diffs,
                                                                    defaultBranches: defaultBranches)
                                       })
        try controller.workspace.load()
        let task = UUID(), project = UUID()
        var tab = SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: task.uuidString, projectId: project.uuidString,
                              agent: .claude, model: "opus", state: .idle, title: "claude", cwd: dir.path)
        controller.helper.handle(.sessionOpened(tab))
        await controller.checkouts.refreshTask?.value
        #expect(scans.count == 1)

        tab.contextPercent = 40; controller.helper.handle(.sessionChanged(tab))
        tab.state = .working; controller.helper.handle(.sessionChanged(tab))
        tab.model = "sonnet"; controller.helper.handle(.sessionChanged(tab))
        tab.title = "✳ claude"; controller.helper.handle(.sessionChanged(tab))
        tab.active = true; controller.helper.handle(.sessionChanged(tab))
        #expect(controller.checkouts.refreshTask == nil)
        #expect(scans.count == 1)

        let moves: [(inout SessionInfo) -> Void] = [
            { $0.agentCwd = dir.appendingPathComponent("sub").path }, { $0.windowId = "w2" }, { $0.tabIndex = 1 },
            { $0.taskId = nil }, { $0.projectId = nil }, { $0.sessionId = "t" },
        ]
        for (n, move) in moves.enumerated() {
            move(&tab)
            controller.helper.handle(.sessionChanged(tab))
            await controller.checkouts.refreshTask?.value
            #expect(scans.count == n + 2)
        }
    }

    /// `shutdown()` stops what `start()` started, and a later `start()` starts all of it again:
    /// the checkout monitor, and the helper's search for Python.
    @Test func startingAgainAfterShutdownRestartsTheMonitorAndTheHelper() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scans = ScanCounter(), pythonLookups = ScanCounter()
        // A bundle, so the helper looks for Python, through a lookup that runs no login shell.
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: dir, bundledResourcesURL: dir,
                                       scan: { _, _, _, _, _, _, _ in
                                           scans.increment()
                                           return WorkspaceScan(branchByCwd: [:], projectBranch: [:], missingCheckouts: [],
                                                                removedTasks: [], remotes: [:])
                                       },
                                       findPython: { pythonLookups.increment(); return nil })
        try controller.workspace.load()

        controller.start()
        controller.shutdown()
        controller.start()
        defer { controller.shutdown() }

        await eventually { scans.count != 0 && controller.helper.itermConnection != .starting }
        #expect(scans.count >= 1, "the restarted monitor runs a pass")
        // The first start's lookup was cancelled with it: only the restarted helper reports.
        #expect(controller.helper.itermConnection == .pythonMissing, "the restarted helper looked for Python")
        #expect(pythonLookups.count >= 1)
    }

    /// The badge is recomputed on every write to `state` and `sessions`; only a new label is
    /// written to the dock.
    @Test func theDockBadgeIsWrittenOnlyWhenItsLabelChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var written: [String?] = []
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch(),
                                       setBadge: { written.append($0) })
        try controller.workspace.load()
        let project = fixtureProject("repo")
        let task = TaskItem(id: UUID(), projectId: project.id, title: "a", branch: "feat/a", worktreePath: "/repo/a",
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                            appendTicket: true, createdAt: Date(), windowId: "w")
        controller.workspace.mutate { state in
            state.append(project: project)
            state.tasks = [task]
        }
        var tab = SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: task.id.uuidString, projectId: nil,
                              agent: .claude, model: nil, state: .needsInput, title: "", cwd: "/repo/a")
        controller.live.sessions = [tab]
        #expect(written == ["1"])

        tab.contextPercent = 30
        controller.live.sessions = [tab]
        controller.workspace.mutate { $0.append(divider: SidebarDivider(id: UUID(), name: "")) }
        #expect(written == ["1"])

        tab.state = .working
        controller.live.sessions = [tab]
        #expect(written == ["1", nil])
    }

    /// The badge counts the rows Focus View steps through: a done task and a terminal waiting on
    /// you count as a task needing input does.
    @Test func theDockBadgeCountsWhatFocusViewStepsThrough() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var written: [String?] = []
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch(),
                                       setBadge: { written.append($0) })
        try controller.workspace.load()
        let project = fixtureProject("repo")
        let task = TaskItem(id: UUID(), projectId: project.id, title: "a", branch: "feat/a", worktreePath: "/repo/a",
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                            appendTicket: true, createdAt: Date(), windowId: "w")
        let shell = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "t", createdAt: Date())
        controller.workspace.mutate { $0.append(project: project) }
        controller.workspace.mutate { $0.tasks = [task] }; controller.workspace.mutate { $0.terminals = [shell] }
        controller.live.sessions = [
            SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: task.id.uuidString, projectId: nil,
                        agent: .claude, model: nil, state: .done, title: "", cwd: "/repo/a"),
            SessionInfo(sessionId: "u", windowId: "t", tabIndex: 0, taskId: nil, projectId: project.id.uuidString,
                        agent: .codex, model: nil, state: .needsInput, title: "", cwd: "/repo"),
        ]
        #expect(written.last == "2")
        controller.showFocusView()
        #expect(controller.focus.selectedTerminalId == shell.id, "Focus View goes to the first of the rows the badge counts")
    }

    @Test func addingADividerAppendsItAtTheEndAndPersists() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.workspace.mutate { $0.append(project: fixtureProject("repo")) }
        controller.projects.addDivider(name: "  Work  ")
        #expect(controller.state.items.last?.divider?.name == "Work")
        #expect(controller.persistenceError == nil)
        #expect(try controller.savedWorkspace().items.count == 2)
    }

    @Test func renamingADividerTrimsAndRenamingATaskChangesOnlyTheTitle() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = fixtureProject("repo")
        controller.workspace.mutate { $0.append(project: project) }
        let rule = SidebarDivider(id: UUID(), name: "Work")
        controller.workspace.mutate { $0.append(divider: rule) }
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Old", branch: "feat/x", worktreePath: "/wt",
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil,
                            firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w1")
        controller.workspace.mutate { $0.tasks = [task] }

        controller.projects.rename(divider: rule, to: "  Personal ")
        #expect(controller.state.items.last?.divider?.name == "Personal")

        controller.projects.rename(task: task, to: "  New title ")
        #expect(controller.state.tasks[0].title == "New title")
        #expect(controller.state.tasks[0].branch == "feat/x")
        #expect(controller.state.tasks[0].worktreePath == "/wt")
        #expect(controller.state.tasks[0].windowId == "w1")

        // An emptied field leaves a task's title alone; a divider may legitimately have no name.
        controller.projects.rename(task: task, to: "   ")
        #expect(controller.state.tasks[0].title == "New title")
        controller.projects.rename(divider: rule, to: "   ")
        #expect(controller.state.items.last?.divider?.name == "")
    }

    @Test func deletingADividerLeavesEveryProjectAndTaskInPlace() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = fixtureProject("repo")
        controller.workspace.mutate { $0.append(project: project) }
        let rule = SidebarDivider(id: UUID(), name: "Work")
        controller.workspace.mutate { state in
            state.append(divider: rule)
            state.terminals = [TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "w1", createdAt: Date())]
        }
        controller.projects.removeDivider(rule)
        #expect(controller.state.items.map(\.id) == [project.id])
        #expect(controller.state.terminals.count == 1)
    }

    @Test func movingAProjectPastADividerChangesItsGroupWithoutReorderingProjects() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = (fixtureProject("a"), fixtureProject("b"))
        let rule = SidebarDivider(id: UUID(), name: "Work")
        controller.workspace.mutate { state in
            state.append(project: a)
            state.append(divider: rule)
            state.append(project: b)
        }

        let moved = controller.projects.move(itemId: b.id, .up)
        #expect(moved)
        #expect(controller.state.items.map(\.id) == [a.id, b.id, rule.id])
        #expect(controller.state.projects.map(\.name) == ["a", "b"])
        #expect(!controller.state.canMove(id: a.id, .up))
        #expect(!controller.state.canMove(id: rule.id, .down))
        #expect(controller.state.canMove(id: rule.id, .up))
    }

    @Test func dividerActionsAreRefusedWhileTheWorkspaceIsLocked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try Data("{broken".utf8).write(to: url)
        let controller = AppController(store: StateStore(url: url), preferences: .scratch())
        #expect(throws: (any Error).self) { try controller.workspace.load() }
        controller.projects.addDivider(name: "Work")
        #expect(controller.state.items.isEmpty)
        controller.sheets.presentNewDivider()
        #expect(controller.sheet == nil)
    }

    @Test func theRenameAndNewDividerSheetsCarryTheirTarget() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = fixtureProject("repo")
        controller.workspace.mutate { $0.append(project: project) }
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Old", branch: "feat/x", worktreePath: "/wt",
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil,
                            firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: nil)
        controller.workspace.mutate { $0.tasks = [task] }

        controller.sheets.presentNewDivider()
        #expect(controller.sheet?.id == "divider-new")

        controller.sheets.presentRename(task: task)
        #expect(controller.sheet?.id == "rename-\(task.id)")
        guard case .rename(let target)? = controller.sheet else { Issue.record("expected a rename sheet"); return }
        #expect(target.name == "Old")
        #expect(target.title == "Rename task")
        #expect(target.subtitle == "The branch and worktree keep their names.")
    }

    /// A terminal is renamed through the same `NameSheet` as a task: the row's name changes and is
    /// saved; its window and everything else about it stay as they are.
    @Test func renamingATerminalChangesAndSavesOnlyItsName() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = fixtureProject("repo")
        controller.workspace.mutate { $0.append(project: project) }
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "w1", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }

        controller.sheets.presentRename(terminal: terminal)
        guard case .rename(let target)? = controller.sheet else { Issue.record("expected a rename sheet"); return }
        #expect(target == .terminal(terminal))
        #expect(target.title == "Rename terminal")
        #expect(target.fieldLabel == "Terminal name")
        #expect(target.name == "Terminal")

        controller.projects.rename(terminal: terminal, to: "  Dev server ")
        #expect(controller.state.terminals == [TerminalItem(id: terminal.id, projectId: project.id, name: "Dev server",
                                                            windowId: "w1", createdAt: terminal.createdAt)])
        #expect(try controller.savedWorkspace().terminals.map(\.name) == ["Dev server"])

        // An emptied field keeps the name, as a task's does.
        controller.projects.rename(terminal: terminal, to: "   ")
        #expect(controller.state.terminals.map(\.name) == ["Dev server"])
    }
}

/// Counts the passes a controller's scanner is asked for, from the background thread each runs on.
private final class ScanCounter: Sendable {
    private let passes = Mutex(0)
    var count: Int { passes.withLock { $0 } }
    func increment() { passes.withLock { $0 += 1 } }
}

/// `DefaultBranchFailingGit`, whose failing read first waits for `open()`, so a test acts while
/// the import's git is still running.
private final class GatedDefaultBranchGit: GitRunning {
    private let inner = DefaultBranchFailingGit()
    private let gate = Mutex((waiting: false, open: false))
    var isWaiting: Bool { gate.withLock { $0.waiting } }
    func open() { gate.withLock { $0.open = true } }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if args.first == "for-each-ref", args.contains("refs/remotes/origin/HEAD") {
            gate.withLock { $0.waiting = true }
            while !gate.withLock({ $0.open }) { Thread.sleep(forTimeInterval: 0.005) }
        }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}

/// A git that times out whenever it is asked for the default branch's name, as it does under load.
private struct DefaultBranchFailingGit: GitRunning {
    let inner: any GitRunning = GitRunner.hermetic()
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        // The one command that reads `origin/HEAD` and the usual names.
        if args.first == "for-each-ref", args.contains("refs/remotes/origin/HEAD") { throw GitError(args: args, code: 15, stderr: "git timed out after \(timeout) s", timedOut: true) }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}

extension AppControllerTests {
    /// The operators read Claude's conversations from the app's Claude folder, as every other reader does.
    @Test func theLiveOperatorsReadTheAppsClaudeFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let scan = WorkspaceScan(branchByCwd: [:], projectBranch: [:], missingCheckouts: [], removedTasks: [], remotes: [:])
        let controller = AppController.live(store: StateStore(url: home.appendingPathComponent("state.json")), preferences: .scratch(),
                                            harnessHome: home, claudeConfig: ClaudeConfig("~/profile"), bundledResourcesURL: nil,
                                            locateAgents: { nil }, setBadge: { _ in }, activateIterm: {}, launchIterm: {},
                                            itermRunning: { true }, backpackPorts: .inert, machineSensor: InertMachineSensor(),
                                            scan: { _, _, _, _, _, _, _ in scan })
        #expect(controller.operatorController.ports.claudeConfig.directory(home: home) == home.appendingPathComponent("profile"))
    }
}
