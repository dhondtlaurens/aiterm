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

    /// A project signal's task still owing its first prompt, chosen: its launch opens the window at once with the prompt,
    /// the choosing waits for it and raises that window, iTerm2 brought forward, in one click.
    @Test func choosingAProjectSignalsTaskOwingItsLaunchOpensAndRaisesItsWindow() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller, signals = controller.signalController
        controller.helper.setDaemonClient(server)
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        let signal = Signal.project()
        controller.workspace.mutate { $0.signals = [signal] }
        signals.sourceRegistrations = { _ in [] }; signals.tabsKnown = true
        signals.start(); await signals.ports.work.settled()
        // Added once the runtime runs, so only the choosing launches it.
        let task = try await fixture.addTask(windowId: nil)
        controller.workspace.mutate { state in
            state.tasks[0].signalOrigin = SignalOrigin(signal: signal.id, name: signal.name, item: .ticket(site: "https://jira.example", key: "PAY-1"),
                                                       startedAt: Date(), owed: OwedPrompt(text: "Go on", at: Date(), kind: .launch))
        }
        #expect(controller.workspace.flush())

        await controller.choose(task: task.id)?.value

        let opened = try #require(server.requests("window.createTask").first)
        #expect((opened.params["agentCommand"] as? String)?.hasSuffix("'Go on'") == true)
        let current = try #require(controller.state.task(id: task.id))
        #expect(current.windowId == "reopened" && current.signalOrigin?.owed == nil)
        #expect(server.requests("window.activate").last?.params["windowId"] as? String == "reopened")
        #expect(focus.seen.count == 1 && controller.focus.selectedTaskId == task.id)
    }

    /// Take Over makes an ordinary task: one whose worker never started gets its worktree on its branch at once,
    /// and choosing it opens its window like any task's, its conversations resumed plainly, outside any branch guard.
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
        task.signalTask = SignalTask.make(item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        task.signalTask?.phase = window == .queued ? .launching : .blocked
        task.firstPrompt = "The Operator's original instruction must not be replayed."
        if window == .conversations {
            task.conversations = [.init(agent: task.agent, id: "saved-main"), .init(agent: .claude, id: "saved-companion")]
        }
        controller.workspace.mutate { $0.tasks = [task] }
        #expect(controller.workspace.flush())
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await controller.takeOver(task.id)
        let taken = try #require(controller.state.task(id: task.id))
        #expect(taken.signalTask == nil && taken.takenOver && taken.hasCheckout)
        await controller.choose(task: task.id)?.value

        let current = try #require(controller.state.task(id: task.id))
        #expect(current.windowId == "reopened")
        #expect(focus.seen.count == 1)
        #expect(server.requests("window.activate").last?.params["windowId"] as? String == "reopened")
        let opened = try #require(server.requests("window.createTask").first)
        #expect(opened.params["cwd"] as? String == current.worktreePath)
        if window == .conversations {
            let first = try #require(opened.params["agentCommand"] as? String)
            let second = try #require(server.requests("tab.create").first?.params["agentCommand"] as? String)
            #expect(try guardedWorkerCommand(first) == first && first.contains("saved-main"))
            #expect(try guardedWorkerCommand(second) == second && second.contains("saved-companion"))
            #expect(WorkerGuardLaunch.recordedScope(task: task.id, home: controller.signalController.ports.home) == nil)
        } else {
            #expect(opened.params["agentCommand"] == nil)
        }
        let git = fixture.git, path = current.worktreePath
        let branch = try await BackgroundWork.run { try git.run(["branch", "--show-current"], in: path) }
        #expect(branch.trimmingCharacters(in: .whitespacesAndNewlines) == task.branch)
    }

    @Test(arguments: [false, true])
    func aTakenOverRequestOpensItsSourceBranchAndRefusesAFork(fork: Bool) async throws {
        let focus = ControllerItermFocus()
        // The request's host is the project's GitLab remote, while git fetches from a local `origin`: the checkout
        // monitor's passes read every other thing from disk, but leave the project's remote as it was saved, rather
        // than adopt that local path at whichever pass lands before the Take Over's request lookup.
        let keepingRemote: CheckoutMonitor.Scanner = { cwds, projects, tasks, branches, remotes, diffs in
            var scan = WorkspaceScan.run(cwds: cwds, projects: projects, tasks: tasks, branches: branches, remotes: remotes, diffs: diffs)
            scan.remotes = [:]
            return scan
        }
        let fixture = try await RaceFixture(activateIterm: { focus.activate() }, scan: keepingRemote, provider: .gitlab,
                                            remoteUrl: "git@git.example:shop/web.git")
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
        task.signalTask = SignalTask.make(item: .request(remote: "git@git.example:shop/web.git", number: 7), startedAt: Date())
        controller.workspace.mutate { $0.tasks = [task] }
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await controller.takeOver(task.id)

        if fork {
            let current = try #require(controller.state.task(id: task.id))
            #expect(current.takenOver && !current.hasCheckout && current.windowId == nil)
            #expect(server.requests("window.createTask").isEmpty && controller.issue?.subject == task.id)
        } else {
            #expect(controller.state.task(id: task.id)?.hasCheckout == true, "\(String(describing: controller.issue))")
            await controller.choose(task: task.id)?.value
            let current = try #require(controller.state.task(id: task.id))
            #expect(current.windowId == "reopened")
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
        fixture.controller.helper.handle(.snapshot(fixture.snapshot(tagging: task, in: "work")))
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
        fixture.controller.helper.handle(.snapshot(ControllerSnapshots.empty))

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
        controller.teardown.seedSnapshotState(.removing, of: task.id)

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
