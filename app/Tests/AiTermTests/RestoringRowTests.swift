import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A row never waits on its window: an owed one is restored by itself once iTerm2 is there. Choosing a
/// row (a click or ↩) whose restore is under way waits on it and raises what it opens; choosing one
/// whose restore failed tries again; with iTerm2 away, iTerm2 is started.
extension AppControllerTests {
    /// A connected snapshot whose tabs name none of the task's windows.
    static let emptySnapshot = DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)

    @Test func anOwedRowIsRestoredOnceITerm2IsThereWithoutBeingChosen() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        #expect(server.requests("window.createTask").isEmpty, "not before iTerm2 is known to be there")

        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        await fixture.controller.windows.lastRestore?.value

        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests("window.activate").isEmpty, "nobody chose it: it is not raised")
    }

    /// A second click or ↩ while the window comes back waits on that same restore: one window, raised once.
    @Test func choosingARowWhileItsRestoreRunsRaisesWhatItOpensOnce() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.createTask")
        focus.server = server
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        try await server.received("window.createTask")

        let first = fixture.controller.focus.select(.task(task.id))
        let second = fixture.controller.focus.select(.task(task.id))
        #expect(first != nil && second != nil, "each choice waits on the restore under way")
        server.release()
        await first?.value
        await second?.value

        #expect(server.requests("window.createTask").count == 1)
        #expect(server.requests("window.activate").count == 1)
        #expect(focus.seen.count == 1)
    }

    /// Moved on while the window opens: it still opens, but neither it nor iTerm2 comes forward.
    @Test func aRestoreTheSelectionLeftOpensTheWindowWithoutRaisingIt() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.createTask")
        focus.server = server
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        try await server.received("window.createTask")

        let choice = fixture.controller.focus.select(.task(task.id))
        fixture.controller.focus.browse(nil)
        server.release()
        await choice?.value

        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests("window.activate").isEmpty)
        #expect(focus.seen.isEmpty)
    }

    /// The task's tab lives on in another window: the row takes that window, and choosing it raises it.
    @Test func choosingATaskWhoseTabLivesOnElsewhereRaisesThatWindow() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
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
    @Test func choosingATaskBeingRemovedRestoresNothing() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.seedSnapshotRemoval(.removing, of: task.id)

        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(server.requests("window.createTask").isEmpty)
        #expect(fixture.controller.focus.selectedTaskId == task.id)
    }

    /// A row whose worktree is missing has nothing to restore into, chosen or not.
    @Test func aTaskWhoseCheckoutIsMissingIsNotRestored() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.checkouts.seedSnapshotFixture(WorkspaceScan(branchByCwd: [:], projectBranch: [:],
                                                                       missingCheckouts: [task.id], removedTasks: [], remotes: [:]))
        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(server.requests("window.createTask").isEmpty)
        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(fixture.controller.issue == nil, "the row already says its worktree is missing")
    }

    /// A task being created is in the workspace before its window opens: the creation opens that
    /// window, and neither its own start nor a snapshot meanwhile restores it a second time.
    @Test func aTaskBeingCreatedIsOpenedOnceAndNotRestored() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        controller.helper.handle(.snapshot(Self.emptySnapshot))

        let create = Task { try await controller.createTask(draft: fixture.draft("New"), project: fixture.project) }
        try await server.received("window.createTask")
        controller.helper.handle(.snapshot(Self.emptySnapshot))
        server.release()
        try await create.value
        await controller.windows.lastRestore?.value

        #expect(server.requests("window.createTask").count == 1)
        #expect(controller.state.tasks.map(\.windowId) == ["reopened"])
    }

    @Test func choosingAnOwedRowWithNoHelperSaysSo() throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try fixture.addTask(windowId: nil)

        #expect(fixture.controller.focus.select(.task(task.id)) == nil)

        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(fixture.controller.issue == .disconnected("again"))
    }

    /// iTerm2 is away — quit, or not started: choosing the row is the person asking for it, so iTerm2 is
    /// started, and the window comes back with the snapshot that follows.
    @Test func choosingAnOwedRowWhileITerm2IsAwayStartsIt() throws {
        let launches = Calls()
        let fixture = try RaceFixture(launchIterm: { launches.record() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)

        #expect(fixture.controller.focus.select(.task(task.id)) == nil)

        #expect(launches.count == 1)
        #expect(server.requests("window.createTask").isEmpty)
        #expect(fixture.controller.issue == nil)
    }
}
