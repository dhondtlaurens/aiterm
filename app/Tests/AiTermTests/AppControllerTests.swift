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
        #expect(throws: (any Error).self) { try controller.loadWorkspace() }
        #expect(!controller.canChangeWorkspace)
        #expect(!controller.persist())
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
        try controller.loadWorkspace()
        #expect(controller.persist())
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        controller.state.lastModelByAgent[.claude] = "sonnet"
        #expect(!controller.persist())
        #expect(controller.persistenceError != nil)
        #expect(!controller.canChangeWorkspace)
        controller.helper.itermConnection = .itermReconnecting
        controller.state.lastModelByAgent[.claude] = "opus"
        try FileManager.default.removeItem(at: store.backupURL)
        #expect(controller.persist())
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
        try controller.restoreWorkspace()
        #expect(controller.state == saved)
        #expect(controller.workspaceLoaded)
        #expect(controller.canChangeWorkspace)
        controller.state.lastModelByAgent[.claude] = "opus"
        try controller.loadWorkspace()
        #expect(controller.state.lastModelByAgent[.claude] == "opus")
    }

    @Test func unsavedWorkspaceRejectsNewCommands() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.loadWorkspace()
        let project = Project(id: UUID(), name: "Repo", path: dir.path, provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.state.projects = [project]
        #expect(controller.persist())
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        #expect(!controller.persist())
        let original = controller.state
        controller.toggleCollapsed(project)
        controller.presentNewTask(project: project)
        controller.presentNewTerminal(project: project)
        #expect(controller.newTerminal(project: project, name: "Shell") == nil)
        controller.confirmRemove(project: project)
        #expect(controller.sheet == nil)
        #expect(controller.state == original)
        let draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        do {
            try await controller.createTask(draft: draft, project: project)
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
        controller.state.projects = [empty, busy]
        controller.state.terminals = [TerminalItem(id: UUID(), projectId: busy.id, name: "Shell", windowId: nil, createdAt: Date())]

        controller.toggleCollapsed(empty)
        controller.toggleCollapsed(busy)
        #expect(controller.state.projects.map(\.collapsed) == [false, true])
    }

    /// Focus View (⌘F) reads the rows' live statuses, as the sidebar draws them: the project whose agent is done
    /// opens, the one only working folds, and the result is saved.
    @Test func focusViewOpensOnlyWaitingProjectsAndPersists() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        var waiting = fixtureProject("Waiting"); waiting.collapsed = true
        let busy = fixtureProject("Busy")
        controller.state.append(project: waiting)
        controller.state.append(project: busy)
        let done = TaskItem.stub(in: waiting, title: "Done"), working = TaskItem.stub(in: busy, title: "Working")
        controller.state.tasks = [done, working]
        #expect(controller.canShowFocusView)

        controller.live.sessions = [SessionInfo.stub("a", window: "w1", task: done, state: .done, agent: .claude),
                                    SessionInfo.stub("b", window: "w2", task: working, state: .working, agent: .claude)]
        #expect(controller.canShowFocusView)
        controller.showFocusView()

        #expect(controller.state.projects.map(\.collapsed) == [false, true])
        #expect(try controller.store.load().projects.map(\.collapsed) == [false, true])
    }

    /// ⌘F again, with every project already where it would put it, writes nothing and saves nothing.
    @Test func focusViewSavesNothingWhenTheLayoutIsUnchanged() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let waiting = fixtureProject("Waiting")
        controller.state.append(project: waiting)
        let done = TaskItem.stub(in: waiting, title: "Done")
        controller.state.tasks = [done]
        controller.live.sessions = [SessionInfo.stub(window: "w", task: done, state: .done)]
        controller.showFocusView()
        #expect(controller.persist())
        try FileManager.default.removeItem(at: controller.store.url)

        controller.showFocusView()

        #expect(!FileManager.default.fileExists(atPath: controller.store.url.path))
    }

    /// Focus View also goes to the first row waiting on you, in the order the sidebar draws them:
    /// projects top to bottom, and within one its terminals above its tasks. With nothing waiting it
    /// leaves the selection where it was.
    @Test func focusViewSelectsTheFirstRowNeedingAttention() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let busy = fixtureProject("Busy"), waiting = fixtureProject("Waiting")
        controller.state.append(project: busy)
        controller.state.append(project: waiting)
        let working = TaskItem(id: UUID(), projectId: busy.id, title: "Busy", branch: "feat/x", worktreePath: busy.path,
                               baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                               appendTicket: false, createdAt: Date(), windowId: nil)
        let done = TaskItem(id: UUID(), projectId: waiting.id, title: "Done", branch: "feat/y", worktreePath: waiting.path,
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(), windowId: nil)
        let asking = TerminalItem(id: UUID(), projectId: waiting.id, name: "Shell", windowId: "w3", createdAt: Date())
        controller.state.tasks = [working, done]
        controller.state.terminals = [asking]
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
        controller.state.append(project: project)
        controller.state.terminals = [TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "w", createdAt: Date())]
        controller.live.sessions = [SessionInfo(sessionId: "a", windowId: "w", tabIndex: 0, taskId: nil, projectId: project.id.uuidString,
                                                agent: .claude, model: nil, state: .needsInput, title: "", cwd: project.path)]
        controller.state.updateProject(id: project.id) { $0.collapsed = true }
        #expect(controller.canShowFocusView)

        controller.sheet = .jiraProjects(project)
        #expect(!controller.canShowFocusView)
        controller.sheet = nil

        #expect(controller.persist())
        try FileManager.default.createDirectory(at: controller.store.backupURL, withIntermediateDirectories: false)
        #expect(!controller.persist())
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
        controller.state.append(project: folded)
        controller.state.append(project: empty)
        controller.state.terminals = [TerminalItem(id: UUID(), projectId: folded.id, name: "Shell", windowId: nil, createdAt: Date())]
        #expect(controller.canShowListView)

        controller.sheet = .jiraProjects(folded)
        #expect(!controller.canShowListView)
        controller.sheet = nil

        controller.showListView()
        #expect(controller.state.projects.map(\.collapsed) == [false, true])
        #expect(try controller.store.load().projects.map(\.collapsed) == [false, true])

        controller.state.updateProject(id: folded.id) { $0.collapsed = true }
        try FileManager.default.createDirectory(at: controller.store.backupURL, withIntermediateDirectories: false)
        #expect(!controller.persist())
        #expect(!controller.canShowListView)
        controller.showListView()
        #expect(controller.state.projects.map(\.collapsed) == [true, true])
    }

    @Test func movingAProjectSwapsItWithItsNeighbourAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.loadWorkspace()
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
        controller.state.projects = [first, moved, last]
        controller.state.tasks = [child]
        controller.state.terminals = [terminal]

        #expect(controller.move(itemId: moved.id, .up))
        #expect(controller.state.projects.map(\.id) == [moved.id, first.id, last.id])
        #expect(controller.state.projects.first?.collapsed == false)
        #expect(controller.state.tasks == [child])
        #expect(controller.state.terminals == [terminal])
        let saved = try store.load()
        #expect(saved.projects.map(\.id) == [moved.id, first.id, last.id])
        #expect(saved.tasks.map(\.projectId) == [moved.id])
        #expect(saved.terminals.map(\.projectId) == [moved.id])

        #expect(controller.move(itemId: moved.id, .down))
        #expect(controller.move(itemId: moved.id, .down))
        #expect(controller.state.projects.map(\.id) == [first.id, last.id, moved.id])
        #expect(try store.load().projects.map(\.id) == [first.id, last.id, moved.id])
    }

    @Test func aProjectKeepsTheJiraProjectsItIsGivenOnceEach() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.loadWorkspace()
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let jiraSite = URL(string: "https://example.atlassian.net")!
        let frontend = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: jiraSite)
        let portal = JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: jiraSite)
        controller.state.projects = [project]
        #expect(controller.persist())

        controller.presentJiraProjects(for: project)
        #expect(controller.sheet?.id == "project-jira-\(project.id)")

        controller.setJiraProjects([frontend, portal, frontend], on: project)
        #expect(controller.state.projects[0].jiraProjects == [frontend, portal], "a project is linked once")
        #expect(try store.load().projects[0].jiraProjects == [frontend, portal])

        controller.setJiraProjects([], on: project)
        #expect(controller.state.projects[0].jiraProjects.isEmpty)
        #expect(try store.load().projects[0].jiraProjects.isEmpty)
    }

    /// A workspace that could not be read is locked, and linking changes it.
    @Test func aLockedWorkspaceNeitherOpensNorSavesJiraProjects() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.state.projects = [project]
        #expect(!controller.canChangeWorkspace)

        controller.presentJiraProjects(for: project)
        #expect(controller.sheet == nil)
        controller.setJiraProjects([JiraProjectRef(id: "1", key: "SHOP", name: "Storefront",
                                                   siteURL: URL(string: "https://example.atlassian.net")!)], on: project)
        #expect(controller.state.projects[0].jiraProjects.isEmpty)
    }

    /// The folder chooser adds the project at once: no sheet, no Jira projects linked, and — for a
    /// folder inside a repository — no alert, only a toast naming the repository that was added.
    @Test func pickingAFolderInsideARepositoryAddsTheRepositoryAndSaysSo() async throws {
        let fixture = try RaceFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.state.projects = []
        #expect(controller.persist())
        let inside = fixture.repo.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        fixture.prompter.folder = inside

        await controller.addProject()?.value

        #expect(controller.sheet == nil)
        #expect(fixture.prompter.asked.isEmpty, "the OK-only “Adding the repository folder” alert is gone")
        #expect(controller.state.projects.map(\.path) == [fixture.repo.path])
        #expect(controller.state.projects.first?.jiraProjects == [])
        #expect(try controller.store.load().projects.map(\.path) == [fixture.repo.path])
        #expect(controller.toastState.toast?.message == "Added repo, the repository around the folder you picked.")
    }

    @Test func pickingTheRepositoryItselfAddsItWithoutAToast() async throws {
        let fixture = try RaceFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.state.projects = []
        #expect(controller.persist())
        fixture.prompter.folder = fixture.repo

        await controller.addProject()?.value

        #expect(controller.sheet == nil)
        #expect(controller.state.projects.map(\.path) == [fixture.repo.path])
        #expect(controller.toastState.toast == nil)
    }

    /// A completion toast comes down by itself once its lifetime has passed, and is up until then.
    @Test func aToastIsTakenDownAfterItsLifetime() async {
        let controller = AppController(preferences: .scratch(), toastLifetime: .milliseconds(30))
        controller.showToast("Task removed.")
        #expect(controller.toastState.toast?.message == "Task removed.")

        await eventually { controller.toastState.toast == nil }
        #expect(controller.toastState.toast == nil)
    }

    /// The "already in your projects" alert stays.
    @Test func pickingAProjectAlreadyAddedSaysSoAndAddsNothing() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "OK"))
        defer { fixture.cleanUp() }
        fixture.prompter.folder = fixture.repo

        await fixture.controller.addProject()?.value

        #expect(fixture.prompter.asked.map(\.message) == ["Repo is already in your projects"])
        #expect(fixture.controller.state.projects == [fixture.project])
    }

    @Test func aProjectCannotMovePastTheEdgesOrInALockedWorkspace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.loadWorkspace()
        let first = Project(id: UUID(), name: "First", path: "/first", provider: .git,
                            remoteUrl: nil, addedAt: Date(), collapsed: false)
        let last = Project(id: UUID(), name: "Last", path: "/last", provider: .git,
                           remoteUrl: nil, addedAt: Date(), collapsed: false)
        let stranger = Project(id: UUID(), name: "Stranger", path: "/elsewhere", provider: .git,
                               remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.state.projects = [first, last]
        #expect(controller.persist())

        #expect(!controller.canMove(itemId: first.id, .up))
        #expect(controller.canMove(itemId: first.id, .down))
        #expect(controller.canMove(itemId: last.id, .up))
        #expect(!controller.canMove(itemId: last.id, .down))
        #expect(!controller.canMove(itemId: stranger.id, .up))
        #expect(!controller.move(itemId: first.id, .up))
        #expect(!controller.move(itemId: last.id, .down))
        #expect(!controller.move(itemId: stranger.id, .down))
        #expect(controller.state.projects.map(\.id) == [first.id, last.id])

        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        #expect(!controller.persist())
        #expect(!controller.canMove(itemId: first.id, .down))
        #expect(!controller.move(itemId: first.id, .down))
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
        #expect(controller.persist())
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        controller.state.lastModelByAgent[.claude] = "opus"
        #expect(!controller.persist())
        // Closing the last window triggers quit too; Cancel must make Retry reachable again.
        app.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
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

    @Test func observedClosesRemoveItemsClearSelectionAndPreserveCheckout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let controller = AppController(store: store, preferences: .scratch())
        try controller.loadWorkspace()
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
        state.projects = [project]; state.tasks = [task]; state.terminals = [terminal]
        controller.state = state
        controller.focus.browse(.task(task.id))
        controller.handleWindowClosed("w1")
        #expect(controller.focus.selectedTaskId == nil)
        #expect(controller.state.tasks.isEmpty)
        #expect(try store.load().tasks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        // A stale not_found response for the old window cannot clear its replacement.
        var replacement = task
        replacement.windowId = "w3"
        controller.state.tasks = [replacement]
        controller.handleWindowClosed(task.windowId)
        #expect(controller.state.tasks[0].windowId == "w3")
        controller.focus.browse(.terminal(terminal.id))
        // Observations still update memory when saving is blocked.
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        controller.handleWindowClosed("w2")
        #expect(controller.state.terminals.isEmpty)
        #expect(controller.focus.selectedTerminalId == nil)
        #expect(controller.persistenceError != nil)
        controller.handleWindowClosed("w2")
        controller.handleWindowClosed(nil)
        try FileManager.default.removeItem(at: store.backupURL)
        #expect(controller.persist())
        #expect(try store.load() == controller.state)
    }

    @Test func disconnectedSnapshotPreservesAssociationsAndConnectedSnapshotReattachesOrRemoves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        let task = TaskItem(id: UUID(), projectId: UUID(), title: "Ongoing", branch: "feat/ongoing",
                            worktreePath: "/wt", baseBranch: "main", jira: nil, agent: .codex,
                            model: "model", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(), windowId: "old")
        controller.state.projects = [Project(id: task.projectId, name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)]
        controller.state.tasks = [task]
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: false, sessions: [], usage: .empty)))
        #expect(controller.state.tasks[0].windowId == "old")
        let session = SessionInfo(sessionId: "s", windowId: "recovered", tabIndex: 0, taskId: task.id.uuidString,
                                  projectId: nil, agent: .shell, model: nil, state: .idle, title: "", cwd: "/wt")
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [session], usage: .empty)))
        #expect(controller.state.tasks[0].windowId == "recovered")
        controller.focus.browse(.task(task.id))
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
        #expect(controller.state.tasks.isEmpty)
        #expect(controller.focus.selectedTaskId == nil)
        #expect(try controller.store.load().tasks.isEmpty)
    }

    @Test func providerContextsSurviveTabChangesAndHideOutsideTasks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work",
                            worktreePath: "/repo/.worktrees/work", baseBranch: "main", jira: nil,
                            agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(), windowId: "w1")
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "w2",
                                    createdAt: Date())
        controller.state.projects = [project]
        controller.state.tasks = [task]
        controller.state.terminals = [terminal]
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

        controller.state.tasks = []
        controller.state.tasks = [task]
        #expect(controller.live.contextPercents(for: controller.focus.selection).isEmpty, "Removing a task evicts its cached context")
    }

    /// A terminal carries no task tag, so its tabs are matched on the window — the same way its
    /// sidebar row finds its avatars. Starting an agent in a plain terminal must light up `ctx`.
    @Test func terminalContextFollowsTheAgentStartedInIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "w2",
                                    createdAt: Date())
        let other = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal 2", windowId: "w3",
                                 createdAt: Date())
        controller.state.projects = [project]
        controller.state.terminals = [terminal, other]
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

        controller.state.terminals = [other]
        controller.state.terminals = [terminal, other]
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
        try controller.loadWorkspace()
        let project = Project(id: UUID(), name: "Repo", path: repo.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.state.projects = [project]
        #expect(controller.persist())
        if failSave { try FileManager.default.createDirectory(at: controller.store.backupURL, withIntermediateDirectories: false) }
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle("Create once")
        try await controller.createTask(draft: draft, project: project)
        let created = try #require(controller.state.tasks.first)
        #expect(controller.state.tasks.count == 1)
        #expect(created.windowId == nil)
        #expect(FileManager.default.fileExists(atPath: created.worktreePath))
        if failSave {
            #expect(controller.persistenceError != nil)
            try FileManager.default.removeItem(at: controller.store.backupURL)
            #expect(controller.persist())
        } else { #expect(controller.issue?.title.contains("Task created") == true) }
        let saved = try controller.store.load().tasks
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
        try controller.loadWorkspace()
        let project = Project(id: UUID(), name: "Repo", path: repo.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.state.projects = [project]
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle("Through the runner")
        draft.promptText = String(repeating: "long ", count: 400)
        try await controller.createTask(draft: draft, project: project)
        let asked = recording.calls.map(\.args)
        #expect(asked.contains { $0.starts(with: ["worktree", "add"]) })
        #expect(asked.filter { $0.contains("info/exclude") }.count == 2, "`.worktrees/` and the first-prompt exclusion are asked of the same runner")
    }

    /// The alert-level courtesy. The guarantee is `TaskWorkflow.remove`'s own refusal, tested in
    /// Task 6; this only proves the checkbox is never offered for a review.
    @Test @MainActor func testReviewRemovalNeverOffersToDeleteTheBranch() {
        let review = TaskItem(id: UUID(), projectId: UUID(), title: "Review gift card", branch: "feat-gift",
                              worktreePath: "/tmp/wt", baseBranch: "main", jira: nil, kind: .review, mr: nil,
                              agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: false,
                              createdAt: Date(), windowId: nil)
        let task = TaskItem(id: UUID(), projectId: UUID(), title: "Add gift card", branch: "feat/gift",
                            worktreePath: "/tmp/wt2", baseBranch: "main", jira: nil,
                            agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(), windowId: nil)
        #expect(AppController.offersBranchDeletion(for: review) == false)
        #expect(AppController.offersBranchDeletion(for: task) == true)
    }

    /// Removing a project deliberately leaves its worktrees on disk, so re-adding it re-imports
    /// them — and before this test the import built every one of them as a `.task`. A review that
    /// came back as a task gets an "Also delete branch" checkbox over a merge request's branch,
    /// which is the one thing the app must never offer. The marker is the lock reason
    /// `Worktrees.checkout` writes; `Worktrees.existing` now carries it through.
    @Test func importingWorktreesKeepsAReviewAReview() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let prompter = ScriptedPrompter(answering: "Import")
        let controller = AppController(store: store, preferences: .scratch(), prompter: prompter)
        try controller.loadWorkspace()

        let repo = try Self.repoWithATaskAndAReviewWorktree(git: controller.git)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: repo).deletingLastPathComponent()) }

        await controller.addProject(path: repo)
        #expect(prompter.asked.map(\.message) == ["Import 2 worktrees?"])

        #expect(controller.state.projects.count == 1)
        let imported = Dictionary(uniqueKeysWithValues: controller.state.tasks.map { ($0.branch, $0.kind) })
        #expect(imported.count == 2, "both worktrees import: \(controller.state.tasks.map(\.branch))")
        #expect(imported["feat/mr-branch"] == .review, "the review's lock reason survives the round trip")
        #expect(imported["feat/a-task"] == TaskKind?.none, "a task stays a task")
        #expect(controller.state.tasks.filter { $0.kind == .review }.allSatisfy { !AppController.offersBranchDeletion(for: $0) })
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
        try controller.loadWorkspace()
        let repo = try Self.repoWithATaskAndAReviewWorktree(git: controller.git)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: repo).deletingLastPathComponent()) }

        await controller.addProject(path: repo)
        #expect(controller.state.projects.count == 1, "the project itself is added")
        #expect(prompter.asked.isEmpty)
        #expect(controller.state.tasks.isEmpty, "no task is saved with a guessed base branch")
    }

    /// A repository holding one worktree of each kind, made by the same calls the app makes: a
    /// task's through `Worktrees.create` and a review's through `Worktrees.checkout`.
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
        _ = try Worktrees.create(repo: repo, slug: "a-task", branch: "feat/a-task", base: "main", git: git)
        _ = try Worktrees.checkout(repo: repo, slug: "review-mr-branch", branch: "feat/mr-branch", git: git)
        return repo
    }

    private func loadedController() throws -> (AppController, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
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
        controller.state.append(project: project)
        controller.state.tasks.append(TaskItem(id: UUID(), projectId: project.id, title: "a", branch: "feat/a",
                                               worktreePath: checkout.path, baseBranch: "main", jira: nil, agent: .claude,
                                               model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: true,
                                               createdAt: Date(), windowId: nil))
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
        controller.state.append(project: project)
        controller.state.tasks = [task]
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
        try controller.loadWorkspace()
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
        try controller.loadWorkspace()

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
        try controller.loadWorkspace()
        let project = fixtureProject("repo")
        let task = TaskItem(id: UUID(), projectId: project.id, title: "a", branch: "feat/a", worktreePath: "/repo/a",
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                            appendTicket: true, createdAt: Date(), windowId: "w")
        controller.state.append(project: project)
        controller.state.tasks = [task]
        var tab = SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: task.id.uuidString, projectId: nil,
                              agent: .claude, model: nil, state: .needsInput, title: "", cwd: "/repo/a")
        controller.live.sessions = [tab]
        #expect(written == ["1"])

        tab.contextPercent = 30
        controller.live.sessions = [tab]
        controller.state.append(divider: SidebarDivider(id: UUID(), name: ""))
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
        try controller.loadWorkspace()
        let project = fixtureProject("repo")
        let task = TaskItem(id: UUID(), projectId: project.id, title: "a", branch: "feat/a", worktreePath: "/repo/a",
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                            appendTicket: true, createdAt: Date(), windowId: "w")
        let shell = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "t", createdAt: Date())
        controller.state.append(project: project)
        controller.state.tasks = [task]; controller.state.terminals = [shell]
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
        controller.state.append(project: fixtureProject("repo"))
        controller.addDivider(name: "  Work  ")
        #expect(controller.state.items.last?.divider?.name == "Work")
        #expect(controller.persistenceError == nil)
        #expect(try controller.store.load().items.count == 2)
    }

    @Test func renamingADividerTrimsAndRenamingATaskChangesOnlyTheTitle() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = fixtureProject("repo")
        controller.state.append(project: project)
        let rule = SidebarDivider(id: UUID(), name: "Work")
        controller.state.append(divider: rule)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Old", branch: "feat/x", worktreePath: "/wt",
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil,
                            firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w1")
        controller.state.tasks = [task]

        controller.rename(divider: rule, to: "  Personal ")
        #expect(controller.state.items.last?.divider?.name == "Personal")

        controller.rename(task: task, to: "  New title ")
        #expect(controller.state.tasks[0].title == "New title")
        #expect(controller.state.tasks[0].branch == "feat/x")
        #expect(controller.state.tasks[0].worktreePath == "/wt")
        #expect(controller.state.tasks[0].windowId == "w1")

        // An emptied field leaves a task's title alone; a divider may legitimately have no name.
        controller.rename(task: task, to: "   ")
        #expect(controller.state.tasks[0].title == "New title")
        controller.rename(divider: rule, to: "   ")
        #expect(controller.state.items.last?.divider?.name == "")
    }

    @Test func deletingADividerLeavesEveryProjectAndTaskInPlace() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = fixtureProject("repo")
        controller.state.append(project: project)
        let rule = SidebarDivider(id: UUID(), name: "Work")
        controller.state.append(divider: rule)
        controller.state.terminals = [TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "w1", createdAt: Date())]
        controller.removeDivider(rule)
        #expect(controller.state.items.map(\.id) == [project.id])
        #expect(controller.state.terminals.count == 1)
    }

    @Test func movingAProjectPastADividerChangesItsGroupWithoutReorderingProjects() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = (fixtureProject("a"), fixtureProject("b"))
        let rule = SidebarDivider(id: UUID(), name: "Work")
        controller.state.append(project: a)
        controller.state.append(divider: rule)
        controller.state.append(project: b)

        let moved = controller.move(itemId: b.id, .up)
        #expect(moved)
        #expect(controller.state.items.map(\.id) == [a.id, b.id, rule.id])
        #expect(controller.state.projects.map(\.name) == ["a", "b"])
        #expect(!controller.canMove(itemId: a.id, .up))
        #expect(!controller.canMove(itemId: rule.id, .down))
        #expect(controller.canMove(itemId: rule.id, .up))
    }

    @Test func dividerActionsAreRefusedWhileTheWorkspaceIsLocked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try Data("{broken".utf8).write(to: url)
        let controller = AppController(store: StateStore(url: url), preferences: .scratch())
        #expect(throws: (any Error).self) { try controller.loadWorkspace() }
        controller.addDivider(name: "Work")
        #expect(controller.state.items.isEmpty)
        #expect(!controller.canMove(itemId: UUID(), .up))
        controller.presentNewDivider()
        #expect(controller.sheet == nil)
    }

    @Test func theRenameAndNewDividerSheetsCarryTheirTarget() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = fixtureProject("repo")
        controller.state.append(project: project)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Old", branch: "feat/x", worktreePath: "/wt",
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil,
                            firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: nil)
        controller.state.tasks = [task]

        controller.presentNewDivider()
        #expect(controller.sheet?.id == "divider-new")

        controller.presentRename(task: task)
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
        controller.state.append(project: project)
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "w1", createdAt: Date())
        controller.state.terminals = [terminal]

        controller.presentRename(terminal: terminal)
        guard case .rename(let target)? = controller.sheet else { Issue.record("expected a rename sheet"); return }
        #expect(target == .terminal(terminal))
        #expect(target.title == "Rename terminal")
        #expect(target.fieldLabel == "Terminal name")
        #expect(target.name == "Terminal")

        controller.rename(terminal: terminal, to: "  Dev server ")
        #expect(controller.state.terminals == [TerminalItem(id: terminal.id, projectId: project.id, name: "Dev server",
                                                            windowId: "w1", createdAt: terminal.createdAt)])
        #expect(try controller.store.load().terminals.map(\.name) == ["Dev server"])

        // An emptied field keeps the name, as a task's does.
        controller.rename(terminal: terminal, to: "   ")
        #expect(controller.state.terminals.map(\.name) == ["Dev server"])
    }
}

