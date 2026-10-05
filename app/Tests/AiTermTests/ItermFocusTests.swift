import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Choosing a row or creating a terminal ends with iTerm2 frontmost, so the person can type at
/// once: the daemon only raises the window inside iTerm2, and the app itself is brought forward
/// after. A new task or review, whose agent is already at work, leaves the keyboard in the sidebar.
extension AppControllerTests {
    /// What the daemon had been asked each time iTerm2 was brought forward.
    @MainActor final class ItermFocus {
        var server: RecordingDaemon?
        private(set) var seen: [[String]] = []
        func activate() { seen.append(server?.requests.map(\.method) ?? []) }
    }

    @Test func choosingATaskBringsItermForwardOnceItsWindowIsActive() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "work")

        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(focus.seen.count == 1)
        #expect(focus.seen.first?.last == "window.activate", "after the window, so iTerm2 comes forward showing it")
    }

    @Test func pressingReturnBringsItermForward() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "work")
        fixture.controller.focus.browse(.task(task.id))
        #expect(focus.seen.isEmpty, "browsing leaves the focus in the sidebar")

        await fixture.controller.focus.activateSelection()?.value
        #expect(focus.seen.count == 1)
    }

    /// A click whose window is still being placed when the selection moves on never takes focus.
    @Test func aStaleClickDoesNotBringItermForward() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.setFrame")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "work")

        let click = fixture.controller.focus.select(.task(task.id))
        try await server.received("window.setFrame")
        fixture.controller.focus.browse(nil)
        server.release()
        await click?.value

        #expect(focus.seen.isEmpty)
        #expect(server.requests("window.activate").isEmpty)
    }

    /// The agent is already on the prompt: the task is selected and its window opened, and Return
    /// is all it takes to go to it.
    @Test func aCreatedTaskIsSelectedButLeavesTheKeyboardInTheSidebar() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)

        try await fixture.controller.createTask(draft: fixture.draft("New"), project: fixture.project)

        let task = try #require(fixture.controller.state.tasks.first { $0.title == "New" })
        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(server.requests.map(\.method).last == "window.createTask")
        #expect(focus.seen.isEmpty)

        await fixture.controller.focus.activateSelection()?.value
        #expect(focus.seen.count == 1)
    }

    /// A new terminal is selected like a new task, but comes forward: an empty shell waits on you.
    @Test func aNewTerminalIsSelectedAndBringsItermForward() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)

        await fixture.controller.newTerminal(project: fixture.project, name: "Shell")?.value

        let terminal = try #require(fixture.controller.state.terminals.first)
        #expect(fixture.controller.focus.selectedTerminalId == terminal.id)
        #expect(focus.seen.count == 1)
        #expect(focus.seen.first?.last == "window.createTerminal")
    }

    /// Moving on while the terminal opens keeps the newer choice: the terminal is added, unselected,
    /// and iTerm2 is not brought forward over what was chosen instead.
    @Test func aNewTerminalDoesNotTakeFocusFromANewerSelection() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.createTerminal")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "work")

        let opening = fixture.controller.newTerminal(project: fixture.project, name: "Shell")
        try await server.received("window.createTerminal")
        fixture.controller.focus.browse(.task(task.id))
        server.release()
        await opening?.value

        #expect(fixture.controller.state.terminals.count == 1)
        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(focus.seen.isEmpty)
    }
}

