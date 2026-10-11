import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Closing one task's window asks Remove Task's own question a second later, and Cancel brings it
/// back; a terminal's takes its row; iTerm2 going away asks nothing, and its windows come back once it
/// does; a close a removal makes is the removal's. Each test first delivers a connected snapshot,
/// as the app's bootstrap does: a close before one is never asked about.
extension AppControllerTests {
    @MainActor final class Calls {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @Test func closingATasksWindowAsksRemovesQuestionAndCancelReopensAndRaisesIt() async throws {
        let clock = ManualInstant(), forward = Calls(), focus = ItermFocus()
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Cancel"), activateIterm: { focus.activate() },
                                      bringForward: { forward.record() }, now: { clock.now })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        controller.helper.handle(.snapshot(fixture.snapshot(tagging: task, in: "alive")))

        controller.helper.handle(.windowClosed("alive"))
        #expect(controller.state.task(id: task.id)?.windowId == nil, "owed at once, its row drawn as it was")
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value
        await controller.windows.lastRestore?.value
        await eventually(describing: "the reopened window raised") { !server.requests("window.activate").isEmpty }

        let asked = try #require(fixture.prompter.asked.first)
        #expect(fixture.prompter.asked.count == 1)
        #expect(asked.message == "Remove task “Work”?")
        #expect(asked.detail == "Deletes its worktree and closes its iTerm2 window.")
        #expect(asked.buttons == ["Remove", "Cancel"])
        #expect(asked.checkbox == "Delete local branch")
        #expect(asked.checkboxHelp == "feat/work")
        #expect(forward.count == 1, "AiTerm comes forward for it")
        #expect(server.requests("window.createTask").count == 1)
        #expect(controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(focus.seen.count == 1, "iTerm2 comes forward with it")
    }

    @Test func answeringRemoveAfterAClosedWindowRemovesTheTask() async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Remove"), now: { clock.now })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        controller.helper.handle(.snapshot(fixture.snapshot(tagging: task, in: "alive")))

        controller.helper.handle(.windowClosed("alive"))
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value