extension AppControllerTests {
    /// The footer's "not installed" is read from the harness home the controller was given — in a
    /// test a temporary one — not from the developer's own `~/.claude`. Both answers are checked, so
    /// reading the real home fails whichever state it is in.
    @Test func theStatusLineProbeReadsTheHarnessHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), resources = root.appendingPathComponent("resources")
        let shim = resources.appendingPathComponent("hooks/claude-statusline-shim.sh")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: home, bundledResourcesURL: resources)

        controller.agents.refreshStatusLineState()
        #expect(!controller.agents.claudeStatusLineInstalled, "this home has no Claude settings at all")

        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"\#(shim.path)"}}"#.utf8).write(to: settings)
        controller.agents.refreshStatusLineState()
        #expect(controller.agents.claudeStatusLineInstalled)
    }

    /// A sheet's models and prompt completions come from the harness home the controller was
    /// given, not the developer's own `~/.claude`: in a test that is a temporary directory.
    @Test func aCreationSheetReadsTheHarnessHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let skill = home.appendingPathComponent(".claude/skills/only-in-this-home")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: only-in-this-home\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try Data(#"{"availableModels":["model-only-in-this-home"]}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: home, bundledResourcesURL: nil)
        let project = Project(id: UUID(), name: "Repo", path: root.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let model = controller.makeCreationModel(
            project: project, draft: TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil), jira: nil)

        await model.loadAgentCatalogue()
        #expect(model.models.contains { $0.id == "model-only-in-this-home" })
        #expect(model.completions.all.contains { $0.name == "only-in-this-home" })
    }

    /// Settings opens on the saved connections, read off the main actor: two Keychain items, and
    /// a Keychain that asks for access would hold the whole app on it.
    @Test func settingsReadsTheSavedConnectionsOffTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jira = JiraConfig(siteURL: URL(string: "https://example.atlassian.net")!, email: "a@b", token: "t")
        let onMain = Mutex<[Bool]>([])
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: root, bundledResourcesURL: nil,
                                       jiraSettings: { onMain.withLock { $0.append(Thread.isMainThread) }; return jira },
                                       gitLabSettings: { onMain.withLock { $0.append(Thread.isMainThread) }; return nil },
                                       gitHubSettings: { nil })
        controller.presentSettings()
        await eventually { controller.sheet != nil }
        guard case .settings(let saved, let gitLab, _)? = controller.sheet else { Issue.record("expected the Settings sheet"); return }
        #expect(saved == jira && gitLab == nil)
        #expect(onMain.withLock { $0 } == [false, false])
    }

    /// ⌘, behind another sheet would replace it — and a New Task draft with it — so it does nothing.
    @Test func settingsDoesNotReplaceAnOpenSheet() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.presentNewDivider()
        #expect(!controller.canPresentSettings)

        controller.presentSettings()

        #expect(controller.sheet?.id == AppController.SheetKind.newDivider.id)
    }

    /// An upgrade from a build whose record of the user's status line the shim no longer reads is
    /// migrated at launch, in the harness home: nothing would prompt a repair that does it.
    @Test func theLaunchProbeMigratesAnOldStatusLineRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let support = home.appendingPathComponent("Library/Application Support/AiTerm")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(#"{"type":"command","command":"my-statusline"}"#.utf8).write(to: support.appendingPathComponent("statusline-original.json"))
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: home, bundledResourcesURL: nil)

        await controller.agents.probeStatusLine()
        let command = support.appendingPathComponent("statusline-original.cmd")
        #expect(try String(contentsOf: command, encoding: .utf8) == "my-statusline")
    }

    /// A test that builds a controller and never scripts its prompter must fail when the app asks a
    /// question, not open a modal `NSAlert` that blocks the run: the default answers nothing.
    @Test func aTestControllerFailsAnUnexpectedQuestionRatherThanAskingModally() {
        let controller = AppController(preferences: .scratch())
        let prompter = controller.prompter as? ScriptedPrompter
        #expect(prompter != nil, "the test initializer's prompter is scripted, not modal")

        var answer: AlertAnswer?
        withKnownIssue("the prompter was not told to expect a question") {
            answer = controller.prompter.ask(AlertPrompt(message: "Remove task?", buttons: ["Remove", "Cancel"], escape: 1))
        }
        #expect(answer?.button == 1, "it answers with the button ⎋ gives")
        #expect(prompter?.asked.map(\.message) == ["Remove task?"])
    }
}

/// Counts the passes a controller's scanner is asked for, from the background thread each runs on.
private final class ScanCounter: Sendable {
    private let passes = Mutex(0)
    var count: Int { passes.withLock { $0 } }
    func increment() { passes.withLock { $0 += 1 } }
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
