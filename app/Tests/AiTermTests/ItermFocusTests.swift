import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Choosing a row or creating a terminal ends with iTerm2 frontmost, so the person can type at
/// once: the daemon only raises the window inside iTerm2, and the app itself is brought forward
/// after. A new task or review, whose agent is already at work, leaves the keyboard in the sidebar.
@MainActor @Suite(.blocking) struct ItermFocusControllerTests {
    enum TakenOverWindow: CaseIterable { case notStarted, queued, shell, conversations }

    @Test(arguments: TakenOverWindow.allCases)
    func clickingATakenOverTaskOpensItsWindowAndBringsItermForward(window: TakenOverWindow) async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        var task = window == .notStarted || window == .queued
            ? TaskItem.make(project: fixture.project.id, branch: "feat/work", worktreePath: "", windowId: nil)
            : try await fixture.addTask(windowId: nil)
        task.signalTask = SignalTask(signal: UUID(), item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        task.signalTask?.phase = window == .queued ? .launching : .blocked
        task.signalTask?.takenOver = true
        task.signalTask?.ownership = 1
        task.firstPrompt = "The Operator's original instruction must not be replayed."
        if window == .conversations {
            task.conversations = [.init(agent: task.agent, id: "saved-main"), .init(agent: .claude, id: "saved-companion")]
        }
        controller.workspace.mutate { $0.tasks = [task] }
        #expect(controller.workspace.flush())
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await controller.choose(task: task.id)?.value

        let current = try #require(controller.state.task(id: task.id))
        #expect(current.hasCheckout)
        #expect(current.windowId == "reopened")
        #expect(focus.seen.count == 1)
        #expect(server.requests("window.activate").last?.params["windowId"] as? String == "reopened")
        let opened = try #require(server.requests("window.createTask").first)
        #expect(opened.params["cwd"] as? String == current.worktreePath)
        if window == .conversations {
            #expect(try guardedWorkerCommand(opened.params["agentCommand"] as? String)?.contains("saved-main") == true)
            #expect(try guardedWorkerCommand(server.requests("tab.create").first?.params["agentCommand"] as? String)?.contains("saved-companion") == true)
            let scope = WorkerGuardLaunch.recordedScope(task: task.id, home: controller.signalController.ports.home)
            #expect(scope?.ownership == 1 && scope?.allowsPush == true && scope?.branch == task.branch)
        } else {
            #expect(opened.params["agentCommand"] == nil)
        }
        let git = fixture.git, path = current.worktreePath
        let branch = try await BackgroundWork.run { try git.run(["branch", "--show-current"], in: path) }
        #expect(branch.trimmingCharacters(in: .whitespacesAndNewlines) == task.branch)
    }