/// The arrow keys peek: the row's window is placed beside the sidebar and raised in iTerm2, but
/// iTerm2 is not brought forward, so the keyboard stays in the sidebar. Return or a click commits.
extension AppControllerTests {
    @Test func peekingShowsTheWindowAndKeepsTheKeyboardInTheSidebar() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "work")

        let peek = fixture.controller.focus.peek(.task(task.id))
        #expect(fixture.controller.focus.selectedTaskId == task.id)
        await peek?.value

        #expect(server.requests.map(\.method) == ["window.setFrame", "window.activate"])
        #expect(server.requests.allSatisfy { $0.params["windowId"] as? String == "work" })
        #expect(focus.seen.isEmpty)
        // Looking is not acting: a task that finished stays blue, so Focus View still finds it.
        #expect(server.requests("sessions.markSeen").isEmpty)
    }

    /// ⌘F goes to the first row waiting on you as the arrows would: its window is shown, the
    /// keyboard stays in the sidebar to arrow on, and the task stays blue until Return opens it.
    @Test func focusViewPeeksAtTheFirstRowNeedingAttention() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "work")
        fixture.controller.live.sessions = [SessionInfo.stub(window: "work", task: task, state: .done)]

        let peek = fixture.controller.showFocusView()
        #expect(fixture.controller.focus.selectedTaskId == task.id)
        await peek?.value

        #expect(server.requests("window.activate").count == 1)
        #expect(focus.seen.isEmpty)
        #expect(server.requests("sessions.markSeen").isEmpty)
    }

    /// The waiting row can already be selected, its window buried under others: ⌘F still shows it.
    @Test func focusViewShowsTheWaitingRowAlreadySelected() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "work")
        fixture.controller.live.sessions = [SessionInfo.stub(window: "work", task: task, state: .done)]
        fixture.controller.focus.browse(.task(task.id))

        await fixture.controller.showFocusView()?.value

        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["work"])
    }

    /// Holding ↓ runs past rows faster than windows can move; only the row it stops on is shown.
    @Test func arrowingPastRowsShowsOnlyTheOneItStopsOn() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let first = try fixture.addTask(windowId: "first")
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "shell", createdAt: Date())
        fixture.controller.state.terminals = [terminal]

        let passed = fixture.controller.focus.peek(.task(first.id))
        let stopped = fixture.controller.focus.peek(.terminal(terminal.id))
        await passed?.value
        await stopped?.value

        #expect(server.requests.map { $0.params["windowId"] as? String } == ["shell", "shell"])
    }

    /// A row whose window is closed has nothing to show; the selection still moves, and nothing is
    /// asked of the daemon.
    @Test func peekingARowWithoutAWindowOnlySelectsIt() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)

        #expect(fixture.controller.focus.peek(.task(task.id)) == nil)

        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(server.requests.isEmpty)
    }

    /// The window a peek raised reports itself activated. Arrowed on meanwhile to a row with no
    /// window, that echo must not pull the selection back.
    @Test func aPeeksOwnActivationDoesNotPullTheSelectionBack() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let shown = try fixture.addTask(windowId: "work")
        let windowless = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        controller.state.terminals = [windowless]

        await controller.focus.peek(.task(shown.id))?.value
        controller.focus.peek(.terminal(windowless.id))
        controller.helper.handle(.windowActivated("work"))
        #expect(controller.focus.selectedTerminalId == windowless.id)

        // Only the echo is dropped: iTerm2 raising the window again, later, is news.
        controller.helper.handle(.windowActivated("work"))
        #expect(controller.focus.selectedTaskId == shown.id)
    }

    /// A task being removed can be selected, but Return, a peek and ⌘F leave its window be: it is
    /// about to close — the removal's first step, while git checks for unsaved work, still has it.
    @Test func aRowBeingRemovedIsNotBroughtForward() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "work")
        controller.live.sessions = [SessionInfo.stub(window: "work", task: task, state: .done)]
        controller.seedSnapshotRemoval(.removing, of: task.id)

        #expect(controller.focus.peek(.task(task.id)) == nil)
        #expect(controller.focus.selectedTaskId == task.id)
        #expect(controller.focus.activateSelection() == nil)
        controller.focus.browse(nil)
        #expect(controller.showFocusView() == nil)
        #expect(controller.focus.selection == nil, "⌘F passes over it")
        #expect(server.requests.isEmpty)
        #expect(focus.seen.isEmpty)
    }
}