        #expect(controller.state.tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(server.requests("window.close").isEmpty, "its window was already gone")
        #expect(controller.toastState.toast?.message == "Task removed.")
    }

    enum ItermGoingAway: String, CaseIterable, Sendable {
        case disconnectsDuringTheHold, closesAnotherWindowDuringTheHold, isAnnouncedAfterAReconnect
    }

    /// iTerm2 going away asks nothing, and restores nothing until it is back and quiet: then the task
    /// and the terminal each get their window again, unraised.
    @Test(arguments: ItermGoingAway.allCases)
    func itermGoingAwayAsksNothingAndRestoresOnceConnected(_ shape: ItermGoingAway) async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(now: { clock.now })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "shell", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [.stub("a", window: "alive", task: task),
                                                                     .stub("b", window: "shell", terminal: terminal)],
                                                          usage: .empty)))

        switch shape {
        case .disconnectsDuringTheHold:
            controller.helper.handle(.windowClosed("alive"))
            controller.helper.handle(.windowClosed("shell"))
            clock.advance(by: .milliseconds(300))
            controller.helper.handle(.itermDisconnected)
        case .closesAnotherWindowDuringTheHold:
            controller.helper.handle(.windowClosed("alive"))
            clock.advance(by: .milliseconds(300))
            controller.helper.handle(.windowClosed("shell"))
        case .isAnnouncedAfterAReconnect:
            controller.helper.handle(.itermDisconnected)
            clock.advance(by: .seconds(5))
            controller.helper.handle(.itermConnected("3.7.2"))
            controller.helper.handle(.windowClosed("alive"))
            controller.helper.handle(.windowClosed("shell"))
        }
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value
        #expect(fixture.prompter.asked.isEmpty)
        if shape != .closesAnotherWindowDuringTheHold {
            #expect(server.requests("window.createTask").isEmpty, "nothing reopens into an iTerm2 that is away")
            controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
        }
        await controller.windows.lastRestore?.value

        #expect(fixture.prompter.asked.isEmpty)
        #expect(server.requests("window.createTask").count == 1)
        #expect(server.requests("window.createTerminal").map { $0.params["terminalId"] as? String } == [terminal.id.uuidString])
        #expect(controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(controller.state.terminals.map(\.windowId) == ["terminal-window"])
        #expect(server.requests("window.activate").isEmpty, "restored quietly")
    }

    enum AfterALoneClose: String, CaseIterable, Sendable {
        case twoOtherTaskWindowsClose, itermDisconnects
    }

    /// Only what happens within the second after a close cancels its question: one task's window
    /// closes alone, and 1.2 s later iTerm2 goes away — a burst of two other task windows, or a
    /// disconnect. The lone close is still asked about, once; the burst asks nothing.
    @Test(arguments: AfterALoneClose.allCases)
    func aLoneCloseIsAskedAboutEvenWhenITerm2GoesAwayAfterItsHold(_ after: AfterALoneClose) async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Cancel"), now: { clock.now })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        let second = TaskItem.stub(in: fixture.project, title: "Second", windowId: "w2")
        let third = TaskItem.stub(in: fixture.project, title: "Third", windowId: "w3")
        // Real worktrees: a restore opens only into one that is there.
        for other in [second, third] {
            try fixture.git.run(["worktree", "add", "-q", "-b", other.branch, other.worktreePath], in: fixture.repo.path)
        }
        controller.workspace.mutate { $0.tasks += [second, third] }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            .stub("a", window: "alive", task: task), .stub("b", window: "w2", task: second), .stub("c", window: "w3", task: third),
        ], usage: .empty)))

        controller.helper.handle(.windowClosed("alive"))
        clock.advance(by: .milliseconds(1200))
        switch after {
        case .twoOtherTaskWindowsClose:
            controller.helper.handle(.windowClosed("w2"))
            controller.helper.handle(.windowClosed("w3"))
        case .itermDisconnects:
            controller.helper.handle(.itermDisconnected)
        }
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value
        await controller.windows.lastRestore?.value

        #expect(fixture.prompter.asked.map(\.message) == ["Remove task “Work”?"])
        switch after {
        case .twoOtherTaskWindowsClose:
            #expect(server.requests("window.createTask").count == 3, "Cancel reopens Work; the burst comes back quietly")
            #expect(controller.state.tasks.allSatisfy { $0.windowId != nil })
        case .itermDisconnects:
            #expect(server.requests("window.createTask").isEmpty, "iTerm2 is away: the windows wait for it")
            #expect(controller.state.tasks.map(\.windowId) == [nil, "w2", "w3"])
        }
    }

    /// Remove closes the window itself; its `window.closed` is the removal's, not a second question.
    @Test func theCloseARemovalMakesAsksNothingMore() async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Remove"), now: { clock.now })
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        controller.helper.handle(.snapshot(fixture.snapshot(tagging: task, in: "alive")))

        let removal = await controller.confirmRemove(task: task)
        try await server.received("window.close")
        controller.helper.handle(.windowClosed("alive"))
        #expect(!controller.windows.triage.isHolding, "the removal's close, held as no task's")
        server.release()
        await removal?.value
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value

        #expect(fixture.prompter.asked.count == 1, "Remove's own question, and no second")
        #expect(controller.state.tasks.isEmpty)
    }

    /// The checkout cleanup closes the window of a task whose worktree went; its `window.closed` is the
    /// cleanup's, held as a close of no task, and the cleanup forgets the task without a question.
    @Test func theCloseTheCheckoutCleanupMakesAsksNothing() async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(now: { clock.now })
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        controller.helper.handle(.snapshot(fixture.snapshot(tagging: task, in: "alive")))
        try fixture.git.run(["worktree", "remove", task.worktreePath], in: fixture.repo.path)

        controller.checkouts.refresh()
        try await server.received("window.close")
        controller.helper.handle(.windowClosed("alive"))
        #expect(!controller.windows.triage.isHolding, "the cleanup's close, held as no task's")
        server.release()
        await eventually(describing: "the task forgotten") { controller.state.tasks.isEmpty }
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value

        #expect(fixture.prompter.asked.isEmpty)
    }

    /// The task's only tab dragged into another window — or Merge All Windows — closes its own window,
    /// but the task lives on there: once the hold is over the row takes that window, and nothing is
    /// asked. The daemon announces the window's close before the tab's move, as it does here.
    @Test func aTaskWhoseTabLivesOnInAnotherWindowIsNotAskedAboutAndTakesThatWindow() async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(now: { clock.now })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [.stub("a", window: "alive", task: task), .stub("b", window: "other")],
                                                          usage: .empty)))

        controller.helper.handle(.windowClosed("alive"))
        controller.helper.handle(.sessionChanged(.stub("a", window: "other", task: task)))
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value

        #expect(fixture.prompter.asked.isEmpty)
        #expect(controller.state.task(id: task.id)?.windowId == "other")
        #expect(server.requests("window.createTask").isEmpty)
    }

    /// Quit while a close is held: its question is never asked, nor its window restored, however long
    /// the hold had to go.
    @Test func quittingWhileACloseIsHeldAsksAndRestoresNothing() async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(now: { clock.now })
        let server = RecordingDaemon()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        controller.helper.handle(.snapshot(fixture.snapshot(tagging: task, in: "alive")))

        controller.helper.handle(.windowClosed("alive"))
        let settling = controller.windows.settling
        #expect(controller.windows.triage.isHolding)
        controller.shutdown()
        #expect(!controller.windows.triage.isHolding, "quit lets go of the held close")
        clock.advance(by: ClosedWindowTriage.hold)
        await settling?.value
        await controller.windows.asking?.value

        #expect(fixture.prompter.asked.isEmpty)
        #expect(server.requests("window.createTask").isEmpty)
        #expect(controller.state.task(id: task.id)?.windowId == nil, "owed: the next launch restores it")
    }

    /// One alert at a time: a second close, held and due while the first question is up, is asked once
    /// that one is answered.
    @Test func twoClosesSecondsApartAreAskedOneAfterTheOther() async throws {
        let clock = ManualInstant()
        let prompter = ScriptedPrompter(answering: "Cancel", "Cancel")
        let fixture = try RaceFixture(prompter: prompter, now: { clock.now })
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
        let first = try fixture.addTask(windowId: "w1")
        let second = TaskItem.stub(in: fixture.project, title: "Other", windowId: "w2")
        controller.workspace.mutate { $0.tasks.append(second) }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [.stub("a", window: "w1", task: first), .stub("b", window: "w2", task: second)],
                                                          usage: .empty)))
        prompter.whileAsking = { prompt in
            guard prompt.message == "Remove task “Work”?" else { return }
            clock.advance(by: .seconds(5))
            controller.helper.handle(.windowClosed("w2"))
            clock.advance(by: ClosedWindowTriage.hold)
            await controller.windows.settling?.value
            #expect(prompter.asked.count == 1, "the second waits for the first")
        }

        controller.helper.handle(.windowClosed("w1"))
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value   // the first question, during which the second was queued
        await controller.windows.asking?.value   // the second, which waited for it

        #expect(prompter.asked.map(\.message) == ["Remove task “Work”?", "Remove task “Other”?"])
    }

    /// A terminal's window closed alone takes its row, as Remove Terminal would; nothing is asked.
    @Test func aTerminalsWindowClosedAloneTakesItsRow() async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(now: { clock.now })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "shell", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [.stub("b", window: "shell", terminal: terminal)], usage: .empty)))

        controller.helper.handle(.windowClosed("shell"))
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value

        #expect(controller.state.terminals.isEmpty)
        #expect(fixture.prompter.asked.isEmpty)
        #expect(server.requests("window.createTerminal").isEmpty)
    }

    /// Another task being created in the project meanwhile is that task's own work: a lone close is
    /// still asked about.
    @Test func aLoneCloseIsAskedAboutWhileAnotherTaskIsCreated() async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Cancel"), now: { clock.now })
        let server = RecordingDaemon(holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        controller.helper.handle(.snapshot(fixture.snapshot(tagging: task, in: "alive")))
        let create = Task { try await controller.createTask(draft: fixture.draft("New"), project: fixture.project) }
        try await server.received("window.createTask")

        controller.helper.handle(.windowClosed("alive"))
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value

        #expect(fixture.prompter.asked.map(\.message) == ["Remove task “Work”?"])
        server.release()
        try await create.value
        await controller.windows.lastRestore?.value
        #expect(controller.state.tasks.allSatisfy { $0.windowId != nil }, "Cancel brought Work back; New has its own")
        #expect(server.requests("window.createTask").count == 2)
    }

    /// While Remove's question is up the row is the question's: a snapshot meanwhile restores nothing.
    @Test func aRowAskedAboutIsNotRestoredWhileTheAlertIsUp() async throws {
        let clock = ManualInstant()
        let prompter = ScriptedPrompter(answering: "Remove")
        let fixture = try RaceFixture(prompter: prompter, now: { clock.now })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        controller.helper.handle(.snapshot(fixture.snapshot(tagging: task, in: "alive")))
        prompter.whileAsking = { _ in
            controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
            clock.advance(by: .seconds(5))
            controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
            #expect(server.requests("window.createTask").isEmpty)
        }

        controller.helper.handle(.windowClosed("alive"))
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value

        #expect(controller.state.tasks.isEmpty)
        #expect(server.requests("window.createTask").isEmpty)
    }

    /// The pinning test for the lock's worst outcomes — a duplicate or a resurrection: across a
    /// reconnect, each row gets exactly one window whether iTerm2's own come back before or after
    /// AiTerm restores, and a task whose removal let its window go is never given one.
    @Test func aReconnectRestoresEachRowOnceAndNeverOneBeingRemoved() async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Remove"), now: { clock.now })
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "a")
        let early = TaskItem.stub(in: fixture.project, title: "Early", windowId: "e")
        // Leaving needs a real worktree: its removal checks it for unsaved work before closing the window.
        let leavingPath = fixture.repo.appendingPathComponent(".worktrees/leaving").path
        try fixture.git.run(["worktree", "add", "-q", "-b", "feat/leaving", leavingPath], in: fixture.repo.path)
        let leaving = TaskItem.stub(in: fixture.project, title: "Leaving", branch: "feat/leaving", worktreePath: leavingPath, windowId: "l")
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "t", createdAt: Date())
        controller.workspace.mutate { $0.tasks += [early, leaving]; $0.terminals = [terminal] }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            .stub("1", window: "a", task: task), .stub("2", window: "e", task: early), .stub("3", window: "l", task: leaving),
            .stub("4", window: "t", terminal: terminal),
        ], usage: .empty)))
        // The removal lets its window go and is held there.
        let removal = await controller.confirmRemove(task: leaving)
        try await server.received("window.close")

        controller.helper.handle(.itermDisconnected)
        clock.advance(by: .seconds(5))
        controller.helper.handle(.itermConnected("3.7.2"))
        // iTerm2 restored Early's window before the first snapshot; the others come later.
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            .stub("5", window: "e-restored", task: early),
        ], usage: .empty)))
        await controller.windows.lastRestore?.value
        // iTerm2's own windows for Work, the terminal and Leaving arrive late, beside AiTerm's.
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            .stub("5", window: "e-restored", task: early), .stub("6", window: "reopened", task: task),
            .stub("7", window: "terminal-window", terminal: terminal), .stub("8", window: "a-late", task: task),
            .stub("9", window: "t-late", terminal: terminal), .stub("10", window: "l-late", task: leaving),
        ], usage: .empty)))
        await controller.windows.lastRestore?.value

        #expect(server.requests("window.createTask").map { $0.params["taskId"] as? String } == [task.id.uuidString])
        #expect(server.requests("window.createTerminal").count == 1)
        #expect(controller.state.task(id: early.id)?.windowId == "e-restored")
        #expect(controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(controller.state.terminals.first?.windowId == "terminal-window")
        #expect(controller.state.task(id: leaving.id)?.windowId == nil)
        server.release()
        await removal?.value
        #expect(controller.state.task(id: leaving.id) == nil)
    }
}
