import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// One owner opens every kind of row's window when it is chosen without one (`RowWindows.open`), and
/// keeps each row's window, the Operator's chat's included, as iTerm2 reports it.
@MainActor @Suite(.blocking) struct RowWindowsControllerTests {
    /// A signal permitting the fixture's task's agent row, and that task driven by it, its worker's
    /// conversation saved and no window.
    func driven(_ fixture: RaceFixture, phase: TaskPhase = .working, checkout: Bool = true) async throws -> TaskItem {
        let signal = Signal(name: "Plan tickets", createdAt: Date(), source: .jira(JiraConditions()), work: SignalWork(prompt: "/psg:plan"),
                            agents: [AgentChoice(agent: .codex, model: "model", reasoning: nil)],
                            finish: SignalFinish(doneWhen: .operatorJudges, then: .keep))
        var task = checkout ? try await fixture.addTask(windowId: nil)
            : TaskItem.make(project: fixture.project.id, worktreePath: "", agent: .codex, model: "model", windowId: nil)
        var record = SignalTask.make(signal: signal, item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        record.phase = phase
        task.signalTask = record
        task.conversations = checkout ? [TaskConversation(agent: .codex, id: "worker-conversation")] : []
        fixture.controller.workspace.mutate { state in
            state.signals = [signal]
            state.tasks.removeAll { $0.id == task.id }
            state.tasks.append(task)
        }
        #expect(fixture.controller.workspace.flush())
        return task
    }

    /// An established chat with a question only the person can answer: work for the Operator, and no
    /// signal task for its passes to start.
    func establishedChat(_ controller: AppController, window: String? = nil) -> OperatorSession {
        var session = OperatorSession(createdAt: Date())
        session.window = window
        session.conversation = "chat-conversation"
        session.questions = [.init(id: "global", task: nil, text: "Which project should future signals use?", openedAt: Date())]
        controller.workspace.mutate { $0.operatorSession = session }
        return session
    }

    /// The person's click opens a driven task's window as a task's (`TaskLauncher.open`), whether the Operator runs or
    /// not: in its worktree, titled by its branch, its first worker's conversation resumed under its branch guard.
    @Test func choosingADrivenTaskWithoutAWindowResumesItsWorkerUnderItsGuardInItsWorktreeAndRaisesIt() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        var task = try await driven(fixture)
        controller.workspace.mutate { $0.updateSignalTask(task.id) { $0.ownership = 3 } }
        task = try #require(controller.state.task(id: task.id))
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await controller.choose(.task(task.id))?.value

        let opened = try #require(server.requests("window.createTask").first)
        #expect(server.requests("window.createTask").count == 1)
        #expect(server.requests("tab.create").isEmpty, "one command: its first worker's")
        #expect(opened.params["cwd"] as? String == task.worktreePath)
        #expect(opened.params["title"] as? String == task.branch)
        let line = opened.params["agentCommand"] as? String
        #expect(line?.hasPrefix("/bin/sh '") == true, "the branch guard wraps the worker")
        #expect(try guardedWorkerCommand(line)?.contains("worker-conversation") == true)
        let scope = try #require(WorkerGuardLaunch.recordedScope(task: task.id, home: controller.signalController.ports.home))
        #expect(scope.ownership == 3 && scope.worktree == task.worktreePath && scope.branch == task.branch)
        #expect(controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(focus.seen.count == 1)
    }

    /// iTerm2 made the window but could not type its command: the row takes the window, and the plain shell it shows
    /// is said on the row, with the daemon's reason, instead of passing for a resumed conversation.
    @Test(arguments: [false, true])
    func aWindowWhoseCommandWasNotTypedIsAdoptedAndSaidOnItsTask(isDriven: Bool) async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        server.commandErrors["window.createTask"] = "The session ended before the command was typed."
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task: TaskItem
        if isDriven { task = try await driven(fixture) }
        else {
            task = try await fixture.addTask(windowId: nil)
            controller.workspace.mutate { $0.tasks[0].conversations = [TaskConversation(agent: .codex, id: "thread-1")] }
        }
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await controller.choose(.task(task.id))?.value

