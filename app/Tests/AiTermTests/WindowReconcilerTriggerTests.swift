import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// What starts a window reconciler pass (phase 7). A session event passes only when it moves something a row draws; the
/// two inputs that waited on any session event before — a checkout read back, the workspace able to change again — pass
/// themselves; and while a row is owed a window and not restored, the checkout monitor's poll passes too.
@MainActor @Suite(.blocking) struct WindowReconcilerTriggerTests {
    /// A connected snapshot with one tab no row owns, whose context fill a later event moves.
    static let unrelated = SessionInfo.make("unrelated", window: "elsewhere", cwd: "/")
    static let snapshot = DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [unrelated], usage: .empty)

    /// Whether the checkout monitor reads every task's worktree missing.
    final class Missing: Sendable {
        private let state: Mutex<Bool>
        init(_ value: Bool) { state = Mutex(value) }
        var value: Bool {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    /// The checkout monitor reads the task's worktree missing while `missing` holds, and back once it does not.
    static func scan(_ missing: Missing) -> CheckoutMonitor.Scanner {
        { _, _, tasks, _, _, _, _ in
            WorkspaceScan(branchByCwd: [:], projectBranch: [:],
                          missingCheckouts: missing.value ? Set(tasks.filter(\.hasCheckout).map(\.id)) : [],
                          removedTasks: [], remotes: [:])
        }
    }

    /// An owed row held back because its checkout reads missing gets its window once the monitor reads it back: at that
    /// read, with no session event. Before phase 7 only the rows a restore had found gone were passed for, and every
    /// other owed row waited for the next session event of any kind.
    @Test func anOwedRowWhoseCheckoutComesBackIsRestoredAtThatRead() async throws {
        let missing = Missing(true)
        let fixture = try await RaceFixture(scan: Self.scan(missing))
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        await controller.checkouts.refresh().value
        #expect(controller.checkouts.isMissing(task.id))
        controller.helper.handle(.snapshot(Self.snapshot))
        await controller.windows.lastRestore?.value
        #expect(server.requests("window.createTask").isEmpty, "held back while its checkout reads missing")

        missing.value = false
        await controller.checkouts.refresh().value
        await controller.windows.lastRestore?.value

        #expect(!controller.checkouts.isMissing(task.id))
        #expect(controller.state.task(id: task.id)?.windowId == "reopened", "restored at the read, with no session event")
    }

    /// An owed row waiting on a workspace that could not save gets its window once a save succeeds again: then, with no
    /// session event. Before phase 7 it waited for the next session event of any kind.
    @Test func anOwedRowWaitingOnTheWorkspaceLockIsRestoredOnceItLifts() async throws {
        let fixture = try await RaceFixture(scan: Budget.noScan)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        try controller.breakSaving()
        controller.helper.handle(.snapshot(Self.snapshot))
        await controller.windows.lastRestore?.value
        #expect(server.requests("window.createTask").isEmpty, "held back while the workspace cannot change")

        try FileManager.default.removeItem(at: controller.workspace.file.backupURL)
        controller.workspace.mutate { $0.sidebarFrame = CGRect(x: 0, y: 0, width: 2, height: 2) }
        #expect(controller.workspace.flush(), "saving again")
        await controller.windows.lastRestore?.value

        #expect(controller.canChangeWorkspace)
        #expect(controller.state.task(id: task.id)?.windowId == "reopened", "restored as the lock lifts, with no session event")
    }

    /// A row that can have its window back by a path no trigger covers is restored within one poll of the checkout
    /// monitor: each poll asks the window plan, in memory, whether a pass would act. Here the daemon is attached after
    /// the snapshot that left the row owed, with no snapshot after it, which no trigger hears; in the app a snapshot
    /// follows an attach.
    @Test func anOwedRowNoTriggerCoversIsRestoredWithinOnePoll() async throws {
        let fixture = try await RaceFixture(scan: Budget.noScan, checkoutPollInterval: .milliseconds(20))
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try await fixture.addTask(windowId: nil)
        controller.helper.handle(.snapshot(Self.snapshot))
        await controller.windows.lastRestore?.value
        controller.helper.setDaemonClient(server)
        await controller.windows.lastRestore?.value
        #expect(controller.state.task(id: task.id)?.windowId == nil, "no trigger has heard the daemon come")
        var polls = 0
        controller.checkouts.onPolled { polls += 1 }

        controller.checkouts.startMonitoring()
        await eventually(describing: "one poll") { polls >= 1 }
        await controller.windows.lastRestore?.value
        controller.checkouts.stop()

        #expect(controller.state.task(id: task.id)?.windowId == "reopened", "restored within one poll")
    }

    /// A row held back — here its checkout keeps reading missing — gives the poll nothing to do: the plan restores
    /// nothing for it, so the poll starts no pass.
    @Test func aRowHeldBackStartsNoPassAtAPoll() async throws {
        let controller = AppController(preferences: .scratch(), checkoutPollInterval: .milliseconds(10),
                                       scan: Self.scan(Missing(true)))
        defer { controller.shutdown() }
        try controller.workspace.load()
        let project = Project.make(path: "/repo")
        let task = TaskItem.make(project: project.id, title: "a", worktreePath: "/repo/a", windowId: nil)
        controller.workspace.mutate { $0.append(project: project); $0.tasks = [task] }
        controller.helper.setDaemonClient(RecordingDaemon())
        await controller.checkouts.refresh().value
        controller.helper.handle(.snapshot(Self.snapshot))
        await controller.windows.lastRestore?.value
        var polls = 0
        controller.checkouts.onPolled { polls += 1 }

        let work = await Budget.metered {
            controller.checkouts.startMonitoring()
            await eventually(describing: "three polls") { polls >= 3 }
            controller.checkouts.stop()
        }

        #expect(controller.checkouts.isMissing(task.id))
        #expect(work[.reconcilerPass, default: 0] == 0, "passes for \(polls) polls: \(work)")
    }

    /// Worktrees imported when a project is added come in as rows owed their windows, with no session event and no
    /// checkout read changing: they are restored at the import (phase 7, review round 1). Before, they waited for the
    /// next session event of any kind.
    @Test func importedWorktreesGetTheirWindowsAtTheImport() async throws {
        let fixture = try await RaceFixture(prompter: ScriptedPrompter(answering: "Import"))
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        controller.workspace.mutate { $0.items = [] }
        #expect(controller.workspace.flush())
        try fixture.git.run(["worktree", "add", "-q", "-b", "feat/old", fixture.repo.path + "/.worktrees/old"], in: fixture.repo.path)
        controller.helper.handle(.snapshot(Self.snapshot))
        await controller.windows.lastRestore?.value

        await controller.projects.addProject(path: fixture.repo.path)
        let imported = try #require(controller.state.tasks.first)
        #expect(imported.windowId == nil, "imported without a window")

        await eventually(describing: "the imported row's window") { controller.state.task(id: imported.id)?.windowId == "reopened" }
        await controller.windows.lastRestore?.value
        #expect(controller.state.task(id: imported.id)?.windowId == "reopened")
    }
}
