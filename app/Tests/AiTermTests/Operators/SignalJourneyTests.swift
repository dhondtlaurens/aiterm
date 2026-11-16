import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// One signal from its Jira match to its archived task, driven only through the controller's own
/// entry points. The fakes stand at the edges: the daemon, HTTP to Jira, git (hermetic, but real),
/// the clock and the worker's transcript on disk.
@MainActor @Suite(.blocking) struct SignalJourneyTests {
    /// The ticket's status as Jira answers it; the stub reads it off the main actor.
    final class TicketStatus: Sendable {
        private let value = Mutex("To Do")
        var current: String { value.withLock { $0 } }
        func set(_ status: String) { value.withLock { $0 = status } }
    }

    @Test func aJiraMatchRunsToItsDoneConditionAndThenArchivesItsTask() async throws {
        // The world: a real repository linked to Jira project PAY, one signal on it, a recording daemon.
        let fixture = try await RaceFixture()
        let daemon = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(daemon)
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        var ports = OperatorPorts.scratch()
        ports.clock.now = { clock.now }
        let site = URL(string: "https://jira.example")!
        let workspace = fixture.controller.workspace
        let signal = Signal(name: "Plan tickets", createdAt: clock.now, source: .jira(JiraConditions()),
                            work: SignalWork(prompt: "/psg:plan"), agents: [SignalWorld.agent],
                            finish: SignalFinish(doneWhen: .ticketStatus("Done"), then: .archive))
        workspace.mutate { state in
            state.updateProject(id: fixture.project.id) {
                $0.jiraProjects = [JiraProjectRef(id: "1", key: "PAY", name: "Payments", siteURL: site)]
            }
            state.signals.append(signal)
        }
        #expect(workspace.flush())

        let status = TicketStatus()
        let stub = StubSession { _ in
            let page = #"{"issues":[{"key":"PAY-1","fields":{"summary":"Make retries safe","description":"Use an idempotency key.","#
                + #""issuetype":{"name":"Task"},"status":{"name":""# + status.current + #""}}}],"isLast":true}"#
            return (200, Data(page.utf8))
        }
        let links = SignalConnections(jira: JiraConfig(siteURL: site, email: "fake", token: "fake"), session: stub.session)

        // The controller under test, wired as the app wires its own.
        let controller = SignalOperatorController(workspace: workspace, live: fixture.controller.live, work: fixture.controller.work,
                                                  ports: ports, daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) },
                                                  automatic: false)
        controller.readConnections = { links }
        controller.archive = fixture.controller.signalController.archive
        fixture.controller.helper.onEvent { [weak controller] in controller?.handle($0) }
        defer {
            controller.stop()
            fixture.controller.shutdown()
            fixture.cleanUp()
            try? FileManager.default.removeItem(at: ports.home)
        }

        // Act 1: the match starts one task with a checkout and a window.
        controller.start()
        fixture.controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
        await ports.work.settled()

        let item = ItemRef.ticket(site: "https://jira.example", key: "PAY-1")
        #expect(workspace.state.tasks.count == 1)
        let task = try #require(workspace.state.tasks.first)
        #expect(task.signalTask?.signal == signal.id)
        #expect(task.signalTask?.item == item)
        #expect(task.jira?.key == "PAY-1")
        #expect(task.signalTask?.phase == .working)
        let worktree = task.worktreePath, branch = task.branch
        #expect(FileManager.default.fileExists(atPath: worktree))
        let window = try #require(task.windowId)
        #expect(daemon.requests("window.createTask").filter { $0.params["taskId"] as? String == task.id.uuidString }.count == 1)
        #expect(workspace.state.signalSeen.filter { $0.signal == signal.id && $0.item == item }.map(\.disposition) == [.started])

        // Act 2: the ticket is done while the worker still works, so nothing finishes.
        func snapshot(_ state: SessionState) -> DaemonEvent {
            .snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
                OperatorServiceFixtures.session("worker", window: window, tag: task.id, state: state,
                                                conversation: "journey-worker", cwd: worktree),
            ], usage: .empty))
        }
        fixture.controller.helper.handle(snapshot(.working))
        await ports.work.settled()
        status.set("Done")
        clock.advance(by: 61)
        await controller.reconcile()
        await ports.work.settled()
        #expect(workspace.state.task(id: task.id)?.signalTask?.phase == .working)
        #expect(daemon.requests("window.close").isEmpty)

        // Act 3: the worker's turn ends with no question, and the next watch archives the task.
        let transcripts = ports.claudeConfig.directory(home: ports.home).appendingPathComponent("projects/journey")
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let reply = #"{"type":"assistant","message":{"content":[{"type":"text","text":"The plan is written."}]}}"# + "\n"
        try reply.write(to: transcripts.appendingPathComponent("journey-worker.jsonl"), atomically: true, encoding: .utf8)
        fixture.controller.helper.handle(snapshot(.done))
        await ports.work.settled()
        clock.advance(by: 61)
        await controller.reconcile()
        await ports.work.settled()

        #expect(workspace.state.task(id: task.id) == nil)
        let archived = try #require(workspace.state.archived(id: task.id))
        #expect(archived.task.signalTask?.phase == .archived)
        #expect(!FileManager.default.fileExists(atPath: worktree))
        let git = fixture.git, repo = fixture.repo.path
        let branches = try await BackgroundWork.run { try git.run(["branch", "--list", branch], in: repo) }
        #expect(branches.contains(branch))
        #expect(daemon.requests("window.close").filter { $0.params["windowId"] as? String == window }.count == 1)
        #expect(workspace.state.operatorSession?.questions.contains { $0.task == task.id && $0.resolvedAt == nil } != true)
        #expect(try fixture.controller.savedWorkspace().archived(id: task.id) != nil)
    }
}
