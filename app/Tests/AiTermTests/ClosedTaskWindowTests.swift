import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Closing one task's window asks Remove Task's own question a second later; iTerm2 going away asks
/// nothing; a close a removal makes is the removal's. Each test first delivers a connected snapshot,
/// as the app's bootstrap does: a close before one is never asked about.
extension AppControllerTests {
    @MainActor final class Calls {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @Test func closingATasksWindowAsksRemovesQuestionAndCancelKeepsTheRow() async throws {
        let clock = ManualInstant(), forward = Calls()
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Cancel"), bringForward: { forward.record() },
                                      now: { clock.now })
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        controller.helper.handle(.snapshot(fixture.snapshot(tagging: task, in: "alive")))

        controller.helper.handle(.windowClosed("alive"))
        #expect(controller.state.task(id: task.id)?.windowId == nil, "the row stays, windowless, at once")
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value

        let asked = try #require(fixture.prompter.asked.first)
        #expect(fixture.prompter.asked.count == 1)
        #expect(asked.message == "Remove task “Work”?")
        #expect(asked.detail == "Deletes the worktree and closes its iTerm2 window:\n\n\(task.worktreePath)")
        #expect(asked.buttons == ["Remove", "Cancel"])
        #expect(asked.checkbox == "Also delete branch feat/work")
        #expect(forward.count == 1, "AiTerm comes forward for it")
        #expect(controller.state.task(id: task.id)?.windowId == nil)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
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

    /// The fixture's prompter answers nothing: a question here fails the test.
    @Test(arguments: ItermGoingAway.allCases)
    func itermGoingAwayAsksNothingAndKeepsTheRow(_ shape: ItermGoingAway) async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(now: { clock.now })
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "shell", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [.stub("a", window: "alive", task: task), .stub("b", window: "shell")],
                                                          usage: .empty)))

        switch shape {
        case .disconnectsDuringTheHold:
            controller.helper.handle(.windowClosed("alive"))
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
            controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
        }
        clock.advance(by: ClosedWindowTriage.hold)
        await controller.windows.settling?.value
        await controller.windows.asking?.value

        #expect(fixture.prompter.asked.isEmpty)
        #expect(controller.state.task(id: task.id)?.windowId == nil, "the row stays, windowless")
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
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        let second = TaskItem.stub(in: fixture.project, title: "Second", windowId: "w2")
        let third = TaskItem.stub(in: fixture.project, title: "Third", windowId: "w3")
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

        #expect(fixture.prompter.asked.map(\.message) == ["Remove task “Work”?"])
        #expect(controller.state.tasks.map(\.windowId) == [nil, after == .itermDisconnects ? "w2" : nil,
                                                           after == .itermDisconnects ? "w3" : nil])
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
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
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
    }

    /// Quit while a close is held: its question is never asked, however long the hold had to go.
    @Test func quittingWhileACloseIsHeldAsksNothing() async throws {
        let clock = ManualInstant()
        let fixture = try RaceFixture(now: { clock.now })
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(RecordingDaemon())
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
        #expect(controller.state.task(id: task.id)?.windowId == nil, "the row stays, windowless")
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
}
