import AppKit
import Testing
@testable import AiTermCore
@testable import AiTerm

/// File › New Task, New Review and New Terminal act on the target project — the selected header's,
/// or the selected row's — and every File item is off behind a sheet or over a locked workspace.
@MainActor
@Suite(.serialized) struct FileMenuTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let git = Project(id: UUID(), name: "repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
    private let folder = Project(id: UUID(), name: "notes", path: "/notes", provider: .none, remoteUrl: nil, addedAt: Date(), collapsed: false)

    private func controller() throws -> AppController {
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        controller.workspace.mutate { $0.items = [.project(git), .project(folder)] }
        return controller
    }

    private func task(in project: Project) -> TaskItem {
        TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work", worktreePath: "/wt",
                 baseBranch: "main", jira: nil, agent: .claude, model: "sonnet", reasoning: nil,
                 firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: nil)
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

    @Test func withNothingSelectedOnlyAddProjectAndAddDividerAreOn() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        #expect(controller.targetProject == nil)
        #expect(try enabled(controller) == ["New Task…": false, "New Review…": false, "New Terminal…": false,
                                            "Add Project…": true, "Add Divider…": true])
    }

    @Test func aSelectedRowTargetsItsProject() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = try controller()
        let work = task(in: git)
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
        let work = task(in: git)
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
