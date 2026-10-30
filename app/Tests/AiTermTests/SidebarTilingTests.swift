import AppKit
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
struct SidebarTilingTests {
    private func sidebarWindow() -> NSWindow {
        let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.titled, .resizable])

        window.minSize = NSSize(width: 360, height: 400)
        return window
    }

    /// A drag reports every pixel; the frame is written to the workspace once, when it has settled.
    @Test func aMoveIsSavedOnceItSettles() async throws {
        let workspace = WorkspaceStore.holding(.empty)
        var changes = 0
        workspace.onChange { changes += 1 }
        let tiling = SidebarTiling(preferences: .scratch(), moveDelay: 0.02, workspace: workspace, daemon: { nil })
        let window = sidebarWindow()
        tiling.sidebarWindow = window
        window.setFrameOrigin(NSPoint(x: 40, y: 0))
        tiling.sidebarMoved()
        window.setFrameOrigin(NSPoint(x: 80, y: 0))
        tiling.sidebarMoved()
        #expect(changes == 0)

        try #require(await eventually { changes > 0 })
        // Absence: the first move's own, cancelled, delay would have fired by now.
        try await Task.sleep(for: .milliseconds(100))
        #expect(changes == 1)
        #expect(workspace.state.sidebarFrame == window.frame)
    }

    /// A sidebar that settles where it already was changes nothing, so nothing is saved.
    @Test func aMoveBackToTheSavedFrameChangesNothing() {
        let workspace = WorkspaceStore.holding(.empty)
        let tiling = SidebarTiling(preferences: .scratch(), workspace: workspace, daemon: { nil })
        let window = sidebarWindow()
        tiling.sidebarWindow = window
        tiling.sidebarMoved()
        tiling.finishPendingMove()
        var changes = 0
        workspace.onChange { changes += 1 }

        tiling.sidebarMoved()
        tiling.finishPendingMove()

        #expect(changes == 0)
    }

    /// AppKit slides the sidebar aside to fit a sheet wider than it, and back once the sheet ends. A
    /// window opened meanwhile — New Terminal's, as its sheet closes — goes beside the sidebar where
    /// it rests, not where the sheet pushed it.
    @Test func aWindowOpenedUnderASheetGoesBesideTheRestingSidebar() {
        let tiling = SidebarTiling(preferences: .scratch(), workspace: .holding(.empty), daemon: { nil })
        let window = sidebarWindow()
        tiling.sidebarWindow = window
        let resting = tiling.taskFrame()

        tiling.sheetWillBegin()
        window.setFrameOrigin(NSPoint(x: 100, y: 0))
        #expect(tiling.taskFrame() == resting)

        window.setFrameOrigin(.zero)
        tiling.sheetDidEnd()
        window.setFrameOrigin(NSPoint(x: 40, y: 0))
        #expect(tiling.taskFrame() != resting, "with the sheet gone, the sidebar's own frame counts again")
    }

    /// The sheet's slide is not a move of the sidebar's: nothing is saved or re-tiled for it. Its end
    /// settles the sidebar, once, where it then is.
    @Test func aSheetsSlideIsNotSavedAndItsEndSettles() {
        let workspace = WorkspaceStore.holding(.empty)
        var changes = 0
        workspace.onChange { changes += 1 }
        let tiling = SidebarTiling(preferences: .scratch(), workspace: workspace, daemon: { nil })
        let window = sidebarWindow()
        tiling.sidebarWindow = window

        tiling.sheetWillBegin()
        window.setFrameOrigin(NSPoint(x: 100, y: 0))
        tiling.sidebarMoved()
        tiling.finishPendingMove()
        #expect(changes == 0)

        window.setFrameOrigin(NSPoint(x: 20, y: 0))
        tiling.sheetDidEnd()
        tiling.finishPendingMove()
        #expect(changes == 1)
        #expect(workspace.state.sidebarFrame == window.frame)
    }

    /// Settings' Save zooms under its sheet: the sidebar is saved and tiled to where it rests, at its
    /// new width.
    @Test func aZoomUnderASheetKeepsTheRestingOrigin() {
        let workspace = WorkspaceStore.holding(.empty)
        let tiling = SidebarTiling(preferences: .scratch(), workspace: workspace, daemon: { nil })
        let window = sidebarWindow()
        tiling.sidebarWindow = window

        tiling.sheetWillBegin()
        window.setFrameOrigin(NSPoint(x: 100, y: 0))
        tiling.setInterfaceSize(.large)

        let saved = workspace.state.sidebarFrame
        #expect(saved?.origin == .zero)
        #expect(saved?.width == window.frame.width)
        #expect(tiling.taskFrame().x == Double(window.frame.width) + 12)
    }

    /// Quitting mid-debounce still saves where the sidebar ended up, into the workspace.
    @Test func quittingSavesAMoveStillSettling() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        let window = sidebarWindow()
        controller.tiling.sidebarWindow = window
        controller.tiling.finishPendingMove()
        #expect(controller.state.sidebarFrame == nil, "nothing was waiting")

        window.setFrameOrigin(NSPoint(x: 120, y: 0))
        controller.tiling.sidebarMoved()
        controller.tiling.finishPendingMove()
        #expect(controller.state.sidebarFrame == window.frame)
        // As `applicationShouldTerminate` does next: the change is saved now, not a moment later.
        #expect(controller.workspace.flush())
        #expect(try StateStore(url: dir.appendingPathComponent("state.json")).load().sidebarFrame == window.frame)
    }

    /// A workspace with a task window, a terminal window and a task whose window is closed,
    /// connected to a daemon that records what it is asked and holds back the replies to `holding`.
    private func tiledWorkspace(holding: String? = nil) async throws -> (RaceFixture, RecordingDaemon, NSWindow, TaskItem, TerminalItem) {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: holding)
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: "task-window")
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Terminal", windowId: "terminal-window",
                                    createdAt: Date())
        let closed = TaskItem(id: UUID(), projectId: fixture.project.id, title: "Closed", branch: "main",
                              worktreePath: fixture.repo.path, baseBranch: "main", jira: nil, agent: .codex,
                              model: "model", reasoning: nil, firstPrompt: nil, appendTicket: false,
                              createdAt: Date(), windowId: nil)
        controller.workspace.mutate { state in
            state.terminals = [terminal]
            state.tasks.append(closed)
        }
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

    @Test func aZoomAlsoSnapsOpenOperatorWindows() async throws {
        let (fixture, server, _, _, _) = try await tiledWorkspace()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        var open = OperatorServiceFixtures.run(projects: [fixture.project])
        open.operatorWindowId = "operator-window"
        let closed = OperatorServiceFixtures.run(projects: [fixture.project])
        fixture.controller.workspace.mutate { $0.runs = [open, closed] }

        await fixture.controller.tiling.setInterfaceSize(.large)?.value

        let snapped = server.requests("window.setFrame").compactMap { $0.params["windowId"] as? String }
        #expect(snapped.sorted() == ["operator-window", "task-window", "terminal-window"])
    }

    /// A re-tiling for a newer frame cancels one still under way, so the windows that one had
    /// not reached yet are framed once, for the newer frame, rather than by whichever reply is last.
    @Test func aNewerReTilingCancelsTheOneUnderWay() async throws {
        let (fixture, server, window, _, _) = try await tiledWorkspace(holding: "window.setFrame")
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let tiling = fixture.controller.tiling
        let zoom = try #require(tiling.setInterfaceSize(.large))
        let zoomed = tiling.taskFrame()
        try await server.received("window.setFrame")

        window.setFrameOrigin(NSPoint(x: 200, y: 0))
        tiling.sidebarMoved()
        tiling.finishPendingMove()
        let moved = tiling.taskFrame()
        server.release()
        await zoom.value
        try await server.received("window.setFrame", count: 3)

        let xs = server.requests("window.setFrame").compactMap { ($0.params["frame"] as? [String: Any])?["x"] as? Double }
        #expect(xs.count { $0 == Double(zoomed.x) } == 1, "the zoom stopped after its first window, got \(xs)")
        #expect(xs.count { $0 == Double(moved.x) } == 2)
    }
}
