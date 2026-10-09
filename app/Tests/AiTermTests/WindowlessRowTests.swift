import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A task row whose window closed is the way back to it: a click or ↩ reopens the window and goes to it;
/// the arrows only select it (`peekingARowWithoutAWindowOnlySelectsIt`).
extension AppControllerTests {
    @Test func choosingATaskWhoseWindowClosedReopensItThenBringsItermForward() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)

        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests.map(\.method).filter { $0.hasPrefix("window.") }
                == ["window.createTask", "window.setFrame", "window.activate"])
        #expect(focus.seen.count == 1, "iTerm2 comes forward once the reopened window is raised")
    }

    @Test func returnOnATaskWhoseWindowClosedReopensIt() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.focus.browse(.task(task.id))
        #expect(server.requests("window.createTask").isEmpty, "selecting it opens nothing")

        await fixture.controller.activateSelection()?.value

        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened")
    }

    /// Moved on while the window opens: it still opens, but neither it nor iTerm2 comes forward.
    @Test func aReopenTheSelectionLeftOpensTheWindowWithoutRaisingIt() async throws {
        let focus = ItermFocus()
        let fixture = try RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.createTask")
        focus.server = server
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)

        let choice = fixture.controller.focus.select(.task(task.id))
        try await server.received("window.createTask")
        fixture.controller.focus.browse(nil)
        server.release()
        await choice?.value

        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests("window.activate").isEmpty)
        #expect(focus.seen.isEmpty)
    }

    /// A row that says its worktree is missing has nothing to reopen into: it is selected, as before.
    @Test func choosingATaskWhoseCheckoutIsMissingReopensNothing() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.checkouts.seedSnapshotFixture(WorkspaceScan(branchByCwd: [:], projectBranch: [:],
                                                                       missingCheckouts: [task.id], removedTasks: [], remotes: [:]))

        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(server.requests("window.createTask").isEmpty)
        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(fixture.controller.issue == nil, "the row already says its worktree is missing")
    }

    @Test func choosingATaskWhoseWindowClosedWhileDisconnectedSaysSo() throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try fixture.addTask(windowId: nil)

        #expect(fixture.controller.focus.select(.task(task.id)) == nil)

        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(fixture.controller.issue == .disconnected("again"))
    }
}
