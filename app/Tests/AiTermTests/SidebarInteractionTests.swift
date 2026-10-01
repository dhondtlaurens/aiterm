import AppKit
import SwiftUI
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct SidebarInteractionTests {
    @Test func inactiveWindowClicksSelectTerminalFirstThenTaskRowsOnTheFirstClick() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let tasks = ["First task", "Second task"].map { title in
            TaskItem(id: UUID(), projectId: project.id, title: title, branch: "feat/work", worktreePath: "/wt",
                     baseBranch: "main", jira: nil, agent: .claude, model: "sonnet", reasoning: nil,
                     firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "window-" + title)
        }
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "terminal-window", createdAt: Date())
        controller.state.projects = [project]; controller.state.tasks = tasks; controller.state.terminals = [terminal]
        controller.focus.browse(.task(tasks[0].id))

        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        let sidebar = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        sidebar.isReleasedWhenClosed = false; sidebar.contentView = host; sidebar.orderFront(nil)
        let other = NSWindow(contentRect: NSRect(x: 500, y: 0, width: 200, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.makeKeyAndOrderFront(nil)
        defer { sidebar.orderOut(nil); other.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        #expect(!sidebar.isKeyWindow)

        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        #expect(list.numberOfRows == 5)
        func click(row: Int, eventNumber: Int) throws {
            let point = list.convert(NSPoint(x: list.bounds.midX, y: list.rect(ofRow: row).midY), to: nil)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                      timestamp: 0, windowNumber: sidebar.windowNumber,
                                                      context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                                    timestamp: 0, windowNumber: sidebar.windowNumber,
                                                    context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 0))
            sidebar.sendEvent(down); sidebar.sendEvent(up)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        // Header, project, terminal, first task, second task — the same type order as the create menu.
        try click(row: 2, eventNumber: 1)
        #expect(controller.focus.selectedTerminalId == terminal.id)

        other.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(!sidebar.isKeyWindow)
        try click(row: 4, eventNumber: 2)
        #expect(controller.focus.selectedTaskId == tasks[1].id)
    }

    /// ↓ peeks: the next row's window is shown, and the task is not marked seen.
    @Test func nativeListArrowKeysPeekAtTheNextRowsWindow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let tasks = ["First task", "Second task"].map { title in
            TaskItem(id: UUID(), projectId: project.id, title: title, branch: "feat/work", worktreePath: "/wt",
                     baseBranch: "main", jira: nil, agent: .claude, model: "sonnet", reasoning: nil,
                     firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "window-" + title)
        }
        controller.state.projects = [project]; controller.state.tasks = tasks
        controller.focus.browse(.task(tasks[0].id))
        let server = RecordingDaemon()
        controller.helper.setDaemonClient(server)
        defer { controller.shutdown() }
        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        turnRunLoop(0.05)
        host.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        #expect(list.selectionHighlightStyle == .none)
        #expect(window.makeFirstResponder(list))
        let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                                 isARepeat: false, keyCode: 125))
        list.keyDown(with: arrow)
        turnRunLoop(0.05)
        #expect(controller.focus.selectedTaskId == tasks[1].id)
        #expect(controller.focus.selectedTerminalId == nil)
        #expect(controller.state.tasks == tasks, "peeking writes nothing to the workspace")
        // The peek is a main-actor task: it runs once the test suspends.
        try await server.received("window.activate")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["window-Second task"])
        #expect(server.requests("sessions.markSeen").isEmpty)
    }

    /// ⌘⌫ reaches the list's handler rather than dying in the table: the selected task's Remove
    /// question comes up, and a plain ⌫ asks nothing.
    @Test func commandDeleteRemovesTheSelectedRow() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Cancel"))
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: "alive")
        controller.focus.browse(.task(task.id))
        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        turnRunLoop(0.05)
        host.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        #expect(window.makeFirstResponder(list))
        func backspace(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                          timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                                          isARepeat: false, keyCode: 51))
        }

        window.sendEvent(try backspace([]))
        turnRunLoop(0.05)
        #expect(fixture.prompter.asked.isEmpty, "a plain ⌫ removes nothing")

        window.sendEvent(try backspace(.command))
        #expect(fixture.prompter.asked.isEmpty, "the alert waits for the key event to finish")
        try await fixture.until { !fixture.prompter.asked.isEmpty }
        #expect(fixture.prompter.asked.map(\.message) == ["Remove task “\(task.title)”?"])
        #expect(fixture.prompter.asked.first?.checkbox == "Also delete branch \(task.branch)")
    }

    @Test func arrowKeysCrossIntoTheNextOpenProjectAndBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        func project(_ name: String) -> Project {
            Project(id: UUID(), name: name, path: "/" + name, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        }
        let (a, b) = (project("a"), project("b"))
        func task(_ title: String, in project: Project) -> TaskItem {
            TaskItem(id: UUID(), projectId: project.id, title: title, branch: "feat/work", worktreePath: "/wt",
                     baseBranch: "main", jira: nil, agent: .claude, model: "sonnet", reasoning: nil,
                     firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "window-" + title)
        }
        let tasks = [task("a1", in: a), task("a2", in: a), task("b1", in: b), task("b2", in: b)]
        let terminal = TerminalItem(id: UUID(), projectId: b.id, name: "Terminal", windowId: "terminal-window", createdAt: Date())
        controller.state.append(project: a)
        controller.state.append(divider: SidebarDivider(id: UUID(), name: "Work"))
        controller.state.append(project: b)
        controller.state.tasks = tasks; controller.state.terminals = [terminal]
        controller.focus.browse(.task(tasks[1].id))

        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        #expect(window.makeFirstResponder(list))
        func press(_ keyCode: UInt16, _ character: String) throws {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: character, charactersIgnoringModifiers: character,
                                                   isARepeat: false, keyCode: keyCode))
            window.sendEvent(key)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        // A divider and project b's header sit between a2 and b's terminal: the arrow steps over the
        // divider and stops on the header, as a Finder outline stops on a folder.
        try press(125, "\u{F701}")
        #expect(controller.focus.selection == .project(b.id))
        try press(125, "\u{F701}")
        #expect(controller.focus.selectedTerminalId == terminal.id)
        try press(126, "\u{F700}")
        #expect(controller.focus.selection == .project(b.id))
        try press(126, "\u{F700}")
        #expect(controller.focus.selectedTaskId == tasks[1].id)
        #expect(controller.helper.daemon == nil)
    }

    /// ↩ on a header folds and opens it; ⌘↩ and ← → do nothing. A header shows no window and raises
    /// nothing, and ⌘⌫ on one removes nothing.
    @Test func returnFoldsAndOpensAHeader() throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Cancel"))
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller, project = fixture.project
        let task = try fixture.addTask(windowId: "work")
        let server = RecordingDaemon()
        controller.helper.setDaemonClient(server)
        #expect(task.projectId == project.id)
        controller.focus.browse(.project(project.id))

        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        #expect(window.makeFirstResponder(list))
        func press(_ keyCode: UInt16, _ character: String, _ flags: NSEvent.ModifierFlags = []) throws {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                   timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: character, charactersIgnoringModifiers: character,
                                                   isARepeat: false, keyCode: keyCode))
            window.sendEvent(key)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        func collapsed() -> Bool? { controller.state.project(id: project.id)?.collapsed }

        try press(123, "\u{F702}")
        #expect(collapsed() == false, "← folds nothing")
        try press(36, "\r", .command)
        #expect(collapsed() == false, "⌘↩ folds nothing")
        try press(36, "\r")
        #expect(collapsed() == true, "↩ folds an open header")
        try press(124, "\u{F703}")
        #expect(collapsed() == true, "→ opens nothing")
        try press(36, "\r")
        #expect(collapsed() == false, "↩ opens a folded one")
        #expect(controller.focus.selection == .project(project.id))
        #expect(server.requests.filter { $0.method.hasPrefix("window.") }.isEmpty, "a header raises nothing")

        try press(51, "\u{7F}", .command)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(fixture.prompter.asked.isEmpty, "⌘⌫ removes nothing from a header")
        #expect(controller.state.projects.map(\.id) == [project.id])
    }

    /// ↩ on an empty header, which has nothing to fold, opens its context menu instead.
    @Test func returnOnAnEmptyHeaderOpensItsMenu() throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Cancel"))
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller, project = fixture.project
        controller.focus.browse(.project(project.id))
        var asked: [UUID] = []
        controller.openRowMenu = { asked.append($0) }

        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        #expect(window.makeFirstResponder(list))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: "\r", charactersIgnoringModifiers: "\r",
                                                isARepeat: false, keyCode: 36))
        window.sendEvent(key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(asked == [project.id], "↩ asks for the header's menu")
        #expect(controller.state.project(id: project.id)?.collapsed == false)

        // The menu the anchor's right-click brings up, asked of the view it lands on rather than
        // tracked: a real menu's modal tracking ends a test host's run. The ↓ that highlights its
        // first item needs that tracking, so it is checked in the app.
        let click = try #require(RowMenuAnchor.anchor(for: project.id)?.rightClick)
        let hit = try #require(host.hitTest(host.convert(click.locationInWindow, from: nil)))
        let menu = try #require(sequence(first: hit, next: \.superview).lazy.compactMap { $0.menu(for: click) }.first,
                                "the click lands on a row with a menu")
        #expect(Array(menu.items.prefix(3).map(\.title)) == ["New Task…", "New Review…", "New Terminal…"],
                "the header's own menu")
    }

    @Test func finalBranchRefreshUsesTheLatestInputs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first"), second = dir.appendingPathComponent("second")
        for (url, branch) in [(first, "first"), (second, "second")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try GitRunner().run(["init", "-q", "-b", branch], in: url.path)
        }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        let old = Project(id: UUID(), name: "Old", path: first.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let new = Project(id: UUID(), name: "New", path: second.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.state.projects = [old]
        controller.checkouts.refresh()
        controller.state.projects = [new]
        await controller.checkouts.refresh().value
        #expect(controller.checkouts.projectBranch == [new.id: "second"])
    }

    @Test func aDividerIsDrawnAsItsOwnRowBetweenTheProjectsItSeparates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        func project(_ name: String) -> Project {
            Project(id: UUID(), name: name, path: "/" + name, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: true)
        }
        let (a, b) = (project("a"), project("b"))
        controller.state.append(project: a)
        controller.state.append(divider: SidebarDivider(id: UUID(), name: "Work"))
        controller.state.append(project: b)

        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        // Header, project a, the divider, project b. Both projects are collapsed, so nothing else.
        #expect(list.numberOfRows == 4)
    }

    /// With no project, a block under PROJECTS says what to add and offers the header's own action;
    /// it goes with the first project, and a divider alone does not count as one.
    @Test func anEmptySidebarOffersToAddAProject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        controller.state.append(divider: SidebarDivider(id: UUID(), name: "Work"))

        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        // Header, the block, the divider.
        #expect(list.numberOfRows == 3)

        controller.state.append(project: Project(id: UUID(), name: "a", path: "/a", provider: .git, remoteUrl: nil,
                                                 addedAt: Date(), collapsed: true))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        // Header, the divider, project a.
        #expect(list.numberOfRows == 3)
        #expect(controller.state.projects.count == 1)
    }

    /// The block's button is the header's "Add Project…": it asks for a folder.
    @Test func theEmptySidebarsButtonAsksForAFolder() throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let block = SidebarEmptyState(controller: fixture.controller)
        #expect(block.canAdd)
        block.add()
        #expect(fixture.prompter.folderPrompts == ["Add Project"])
    }

    /// Lays out and delivers events in an async test, where `RunLoop.run(until:)` cannot be called
    /// directly.
    private func turnRunLoop(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}