        #expect(server.requests("window.createTask").count == 1)
        #expect(controller.state.task(id: task.id)?.windowId == "reopened")
        let issue = try #require(controller.issue)
        #expect(issue.subject == task.id)
        #expect(issue.title == (isDriven ? "Reopened the window, but its worker didn’t resume."
                                       : "Reopened the window, but not every conversation."))
        #expect(issue.reason == "The session ended before the command was typed.")
    }

    @Test func aDrivenWorkerReopenThatFailsIsReportedOnTheClickAboutItsTask() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon(failing: ["window.createTask": "temporary_failure"])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await driven(fixture)
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        await controller.choose(.task(task.id))?.value

        #expect(controller.issue?.title == "Couldn’t reopen the window.")
        #expect(controller.issue?.subject == task.id)
        #expect(controller.signalController.issues.current.isEmpty, "not an Operator issue")
    }

    @Test func choosingADrivenTaskStillLaunchingWithoutACheckoutOnlySelectsIt() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await driven(fixture, phase: .launching, checkout: false)
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        #expect(controller.choose(.task(task.id)) == nil)

        #expect(controller.focus.selectedTaskId == task.id)
        #expect(server.requests.isEmpty)
        #expect(controller.issue == nil)
    }

    @Test func choosingTheOperatorRowWithoutAWindowOpensItsChatOnceAndRaisesIt() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        _ = establishedChat(controller)
        controller.signalController.start()
        await controller.signalController.ports.work.settled()
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        await controller.signalController.ports.work.settled()
        #expect(server.requests("window.createTask").isEmpty, "a closed chat with nothing to type stays closed")

        await controller.choose(.operatorChat)?.value

        #expect(server.requests("window.createTask").count == 1)
        // The line it types, or past the inline limit the launch file that line reads.
        let line = try #require(server.requests("window.createTask").first?.params["agentCommand"] as? String)
        let launch = line.hasPrefix("eval ") ? try String(contentsOf: OperatorLaunch.folder(home: controller.signalController.ports.home)
            .appendingPathComponent(OperatorLaunch.launchFile), encoding: .utf8) : line
        #expect(launch.contains("--resume") && launch.contains("chat-conversation"), "it resumes its conversation: \(launch)")
        #expect(controller.state.operatorSession?.window == "reopened")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(focus.seen.count == 1)
        #expect(controller.focus.selection == .operatorChat)
        #expect(controller.issue == nil)
    }

    @Test func choosingTheOperatorRowWithNoWorkOnlySelectsIt() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        #expect(controller.choose(.operatorChat) == nil)

        #expect(controller.focus.selection == .operatorChat)
        #expect(server.requests.isEmpty)
        #expect(controller.issue == nil)
    }

    /// The chat closed is a closed view: no pass opens it again, until the Operator has something to
    /// type into it.
    @Test func aClosedChatStaysClosedUntilTheOperatorHasSomethingToTypeIntoIt() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let session = establishedChat(controller, window: "chat-window")
        controller.signalController.start()
        await controller.signalController.ports.work.settled()
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            .make("chat", window: "chat-window", task: session.id, agent: .claude, state: .idle, conversation: "chat-conversation"),
        ], usage: .empty)))
        await controller.signalController.ports.work.settled()

        controller.helper.handle(.windowClosed("chat-window"))
        #expect(controller.state.operatorSession?.window == nil)
        await controller.signalController.reconcile()
        #expect(server.requests("window.createTask").isEmpty)

        controller.signalController.native.onTurn(UUID())
        await controller.signalController.reconcile()
        await controller.signalController.reconcile()

        #expect(server.requests("window.createTask").count == 1)
        #expect(controller.state.operatorSession?.window == "reopened")
    }

    /// iTerm2 restored the chat's window: its tab, tagged with the session's id, gives the chat that
    /// window without opening another. Not while a handover runs: the old and new chats carry one tag.
    @Test func aRestoredChatWindowIsTakenByItsTagExceptDuringAHandover() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let session = establishedChat(controller)
        func tagged(in window: String) -> DaemonSnapshot {
            DaemonSnapshot(protocolVersion: 1, connected: true,
                           sessions: [.make("chat", window: window, task: session.id, agent: .shell)], usage: .empty)
        }

        controller.helper.handle(.snapshot(tagged(in: "restored")))
        #expect(controller.state.operatorSession?.window == "restored")

        controller.workspace.mutate { $0.operatorSession?.handover = .closing }
        controller.helper.handle(.snapshot(tagged(in: "newer")))
        #expect(controller.state.operatorSession?.window == "restored")
        #expect(server.requests("window.createTask").isEmpty)
    }

    @Test func aNotificationsOpenOnATaskWithoutAWindowOpensAndRaisesIt() async throws {
        let focus = ControllerItermFocus()
        let fixture = try await RaceFixture(activateIterm: { focus.activate() })
        let server = RecordingDaemon()
        focus.server = server
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        controller.helper.handle(.snapshot(ControllerSnapshots.empty))

        controller.signalController.ports.notifications.onOpen?(.task(task.id))
        await eventually(describing: "the opened window raised") { focus.seen.count == 1 }

        #expect(server.requests("window.createTask").count == 1)
        #expect(controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests("window.activate").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(controller.focus.selectedTaskId == task.id)
    }
}
