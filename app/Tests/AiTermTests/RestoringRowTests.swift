import Foundation
import Testing
import Synchronization
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

        let create = Task { try await controller.launcher.createTask(draft: fixture.draft("New"), project: fixture.project) }
        try await server.received("window.createTask")
        controller.helper.handle(.snapshot(Self.emptySnapshot))
        server.release()
        try await create.value
        await controller.windows.lastRestore?.value

        #expect(server.requests("window.createTask").count == 1)
        #expect(controller.state.tasks.map(\.windowId) == ["reopened"])
    }

    /// A worktree gone before the checkout monitor has read it so: the restore finds nothing to open
    /// in, and opens nothing, quietly — the monitor's pass then says so, and closes the row.
    @Test func aTaskWhoseWorktreeWentUnreadIsNotRestored() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        try fixture.git.run(["worktree", "remove", task.worktreePath], in: fixture.repo.path)

        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        await fixture.controller.windows.lastRestore?.value

        #expect(server.requests("window.createTask").isEmpty)
        #expect(!fixture.controller.windows.hasFailed(task.id))
        #expect(fixture.controller.issue == nil)
    }

    /// A worktree a restore found gone is looked for once, not again at every pass until the checkout
    /// monitor reads it: the row waits for the monitor, whose pass then says the worktree is missing.
    @Test func aWorktreeFoundGoneIsLookedForOnceUntilTheMonitorReadsIt() async throws {
        let read = Mutex(false)
        let fixture = try RaceFixture(scan: { cwds, projects, tasks, branches, remotes, diffs, defaultBranches in
            // Until `read`, a pass that has not seen the worktree go.
            read.withLock { $0 }
                ? WorkspaceScan.run(cwds: cwds, projects: projects, tasks: tasks, branches: branches, remotes: remotes, diffs: diffs,
                                    defaultBranches: defaultBranches)
                : WorkspaceScan(branchByCwd: [:], projectBranch: [:], missingCheckouts: [], removedTasks: [], remotes: [:])
        })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        try fixture.git.run(["worktree", "remove", task.worktreePath], in: fixture.repo.path)
        var attempts = 0
        controller.work.onChange { subject in
            if subject == .task(task.id), controller.work.operation(onTask: task.id) == .reopening { attempts += 1 }
        }

        controller.helper.handle(.snapshot(Self.emptySnapshot))
        await controller.windows.lastRestore?.value
        await controller.checkouts.refreshTask?.value
        controller.helper.handle(.snapshot(Self.emptySnapshot))
        await controller.windows.lastRestore?.value
        #expect(attempts == 1, "looked for once, then left for the monitor")
        #expect(!controller.checkouts.isMissing(task.id))

        read.withLock { $0 = true }
        await controller.checkouts.refresh().value
        await controller.windows.lastRestore?.value
        #expect(controller.checkouts.isMissing(task.id))
        #expect(attempts == 1, "the monitor says it is missing: nothing more is tried")
        #expect(server.requests("window.createTask").isEmpty)
        #expect(!controller.windows.hasFailed(task.id))
    }

    /// A restore waiting its turn looks again before it opens: iTerm2 closing windows meanwhile — a quit
    /// under way — stops it, and it comes back once iTerm2 is quiet again.
    @Test func aQueuedRestoreWaitsOutWindowsClosingMeanwhile() async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(now: { clock.now })
        let server = RecordingDaemon(holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        _ = try fixture.addTask(windowId: nil)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }
        controller.helper.handle(.snapshot(Self.emptySnapshot))
        try await server.received("window.createTask")

        controller.helper.handle(.windowClosed("elsewhere"))
        server.release()
        await controller.windows.lastRestore?.value
        #expect(server.requests("window.createTerminal").isEmpty, "not while iTerm2 is closing windows")
        #expect(!controller.windows.hasFailed(terminal.id))

        // The close's own look, a hold after it, is the pass that plans the restore again. A test's
        // hold is none, so that look has run already: the pass is asked for here, once quiet.
        clock.advance(by: ClosedWindowTriage.hold)
        controller.windows.pass()
        await controller.windows.lastRestore?.value
        #expect(controller.state.terminals.map(\.windowId) == ["terminal-window"])
    }

    /// A restore that fails while iTerm2 is there says so on the row; choosing the row tries again,
    /// and raises what it opens.
    @Test func choosingARowWhoseRestoreFailedTriesAgainAndRaisesIt() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(failing: ["window.createTask": "temporary_failure"])
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        await fixture.controller.windows.lastRestore?.value
        #expect(fixture.controller.hasFailedRestore(task.id))
        #expect(fixture.controller.issue?.title == "Couldn’t reopen the window.")
        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        await fixture.controller.windows.lastRestore?.value
        #expect(server.requests("window.createTask").count == 1, "a failed row waits for the person")

        server.failing = [:]
        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(!fixture.controller.hasFailedRestore(task.id))
        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened-2")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["reopened-2"])
        #expect(focus.seen.count == 1)
    }

    /// A restore that fails because iTerm2 went away meanwhile is not the row's failure: the next
    /// connected snapshot restores it.
    @Test func aRestoreThatFailsAsItermGoesAwayIsNotMarkedFailed() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(failing: ["window.createTask": "iterm_unavailable"], holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        try await server.received("window.createTask")
        fixture.controller.helper.handle(.itermDisconnected)
        server.release()
        await fixture.controller.windows.lastRestore?.value
        #expect(!fixture.controller.hasFailedRestore(task.id))

        server.failing = [:]
        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        await fixture.controller.windows.lastRestore?.value

        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened-2")
    }

    /// A failed row that gets a window another way — a restore that timed out but whose window opened,
    /// iTerm2's own restoration — takes it, and the caption and its retry hint go with the failure.
    @Test func aFailedRowThatAdoptsAWindowNoLongerSaysItFailed() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(failing: ["window.createTask": "temporary_failure"])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        await fixture.controller.windows.lastRestore?.value
        #expect(fixture.controller.hasFailedRestore(task.id))

        fixture.controller.helper.handle(.sessionChanged(.stub("a", window: "other", task: task)))

        #expect(fixture.controller.state.task(id: task.id)?.windowId == "other")
        #expect(!fixture.controller.hasFailedRestore(task.id))
        #expect(server.requests("window.createTask").count == 1, "adopted, not opened again")
    }

    /// A restore refused because iTerm2 is unavailable is not the row's failure even while the snapshot
    /// still says synced: the failed reply and the disconnect event race in the daemon.
    @Test func aRestoreRefusedForITerm2BeingUnavailableIsNotMarkedFailedWhileSynced() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(failing: ["window.createTask": "iterm_unavailable"])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        await fixture.controller.windows.lastRestore?.value

        #expect(!fixture.controller.hasFailedRestore(task.id))
        #expect(fixture.controller.issue == nil)

        server.failing = [:]
        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        await fixture.controller.windows.lastRestore?.value
        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened-2")
    }

    /// A failed terminal reopen names its row, so a successful retry can dismiss its banner.
    @Test func aTerminalWhoseRestoreFailedShowsTheBannerWithItsName() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(failing: ["window.createTerminal": "temporary_failure"])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        fixture.controller.workspace.mutate { $0.terminals = [terminal] }

        fixture.controller.helper.handle(.snapshot(Self.emptySnapshot))
        await fixture.controller.windows.lastRestore?.value

        #expect(fixture.controller.issue?.title == "Couldn’t reopen “Shell”.")
        #expect(fixture.controller.issue?.subject == terminal.id)
        #expect(fixture.controller.hasFailedRestore(terminal.id))
    }

    /// AiTerm starting while iTerm2 is not running starts it, once: an adopted daemon, still running
    /// from the last launch, never does. Already running, it is left be.
    @Test func startingWhileITerm2IsNotRunningStartsItOnce() throws {
        let launches = Calls()
        let fixture = try RaceFixture(launchIterm: { launches.record() }, itermRunning: { false })
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        fixture.controller.start()
        fixture.controller.start()

        #expect(launches.count == 1)
    }

    @Test func startingWhileITerm2IsRunningLeavesItBe() throws {
        let launches = Calls()
        let fixture = try RaceFixture(launchIterm: { launches.record() }, itermRunning: { true })
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        fixture.controller.start()

        #expect(launches.count == 0)
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
