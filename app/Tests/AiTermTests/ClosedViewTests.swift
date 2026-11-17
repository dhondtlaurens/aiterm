import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A row's window is a view of the row: closing it asks nothing and removes nothing, and nothing opens
/// it again by itself — not after a close, not when iTerm2 restarts, not for imported worktrees.
/// Choosing the row opens it. A row still takes a window its tag is in. Each test first delivers a
/// connected snapshot, as the app's bootstrap does.
@MainActor @Suite(.blocking) struct ClosedViewControllerTests {
    @Test func closingATasksWindowClearsItAndAsksOpensAndBringsNothingForward() async throws {
        let launches = ControllerCallCounter(), focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() }, launchIterm: { launches.record() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        controller.workspace.mutate { $0.tasks[0].conversations = [TaskConversation(agent: .codex, id: "thread-1")] }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [.stub("a", window: "alive", task: task)], usage: .empty)))
        controller.focus.browse(.task(task.id))
        let conversations = controller.state.task(id: task.id)?.conversations

        controller.helper.handle(.windowClosed("alive"))

        #expect(controller.state.task(id: task.id)?.windowId == nil)
        #expect(controller.state.task(id: task.id)?.conversations == conversations)
        #expect(controller.focus.selectedTaskId == task.id)
        #expect(fixture.prompter.asked.isEmpty)
        #expect(server.requests("window.createTask").isEmpty)
        #expect(server.requests("window.activate").isEmpty)
        #expect(focus.seen.isEmpty)
        #expect(launches.count == 0)
        #expect(controller.work.operation(onTask: task.id) == nil)
    }

    @Test func closingATerminalsWindowKeepsItsRowAndChoosingItOpensOneFreshShell() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "shell", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [.stub("b", window: "shell", terminal: terminal)], usage: .empty)))

        controller.helper.handle(.windowClosed("shell"))

        #expect(controller.state.terminals.map(\.id) == [terminal.id])
        #expect(controller.state.terminals.first?.windowId == nil)
        #expect(fixture.prompter.asked.isEmpty)
        #expect(server.requests("window.createTerminal").isEmpty)

        await controller.choose(.terminal(terminal.id))?.value

        #expect(server.requests("window.createTerminal").map { $0.params["terminalId"] as? String } == [terminal.id.uuidString])
        #expect(server.requests("window.createTerminal").first?.params["cwd"] as? String == fixture.project.path)
        #expect(controller.state.terminals.first?.windowId == "terminal-window")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["terminal-window"])
        #expect(focus.seen.count == 1)
    }

    @Test func choosingAClosedTaskOpensItOnceWithItsConversationsResumedAndRaisesIt() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.createTask")
        focus.server = server
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        controller.workspace.mutate {
            $0.tasks[0].conversations = [TaskConversation(agent: .codex, id: "thread-1"), TaskConversation(agent: .claude, id: "conv-2")]
        }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [.stub("a", window: "alive", task: task)], usage: .empty)))
        controller.helper.handle(.windowClosed("alive"))

        let first = controller.choose(.task(task.id))
        try await server.received("window.createTask")
        let second = controller.choose(.task(task.id))
        server.release()
        await first?.value
        await second?.value

        let window = try #require(server.requests("window.createTask").first)
        #expect(server.requests("window.createTask").count == 1)
        #expect(window.params["agentCommand"] as? String == "codex resume thread-1 --dangerously-bypass-approvals-and-sandbox -m model")
        #expect(server.requests("tab.create").map { $0.params["agentCommand"] as? String } == ["claude --resume conv-2"])
        #expect(controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(focus.seen.count == 1)
    }

    /// iTerm2 restarted: its first connected snapshot lists none of the rows' windows. Each row is left
    /// without one and nothing is opened; a later snapshot listing a tagged window gives that row its window.
    @Test func aSnapshotLackingEveryWindowLeavesEveryRowWithoutOneAndOpensNothing() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "a")
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "t", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal] }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            .stub("1", window: "a", task: task), .stub("2", window: "t", terminal: terminal),
        ], usage: .empty)))

        controller.helper.handle(.itermDisconnected)
        controller.helper.handle(.itermConnected("3.7.2"))
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        #expect(controller.state.task(id: task.id)?.windowId == nil)
        #expect(controller.state.terminals.first?.windowId == nil)
        #expect(server.requests("window.createTask").isEmpty)
        #expect(server.requests("window.createTerminal").isEmpty)

        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [.stub("3", window: "restored", task: task)], usage: .empty)))

        #expect(controller.state.task(id: task.id)?.windowId == "restored")
        #expect(controller.state.terminals.first?.windowId == nil)
        #expect(server.requests("window.createTask").isEmpty)
        #expect(server.requests("window.createTerminal").isEmpty)
    }

    /// The arrow keys look, and never open: a row without a window is selected, and the daemon hears nothing.
    @Test func peekingAtARowWithoutAWindowSelectsItAndSendsNothing() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        #expect(controller.focus.peek(.task(task.id)) == nil)

        #expect(controller.focus.selectedTaskId == task.id)
        #expect(server.requests.filter { $0.method.hasPrefix("window.") || $0.method.hasPrefix("tab.") }.isEmpty)
        #expect(controller.work.operation(onTask: task.id) == nil)
    }

    /// Worktrees imported with a new project come in as rows without windows, and open nothing until chosen.
    @Test func worktreesImportedWithANewProjectComeInWithoutWindowsAndOpenNothing() async throws {
        let fixture = try await RaceFixture(prompter: ScriptedPrompter(answering: "Import"))
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        controller.workspace.mutate { $0.items = [] }
        #expect(controller.workspace.flush())
        try fixture.git.run(["worktree", "add", "-q", "-b", "feat/old", fixture.repo.path + "/.worktrees/old"], in: fixture.repo.path)
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await controller.projects.addProject(path: fixture.repo.path)
        await controller.savePreparedProject()
        let imported = try #require(controller.state.tasks.first)
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        #expect(imported.windowId == nil)
        #expect(controller.state.task(id: imported.id)?.windowId == nil)
        #expect(server.requests("window.createTask").isEmpty)

        await controller.choose(.task(imported.id))?.value

        #expect(server.requests("window.createTask").count == 1)
        #expect(controller.state.task(id: imported.id)?.windowId == "reopened")
    }

    /// A failed open is reported on the click, about its row; the row itself carries no mark of it.
    @Test func aFailedOpenIsReportedOnTheClickAndTheRowHasNoOtherMarkOfIt() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon(failing: ["window.createTask": "temporary_failure"])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        #expect(controller.issue == nil)

        await controller.choose(.task(task.id))?.value

        #expect(controller.issue?.title == "Couldn’t reopen the window.")
        #expect(controller.issue?.subject == task.id)
        #expect(controller.state.task(id: task.id)?.windowId == nil)
        #expect(controller.work.operation(onTask: task.id) == nil)
        let caption = TaskRowCaption(removal: controller.remover.removal(of: task.id), missing: controller.checkouts.isMissing(task.id))
        #expect(caption == TaskRowCaption(progress: nil, note: nil))
        #expect(server.requests("window.createTask").count == 1, "nothing tries again by itself")
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        #expect(server.requests("window.createTask").count == 1)
    }

    /// The task's only tab dragged into another window — or Merge All Windows — closes its own window,
    /// but the task lives on there: the row takes that window, nothing opens and nothing is asked. The
    /// daemon announces the window's close before the tab's move, as it does here.
    @Test func aTaskWhoseTabLivesOnInAnotherWindowTakesThatWindow() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [.stub("a", window: "alive", task: task), .stub("b", window: "other")],
                                                          usage: .empty)))

        controller.helper.handle(.windowClosed("alive"))
        controller.helper.handle(.sessionChanged(.stub("a", window: "other", task: task)))

        #expect(fixture.prompter.asked.isEmpty)
        #expect(controller.state.task(id: task.id)?.windowId == "other")
        #expect(server.requests("window.createTask").isEmpty)
    }

    /// The pinning test against a duplicate or a resurrection: across a reconnect, each row takes its
    /// own tagged window whenever iTerm2 brings it back, and AiTerm opens none.
    @Test func acrossAReconnectEachRowTakesItsOwnTaggedWindowAndNothingIsOpened() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "a")
        let early = TaskItem.stub(in: fixture.project, title: "Early", windowId: "e")
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "t", createdAt: Date())
        controller.workspace.mutate { $0.tasks += [early]; $0.terminals = [terminal] }
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            .stub("1", window: "a", task: task), .stub("2", window: "e", task: early), .stub("4", window: "t", terminal: terminal),
        ], usage: .empty)))

        controller.helper.handle(.itermDisconnected)
        controller.helper.handle(.itermConnected("3.7.2"))
        // iTerm2 restored Early's window before the first snapshot; the others come later.
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            .stub("5", window: "e-restored", task: early),
        ], usage: .empty)))
        #expect(controller.state.task(id: early.id)?.windowId == "e-restored")
        #expect(controller.state.task(id: task.id)?.windowId == nil)
        #expect(controller.state.terminals.first?.windowId == nil)
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            .stub("5", window: "e-restored", task: early), .stub("8", window: "a-late", task: task),
            .stub("9", window: "t-late", terminal: terminal),
        ], usage: .empty)))

        #expect(server.requests("window.createTask").isEmpty)
        #expect(server.requests("window.createTerminal").isEmpty)
        #expect(controller.state.task(id: early.id)?.windowId == "e-restored")
        #expect(controller.state.task(id: task.id)?.windowId == "a-late")
        #expect(controller.state.terminals.first?.windowId == "t-late")
    }
}
