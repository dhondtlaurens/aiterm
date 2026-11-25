import AppKit
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// File › New Task, New Review and New Terminal act on the target project — the selected header's,
/// or the selected row's — and every File item is off behind a sheet or over a locked workspace.
@MainActor
@Suite(.serialized) struct FileMenuTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let git = Project.make(name: "repo", path: "/repo", addedAt: Date())
    private let folder = Project.make(name: "notes", path: "/notes", provider: .none, addedAt: Date())

    private func controller() throws -> AppController {
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        controller.workspace.mutate { $0.items = [.project(git), .project(folder)] }
        return controller
    }

    /// What the File menu's items say about themselves, by title.
    private func enabled(_ controller: AppController) throws -> [String: Bool] {
        let saved = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = saved }
        let app = AiTermApp(controller: controller)
        app.buildMenu()
        let file = try #require(NSApplication.shared.mainMenu?.items.compactMap(\.submenu).first { $0.title == "File" })
        return Dictionary(uniqueKeysWithValues: file.items.filter { !$0.isSeparatorItem }.map { ($0.title, app.validateMenuItem($0)) })
    }

    @Test func withNothingSelectedProjectDividerAndSignalAreOn() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        #expect(controller.targetProject == nil)
        #expect(try enabled(controller) == ["New Task…": false, "New Review…": false, "New Terminal…": false,
                                            "Add Project…": true, "Add Divider…": true, "New Signal…": true])
    }

    /// A task the Operator runs in `git`, which opens its section.
    private func held(by signal: Signal) -> TaskItem {
        var task = TaskItem.make(project: git.id, worktreePath: "/repo/held")
        task.signalTask = SignalTask.make(signal: signal, item: .ticket(site: "https://jira.example", key: "PAY-1"))
        return task
    }

    /// ⌘D always adds between projects: with the Operator's section open, and its last signal gone, it is still on and
    /// asks for a projects' divider.
    @Test func addDividerAlwaysAddsBetweenProjects() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        var world = SignalWorld(); let signal = world.signal()
        let task = held(by: world.state.signals[0])
        controller.workspace.mutate { $0.signals = world.state.signals; $0.tasks = [task]; $0.operatorOpen = true }
        controller.workspace.mutate { $0.removeSignal(id: signal) }
        #expect(controller.rows.operatorOpen)
        #expect(try enabled(controller)["Add Divider…"] == true)
        AiTermApp(controller: controller).addDivider()
        #expect(controller.sheet?.id == AppController.SheetKind.newDivider.id)
    }

    @Test func commandSOpensNewSignalWithoutASelectedProject() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        let saved = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = saved }
        let app = AiTermApp(controller: controller)
        app.buildMenu()
        let menu = try #require(NSApplication.shared.mainMenu)
        let item = try #require(menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "New Signal…" })
        item.target = app
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        #expect(menu.performKeyEquivalent(with: event))
        #expect(await eventually(describing: "⌘S opens New Signal") { controller.sheet != nil })
        guard case .signal(let sheet)? = controller.sheet else { Issue.record("no New Signal sheet"); return }
        #expect(sheet.projects == [git, folder])
    }

    /// ⌘S makes the open section's kind (O4): a project signal with Projects open, the default; an Operator signal with
    /// the Operator's open.
    @Test func newSignalMakesTheOpenSectionsKind() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        let saved = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = saved }
        let app = AiTermApp(controller: controller)
        app.buildMenu()
        #expect(!controller.rows.operatorOpen)
        app.newSignal()
        #expect(await eventually(describing: "New Signal opens") { controller.sheet != nil })
        guard case .signal(let project)? = controller.sheet else { Issue.record("no New Signal sheet"); return }
        #expect(project.kind == .project && project.title == "New project signal")
        controller.sheet = nil
        var world = SignalWorld(); world.signal()
        let task = held(by: world.state.signals[0])
        controller.workspace.mutate { $0.signals = world.state.signals; $0.tasks = [task]; $0.operatorOpen = true }
        #expect(controller.rows.operatorOpen)
        app.newSignal()
        #expect(await eventually(describing: "New Signal opens") { controller.sheet != nil })
        guard case .signal(let operatorSignal)? = controller.sheet else { Issue.record("no New Signal sheet"); return }
        #expect(operatorSignal.kind == .operator && operatorSignal.title == "New Operator signal")
    }

    @Test func signalsCanBeAddedWhileAnotherSignalExists() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        var world = SignalWorld(); _ = world.signal()
        controller.workspace.mutate { $0.signals = world.state.signals }
        #expect(try enabled(controller)["New Signal…"] == true)
    }

    @Test func aSelectedRowTargetsItsProject() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        let work = TaskItem.make(project: git.id, worktreePath: "/wt", model: "sonnet", createdAt: Date())
        let shell = TerminalItem(id: UUID(), projectId: git.id, name: "Terminal", windowId: nil, createdAt: Date())
        controller.workspace.mutate { $0.tasks = [work] }; controller.workspace.mutate { $0.terminals = [shell] }

        controller.focus.browse(.task(work.id))
        #expect(controller.targetProject == git)
        controller.focus.browse(.terminal(shell.id))
        #expect(controller.targetProject == git)
        #expect(try enabled(controller).values.allSatisfy { $0 })
    }

    @Test func aSelectedHeaderIsTheTarget() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        controller.focus.browse(.project(folder.id))
        #expect(controller.targetProject == folder)
        controller.focus.browse(.project(git.id))
        #expect(controller.targetProject == git)
        #expect(try enabled(controller).values.allSatisfy { $0 })
    }

    /// A folder with no provider can hold a terminal but no task or review, as its "+" menu says.
    @Test func aProjectWithNoProviderTakesOnlyATerminal() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        let shell = TerminalItem(id: UUID(), projectId: folder.id, name: "Terminal", windowId: nil, createdAt: Date())
        controller.workspace.mutate { $0.terminals = [shell] }
        controller.focus.browse(.terminal(shell.id))
        let items = try enabled(controller)
        #expect(items["New Task…"] == false)
        #expect(items["New Review…"] == false)
        #expect(items["New Terminal…"] == true)
    }

    @Test func aSheetTurnsTheWholeMenuOff() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        let work = TaskItem.make(project: git.id, worktreePath: "/wt", model: "sonnet", createdAt: Date())
        controller.workspace.mutate { $0.tasks = [work] }
        controller.focus.browse(.task(work.id))
        controller.sheet = .newDivider
        #expect(try enabled(controller).values.allSatisfy { !$0 })
    }

    @Test func aWorkspaceThatHasNotLoadedTurnsTheWholeMenuOff() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        #expect(try enabled(controller).values.allSatisfy { !$0 })
    }
}