    @Test(arguments: [false, true])
    func aTakenOverWindowOpeningFollowsTheLatestClick(clickAgain: Bool) async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        var task = try await fixture.addTask(windowId: nil)
        task.signalTask = SignalTask(signal: UUID(), item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        task.signalTask?.takenOver = true
        controller.workspace.mutate { $0.tasks = [task] }
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        let first = controller.choose(task: task.id)
        try await server.received("window.createTask")
        let latest: Task<Void, Never>?
        if clickAgain { latest = controller.choose(task: task.id) }
        else { latest = nil; controller.focus.browse(.project(fixture.project.id)) }
        server.release()
        await first?.value
        await latest?.value

        #expect(server.requests("window.createTask").count == 1)
        #expect(controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(focus.seen.count == (clickAgain ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func aTakenOverTaskChecksForALiveWindowBeforeResuming(connected: Bool) async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        var task = try await fixture.addTask(windowId: nil)
        task.signalTask = SignalTask(signal: UUID(), item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        task.signalTask?.takenOver = true
        task.conversations = [.init(agent: task.agent, id: "still-running")]
        controller.workspace.mutate { $0.tasks = [task] }
        // iTerm2's windows read with none of the task's yet; the opener's own lookup then finds the live one.
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        server.snapshotValue = DaemonSnapshot(protocolVersion: 1, connected: connected,
            sessions: connected ? [.stub("live", window: "still-open", task: task, state: .working)] : [], usage: .empty)

        await controller.choose(task: task.id)?.value

        #expect(server.requests("window.createTask").isEmpty)
        #expect(controller.state.task(id: task.id)?.windowId == (connected ? "still-open" : nil))
        #expect(focus.seen.count == (connected ? 1 : 0))
        if !connected { #expect(controller.issue != nil) }
    }

    @Test(arguments: [false, true])
    func aTakenOverRequestOpensItsSourceBranchAndRefusesAFork(fork: Bool) async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() }, provider: .gitlab, remoteUrl: "git@git.example:shop/web.git")
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller, git = fixture.git, repo = fixture.repo.path
        let remote = fixture.root.appendingPathComponent("origin.git").path
        let sourceHead = try await BackgroundWork.run {
            try git.run(["init", "--bare", "-q", remote], in: repo)
            try git.run(["remote", "add", "origin", remote], in: repo)
            try git.run(["push", "-q", "origin", "main"], in: repo)
            try git.run(["checkout", "-q", "-b", "review-source"], in: repo)
            try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "request change"], in: repo)
            let head = try git.run(["rev-parse", "HEAD"], in: repo)
            try git.run(["push", "-q", "origin", "review-source"], in: repo)
            try git.run(["checkout", "-q", "main"], in: repo)
            try git.run(["branch", "-D", "review-source"], in: repo)
            return head
        }
        let stub = StubSession { _ in
            (200, Data("[{\"iid\":7,\"title\":\"Request\",\"source_branch\":\"review-source\",\"target_branch\":\"main\",\"state\":\"opened\",\"web_url\":\"https://git.example/shop/web/-/merge_requests/7\",\"source_project_id\":\(fork ? 2 : 1),\"target_project_id\":1}]".utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        controller.signalController.readConnections = { links }
        controller.helper.setDaemonClient(server)
        var task = TaskItem.make(project: fixture.project.id, branch: "review-source", model: "")
        task.mr = .init(iid: 7, title: "Request", url: "https://git.example/shop/web/-/merge_requests/7")
        task.signalTask = SignalTask(signal: UUID(), item: .request(remote: "git@git.example:shop/web.git", number: 7), startedAt: Date())
        task.signalTask?.takenOver = true
        controller.workspace.mutate { $0.tasks = [task] }
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await controller.choose(task: task.id)?.value

        let current = try #require(controller.state.task(id: task.id))
        if fork {
            #expect(!current.hasCheckout && current.windowId == nil)
            #expect(server.requests("window.createTask").isEmpty && controller.issue != nil)
        } else {
            #expect(current.hasCheckout && current.windowId == "reopened")
            let path = current.worktreePath
            let openedHead = try await BackgroundWork.run { try git.run(["rev-parse", "HEAD"], in: path) }
            #expect(openedHead == sourceHead)
            #expect(focus.seen.count == 1)
        }
    }

    @Test func choosingATaskBringsItermForwardOnceItsWindowIsActive() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "work")

        await fixture.controller.focus.select(.task(task.id))?.value

        #expect(focus.seen.count == 1)
        #expect(focus.seen.first?.last == "window.activate", "after the window, so iTerm2 comes forward showing it")
    }

    @Test func pressingReturnBringsItermForward() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try await fixture.addTask(windowId: "work")
        fixture.controller.focus.browse(.task(task.id))
        #expect(focus.seen.isEmpty, "browsing leaves the focus in the sidebar")

        await fixture.controller.activateSelection()?.value
        #expect(focus.seen.count == 1)
    }

    /// A click whose window is still being placed when the selection moves on never takes focus.
    @Test func aStaleClickDoesNotBringItermForward() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.setFrame")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "work")

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
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)

        try await fixture.controller.launcher.createTask(draft: fixture.draft("New"), project: fixture.project)

        let task = try #require(fixture.controller.state.tasks.first { $0.title == "New" })
        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(server.requests.map(\.method).last == "window.createTask")
        #expect(focus.seen.isEmpty)

        await fixture.controller.activateSelection()?.value
        #expect(focus.seen.count == 1)
    }

    /// A new terminal is selected like a new task, but comes forward: an empty shell waits on you.
    @Test func aNewTerminalIsSelectedAndBringsItermForward() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)

        await fixture.controller.terminals.newTerminal(project: fixture.project, name: "Shell")?.value

        let terminal = try #require(fixture.controller.state.terminals.first)
        #expect(fixture.controller.focus.selectedTerminalId == terminal.id)
        #expect(focus.seen.count == 1)
        #expect(focus.seen.first?.last == "window.createTerminal")
    }

    /// Moving on while the terminal opens keeps the newer choice: the terminal is added, unselected,
    /// and iTerm2 is not brought forward over what was chosen instead.
    @Test func aNewTerminalDoesNotTakeFocusFromANewerSelection() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon(holding: "window.createTerminal")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "work")

        let opening = fixture.controller.terminals.newTerminal(project: fixture.project, name: "Shell")
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
extension ItermFocusControllerTests {
    @Test func peekingShowsTheWindowAndKeepsTheKeyboardInTheSidebar() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "work")

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
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "work")
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
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "work")
        fixture.controller.live.sessions = [SessionInfo.stub(window: "work", task: task, state: .done)]
        fixture.controller.focus.browse(.task(task.id))

        await fixture.controller.showFocusView()?.value

        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["work"])
    }

    /// Holding ↓ runs past rows faster than windows can move; only the row it stops on is shown.
    @Test func arrowingPastRowsShowsOnlyTheOneItStopsOn() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let first = try await fixture.addTask(windowId: "first")
        let terminal = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: "shell", createdAt: Date())
        fixture.controller.workspace.mutate { $0.terminals = [terminal] }

        let passed = fixture.controller.focus.peek(.task(first.id))
        let stopped = fixture.controller.focus.peek(.terminal(terminal.id))
        await passed?.value
        await stopped?.value

        #expect(server.requests.map { $0.params["windowId"] as? String } == ["shell", "shell"])
    }

    /// A row whose window is closed has nothing to show; the selection still moves, and nothing is
    /// asked of the daemon.
    @Test func peekingARowWithoutAWindowOnlySelectsIt() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)

        #expect(fixture.controller.focus.peek(.task(task.id)) == nil)

        #expect(fixture.controller.focus.selectedTaskId == task.id)
        #expect(server.requests.isEmpty)
    }

    /// The window a peek raised reports itself activated. Arrowed on meanwhile to a row with no
    /// window, that echo must not pull the selection back.
    @Test func aPeeksOwnActivationDoesNotPullTheSelectionBack() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let shown = try await fixture.addTask(windowId: "work")
        let windowless = TerminalItem(id: UUID(), projectId: fixture.project.id, name: "Shell", windowId: nil, createdAt: Date())
        controller.workspace.mutate { $0.terminals = [windowless] }

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
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "work")
        controller.live.sessions = [SessionInfo.stub(window: "work", task: task, state: .done)]
        controller.remover.seedSnapshotRemoval(.removing, of: task.id)

        #expect(controller.focus.peek(.task(task.id)) == nil)
        #expect(controller.focus.selectedTaskId == task.id)
        #expect(controller.activateSelection() == nil)
        controller.focus.browse(nil)
        #expect(controller.showFocusView() == nil)
        #expect(controller.focus.selection == nil, "⌘F passes over it")
        #expect(server.requests.isEmpty)
        #expect(focus.seen.isEmpty)
    }
}
