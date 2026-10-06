import AppKit
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
struct SidebarTilingTests {
    private func sidebarWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 400)
        return window
    }

    /// A drag reports every pixel; the frame is saved once, when it has settled.
    @Test func aMoveIsSavedOnceItSettles() async throws {
        var saved: [CGRect] = []
        let tiling = SidebarTiling(preferences: .scratch(), moveDelay: 0.02, tiledWindows: { [] }, daemon: { nil },
                                   saveSidebarFrame: { saved.append($0) })
        let window = sidebarWindow()
        tiling.sidebarWindow = window
        window.setFrameOrigin(NSPoint(x: 40, y: 0))
        tiling.sidebarMoved()
        window.setFrameOrigin(NSPoint(x: 80, y: 0))
        tiling.sidebarMoved()
        #expect(saved.isEmpty)

        try #require(await eventually { !saved.isEmpty })
        // Absence: the first move's own, cancelled, delay would have fired by now.
        try await Task.sleep(for: .milliseconds(100))
        #expect(saved == [window.frame])
    }

    /// Quitting mid-debounce still saves where the sidebar ended up, into the workspace.
    @Test func quittingSavesAMoveStillSettling() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        let window = sidebarWindow()
        controller.tiling.sidebarWindow = window
        controller.tiling.finishPendingMove()
        #expect(controller.state.sidebarFrame == nil, "nothing was waiting")

        window.setFrameOrigin(NSPoint(x: 120, y: 0))
        controller.tiling.sidebarMoved()
        controller.tiling.finishPendingMove()
        #expect(controller.state.sidebarFrame == window.frame)
        #expect(try StateStore(url: dir.appendingPathComponent("state.json")).load().sidebarFrame == window.frame)
    }

    /// A workspace with a task window, a terminal window and a task whose window is closed,
    /// connected to a daemon that records what it is asked.
    private func tiledWorkspace() async throws -> (RaceFixture, RecordingDaemon, NSWindow, TaskItem, TerminalItem) {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: "task-window")
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Terminal", windowId: "terminal-window",
                                    createdAt: Date())
        controller.state.terminals = [terminal]
        controller.state.tasks.append(TaskItem(id: UUID(), projectId: fixture.project.id, title: "Closed", branch: "main",
                                               worktreePath: fixture.repo.path, baseBranch: "main", jira: nil, agent: .codex,
                                               model: "model", reasoning: nil, firstPrompt: nil, appendTicket: false,
                                               createdAt: Date(), windowId: nil))
        controller.helper.setDaemonClient(server)
        await controller.checkouts.refreshTask?.value
        let window = sidebarWindow()
        controller.tiling.sidebarWindow = window
        return (fixture, server, window, task, terminal)
    }

    /// Once a drag settles, the task's window is put back beside the sidebar where it now is.
    @Test func aSettledDragReTilesTheTaskWindows() async throws {
        let (fixture, server, window, task, _) = try await tiledWorkspace()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        window.setFrameOrigin(NSPoint(x: 200, y: 0))
        fixture.controller.tiling.sidebarMoved()
        fixture.controller.tiling.finishPendingMove()
        try await server.received("window.setFrame", count: 2)

        let request = try #require(server.requests("window.setFrame").first { $0.params["windowId"] as? String == task.windowId })
        let frame = try #require(request.params["frame"] as? [String: Any])
        #expect(frame["x"] as? Double == Double(fixture.controller.tiling.taskFrame().x))
    }

    /// A zoom re-tiles exactly the windows the workspace has open: every task's and terminal's.
    @Test func aZoomSnapsEveryTaskAndTerminalWindow() async throws {
        let (fixture, server, _, _, _) = try await tiledWorkspace()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        await fixture.controller.tiling.setInterfaceSize(.large)?.value

        let snapped = server.requests("window.setFrame").compactMap { $0.params["windowId"] as? String }
        #expect(snapped.sorted() == ["task-window", "terminal-window"])
    }
}
