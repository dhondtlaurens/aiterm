import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A row without a window opens one only when it is chosen (a click or ↩). Choosing it again while
/// that open runs joins it and raises what it opens; a failed open is reported on the click, and the
/// next choose tries again; with iTerm2 away, iTerm2 is started and the row opens once it connects.
@MainActor @Suite(.blocking) struct OpeningRowControllerTests {
    /// A second click or ↩ while the window opens joins that same open: one window, raised once.
    @Test func choosingARowWhileItsOpenRunsRaisesWhatItOpensOnce() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.createTask")
        focus.server = server
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        fixture.controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        let first = fixture.controller.focus.select(.task(task.id))
        try await server.received("window.createTask")
        let second = fixture.controller.focus.select(.task(task.id))
        #expect(first != nil && second != nil, "each choice waits on the open under way")
        server.release()
        await first?.value
        await second?.value

        #expect(server.requests("window.createTask").count == 1)
        #expect(server.requests("window.activate").count == 1)
        #expect(focus.seen.count == 1)
    }

    /// Moved on while the window opens: it still opens, but neither it nor iTerm2 comes forward.
    @Test func anOpenTheSelectionLeftOpensTheWindowWithoutRaisingIt() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.createTask")
        focus.server = server
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        fixture.controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        let choice = fixture.controller.focus.select(.task(task.id))
        try await server.received("window.createTask")
        fixture.controller.focus.browse(nil)
        server.release()
        await choice?.value
        await fixture.controller.windows.open(.task(task.id))?.value

        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests("window.activate").isEmpty)
        #expect(focus.seen.isEmpty)
    }

    /// The task's tab lives on in another window: the row takes that window, and choosing it raises it.
    @Test func choosingATaskWhoseTabLivesOnElsewhereRaisesThatWindow() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        fixture.controller.workspace.mutate { $0.tasks[0].conversations = [TaskConversation(agent: .codex, id: "thread-1")] }
        fixture.controller.helper.handle(.sessionChanged(.stub("a", window: "other", task: task)))

        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(server.requests("window.createTask").isEmpty)
        #expect(server.requests("tab.create").isEmpty)
        #expect(fixture.controller.state.task(id: task.id)?.windowId == "other")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["other"])
        #expect(focus.seen.count == 1)
    }

    /// A row on its way out is selected and nothing more: its window is closing, or gone.
    @Test func choosingATaskBeingRemovedOpensNothing() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        fixture.controller.remover.seedSnapshotRemoval(.removing, of: task.id)

        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(server.requests("window.createTask").isEmpty)
        #expect(fixture.controller.focus.selectedTaskId == task.id)
    }

    /// A row whose worktree is missing has nothing to open into.
    @Test func aTaskWhoseCheckoutIsMissingIsNotOpened() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        fixture.controller.checkouts.seedSnapshotFixture(WorkspaceScan(branchByCwd: [:], projectBranch: [:],
                                                                       missingCheckouts: [task.id], removedTasks: [], remotes: [:]))
        fixture.controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(server.requests("window.createTask").isEmpty)
        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(fixture.controller.issue == nil, "the row already says its worktree is missing")
    }

    /// A task being created is in the workspace before its window opens: the creation opens that
    /// window, and neither a snapshot nor choosing the row meanwhile opens a second one.
    @Test func aTaskBeingCreatedIsOpenedOnce() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon(holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        let create = Task { try await controller.launcher.createTask(draft: fixture.draft("New"), project: fixture.project) }
        try await server.received("window.createTask")
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        let id = try #require(controller.state.tasks.first?.id)
        let choice = controller.focus.select(.task(id))
        server.release()
        try await create.value
        await choice?.value

        #expect(server.requests("window.createTask").count == 1)
        #expect(controller.state.tasks.map(\.windowId) == ["reopened"])
    }

    /// A worktree gone before the checkout monitor has read it so: the open finds nothing to open in,
    /// and opens nothing, quietly; the monitor's pass then says so on the row.
    @Test func aTaskWhoseWorktreeWentUnreadIsNotOpened() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        try fixture.git.run(["worktree", "remove", task.worktreePath], in: fixture.repo.path)
        fixture.controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(server.requests("window.createTask").isEmpty)
        #expect(fixture.controller.issue == nil)
    }

    /// An open that fails is reported on the click; choosing the row again tries again, and raises
    /// what it opens.
    @Test func choosingARowWhoseOpenFailedTriesAgainAndRaisesIt() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(failing: ["window.createTask": "temporary_failure"])
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        fixture.controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await fixture.controller.focus.select(.task(task.id))?.value
        #expect(fixture.controller.issue?.title == "Couldn’t reopen the window.")
        #expect(fixture.controller.issue?.subject == task.id)
        #expect(focus.seen.isEmpty)

        server.failing = [:]
        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened-2")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["reopened-2"])
        #expect(focus.seen.count == 1)
    }

    /// A failed terminal open names its row, so a successful retry can dismiss its banner.
    @Test func aTerminalWhoseOpenFailedShowsTheBannerWithItsName() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon(failing: ["window.createTerminal": "temporary_failure"])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        fixture.controller.workspace.mutate { $0.terminals = [terminal] }
        fixture.controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await fixture.controller.focus.select(.terminal(terminal.id))?.value

        #expect(fixture.controller.issue?.title == "Couldn’t reopen “Shell”.")
        #expect(fixture.controller.issue?.subject == terminal.id)
    }

    /// AiTerm starting while iTerm2 is not running starts it, once: an adopted daemon, still running
    /// from the last launch, never does. Already running, it is left be.
    @Test func startingWhileITerm2IsNotRunningStartsItOnce() async throws {
        let launches = ControllerCallCounter()
        let fixture = try await RaceFixture(launchIterm: { launches.record() }, itermRunning: { false })
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        fixture.controller.start()
        fixture.controller.start()

        #expect(launches.count == 1)
    }

    @Test func startingWhileITerm2IsRunningLeavesItBe() async throws {
        let launches = ControllerCallCounter()
        let fixture = try await RaceFixture(launchIterm: { launches.record() }, itermRunning: { true })
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        fixture.controller.start()

        #expect(launches.count == 0)
    }

    @Test func choosingARowWithoutAWindowWithNoHelperSaysSo() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try await fixture.addTask(windowId: nil)

        #expect(fixture.controller.focus.select(.task(task.id)) == nil)

        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(fixture.controller.issue == .disconnected("again"))
    }

    /// iTerm2 is away — quit, or not started: choosing the row is the person asking for it, so iTerm2 is
    /// started, and nothing is reported for the row.
    @Test func choosingARowWithoutAWindowWhileITerm2IsAwayStartsIt() async throws {
        let launches = ControllerCallCounter()
        let fixture = try await RaceFixture(launchIterm: { launches.record() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)

        #expect(fixture.controller.focus.select(.task(task.id)) == nil)

        #expect(launches.count == 1)
        #expect(server.requests("window.createTask").isEmpty)
        #expect(fixture.controller.issue == nil)
    }

    /// The one click after a quit is enough: the row chosen while iTerm2 was away opens once iTerm2
    /// connects, if it is still the selection, and is raised as a click raises it. One the selection
    /// left, or one chosen before another, opens nothing.
    @Test func aRowChosenWhileITerm2IsAwayOpensOnceItConnectsIfStillSelected() async throws {
        let launches = ControllerCallCounter(), focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() }, launchIterm: { launches.record() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }

        // Chosen, then the selection moves to a project: dropped at the snapshot.
        controller.focus.select(.terminal(terminal.id))
        controller.focus.browse(.project(fixture.project.id))
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        #expect(server.requests("window.createTerminal").isEmpty)

        // Away again; the terminal, then the task, chosen: only the task, still selected, opens.
        controller.helper.handle(.itermDisconnected)
        controller.focus.select(.terminal(terminal.id))
        controller.focus.select(.task(task.id))
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        await controller.windows.open(.task(task.id))?.value
        await eventually(describing: "the opened window raised") { !focus.seen.isEmpty }

        #expect(launches.count == 3)
        #expect(server.requests("window.createTask").count == 1)
        #expect(controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(focus.seen.count == 1)
        #expect(controller.focus.selectedTaskId == task.id)
        #expect(server.requests("window.createTerminal").isEmpty)
        #expect(controller.issue == nil)
    }
}
