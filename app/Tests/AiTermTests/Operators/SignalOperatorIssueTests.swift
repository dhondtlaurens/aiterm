import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// The Operator row says "needs you" only while an issue needs the person: one issue per source,
/// cleared by that source's own next success, logged and reported in run_status.
@MainActor @Suite struct SignalOperatorIssueTests {
    @MainActor final class Rig {
        let world: SignalWorld, h: SignalHarness, task: UUID, session: OperatorSession
        let live: LiveSessions, daemon = RecordingDaemon(), ports: OperatorPorts, root: SignalOperatorController
        init() async throws {
            var world = SignalWorld(); let signal = world.signal(); task = world.workingTask(signal: signal)
            var session = OperatorSession(createdAt: world.now); session.window = "operator-window"; session.conversation = "op"
            world.state.operatorSession = session
            self.world = world; self.session = session
            h = try SignalHarness(world)
            live = LiveSessions(workspace: h.workspace)
            var ports = OperatorPorts.scratch(); let now = world.now; ports.clock.now = { now }; self.ports = ports
            live.sessions = [OperatorServiceFixtures.session("operator", window: "operator-window", tag: session.id, state: .done, conversation: "op")]
            root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
                daemon: { [daemon] in daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
            root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        }
        func cleanUp() { root.stop(); h.cleanUp(); try? FileManager.default.removeItem(at: ports.home) }
        var row: SignalOperatorRowValue { SignalOperatorRowValue.make(state: h.workspace.state, sessions: live.sessions, issue: root.statusIssue) }
        func pass() async { await root.reconcile(); await ports.work.settled() }
        func request(_ tool: String, _ arguments: JSONValue = [:], id: String = UUID().uuidString) async {
            root.handle(.operatorRequest(.init(requestId: id, operatorId: session.id.uuidString, tool: tool, arguments: arguments, generation: 1)))
            await ports.work.settled()
        }
        var activity: [ActivityEntry] { ActivityLog.read(folder: OperatorLaunch.folder(home: ports.home)).entries }
    }

    @Test func aWakeThatKeepsFailingNeedsYouAndTheNextDeliveredWakeClearsItWithoutOpeningAWindow() async throws {
        let r = try await Rig(); defer { r.cleanUp() }
        r.daemon.failing["session.deliver"] = .timeout
        r.root.native.onTurn(r.task)
        await r.pass(); await r.pass()
        #expect(r.row.line.look != .needsYou, "Two failures are still AiTerm's to retry.")
        await r.pass()
        #expect(r.row.line.text == "needs you" && r.row.line.tooltip.hasPrefix("Waking the Operator:"))
        r.daemon.failing = [:]
        await r.pass()
        #expect(r.row.line.text == "watching 1 task in 1 signal" && r.root.statusIssue == nil)
        #expect(r.daemon.requests("window.activate").isEmpty)
        let logged = r.activity.filter { $0.tool == "app_issue" }
        #expect(logged.map(\.line) == ["Waking the Operator failed.", "Waking the Operator recovered."])
    }

    @Test func notNowRefusalsWaitButARefusedLineAndAnUnsentWakeCount() async throws {
        let r = try await Rig(); defer { r.cleanUp() }
        r.daemon.deliveries = [Delivery(result: .refused, reason: "the person is typing", code: .typing)]
        r.root.native.onTurn(r.task)
        for _ in 0..<4 { await r.pass() }
        #expect(r.root.issues.current.isEmpty, "Typing is not a failure.")
        r.daemon.deliveries = [Delivery(result: .partial, reason: "Enter held", code: nil),
                               Delivery(result: .refused, reason: "unsent input", code: .unsentInput)]
        for _ in 0..<3 { await r.pass() }
        #expect(r.root.statusIssue?.contains("Send or clear it there") == true)
        await r.request("run_status")
        #expect(r.root.statusIssue == nil, "The Operator's global read acknowledges the wake the person sent.")
        r.root.native.onTurn(r.task)
        r.daemon.deliveries = [Delivery(result: .refused, reason: "a wake line may not carry a digit", code: .wakeText)]
        for _ in 0..<3 { await r.pass() }
        #expect(r.root.statusIssue?.contains("may not carry a digit") == true)
    }

    @Test func aWakeWhoseReplyWasLostCountsTheTextItMayHaveLeftInTheChat() async throws {
        let r = try await Rig(); defer { r.cleanUp() }
        r.daemon.failing["session.deliver"] = .timeout
        r.root.native.onTurn(r.task)
        await r.pass()
        r.daemon.failing = [:]
        r.daemon.deliveries = [Delivery(result: .refused, reason: "unsent input", code: .unsentInput)]
        await r.pass(); await r.pass()
        #expect(r.root.statusIssue?.contains("Send or clear it there") == true)
    }
    @Test func aRelaunchWithAnUnreadWakeCountsTheTextLeftInTheChat() async throws {
        var world = SignalWorld(); let signal = world.signal(); _ = world.workingTask(signal: signal)
        var session = OperatorSession(createdAt: world.now); session.window = "operator-window"; session.conversation = "op"
        session.wakeAwaitingRead = true; world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon()
        var ports = OperatorPorts.scratch(); defer { try? FileManager.default.removeItem(at: ports.home) }
        let now = world.now; ports.clock.now = { now }
        live.sessions = [OperatorServiceFixtures.session("operator", window: "operator-window", tag: session.id, state: .done, conversation: "op")]
        daemon.deliveries = [Delivery(result: .refused, reason: "unsent input", code: .unsentInput)]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        for _ in 0..<3 { await root.reconcile(); await ports.work.settled() }
        #expect(root.statusIssue?.contains("Send or clear it there") == true)
        root.stop()
    }
    @Test func twoSourcesFailingAndOneRecoveringKeepsTheOther() async throws {
        let r = try await Rig(); defer { r.cleanUp() }
        r.daemon.failing = ["session.deliver": .timeout, "operator.reply": .timeout]
        r.root.native.onTurn(r.task)
        for _ in 0..<3 {
            await r.pass()
            await r.request("run_status", ["task": .string(r.task.uuidString)])
        }
        #expect(Set(r.root.issues.current.filter(\.needsYou).map(\.source)) == [.wake, .reply])
        r.daemon.failing = ["operator.reply": .timeout]
        await r.pass()
        #expect(r.root.issues.current.map(\.source) == [.reply] && r.root.statusIssue?.hasPrefix("Answering the Operator:") == true)
        let status = await r.root.tools.respond(OperatorRequest(requestId: "s", operatorId: r.session.id.uuidString, tool: "run_status", arguments: [:], generation: 1))
        let issue = try #require(status.value?["appIssues"]?.arrayValue?.first)
        #expect(issue["source"] == "reply" && issue["needsYou"] == true && issue["text"]?.stringValue?.contains("could not be sent") == true)
    }

    @Test func aFailedReplyClearsWhenTheOperatorsRetryOfTheSameKeyIsAnsweredWithoutASecondEffect() async throws {
        let r = try await Rig(); defer { r.cleanUp() }
        let note: JSONValue = ["task": .string(r.task.uuidString), "stage": 1, "ownership": 0, "key": "n", "text": "Use the retry key."]
        r.daemon.failing = ["operator.reply": .timeout]
        await r.request("note", note)
        await r.request("note", note)
        #expect(r.root.issues.current.first?.attempts == 2 && r.root.statusIssue == nil, "Two failed replies are not yet the person's.")
        r.daemon.failing = [:]
        await r.request("note", note)
        #expect(r.root.issues.current.isEmpty)
        let notes = try TaskJournal.read(task: r.task, folder: OperatorLaunch.folder(home: r.ports.home).appendingPathComponent("journals"))
        #expect(notes.count == 1, "The ledger replays the note instead of writing it again.")
        r.daemon.failing = ["operator.reply": .timeout]
        for _ in 0..<3 { await r.request("run_status") }
        #expect(r.root.statusIssue?.hasPrefix("Answering the Operator:") == true, "Three failed replies across calls need the person.")
    }

    @Test func aFailedActivityWriteIsReportedAndTheNextWrittenEntryClearsIt() async throws {
        let r = try await Rig(); defer { r.cleanUp() }
        let log = OperatorLaunch.folder(home: r.ports.home).appendingPathComponent(ActivityLog.file)
        try? FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        r.daemon.failing["session.deliver"] = .timeout
        r.root.native.onTurn(r.task)
        await r.pass()
        #expect(r.root.issues.current.map(\.source).contains(.activity))
        try FileManager.default.removeItem(at: log)
        await r.request("run_status")
        let logged = r.activity.filter { $0.tool == "app_issue" }.map(\.line)
        #expect(r.activity.contains { $0.tool == "run_status" })
        #expect(logged.contains("The Operator's activity log recovered."))
        #expect(!logged.contains("The Operator's activity log failed."))
        #expect(!logged.contains("Waking the Operator failed."), "The failed entry is dropped.")
        #expect(!r.root.issues.current.map(\.source).contains(.activity))
        r.daemon.failing = [:]
        await r.pass()
        #expect(r.activity.contains { $0.line == "Waking the Operator recovered." })
    }

    @Test func aTakeOverWhoseJournalCannotBeWrittenShowsAtOnce() async throws {
        let r = try await Rig(); defer { r.cleanUp() }
        let journals = OperatorLaunch.folder(home: r.ports.home).appendingPathComponent("journals")
        try? FileManager.default.removeItem(at: journals)
        try FileManager.default.createDirectory(at: journals.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: journals)
        await r.root.takeOver(r.task); await r.ports.work.settled()
        #expect(r.root.statusIssue?.hasPrefix("Take Over:") == true)
        await r.root.openOperator()
        #expect(r.daemon.requests("window.createTask").isEmpty, "A Take Over issue without work must not start a throwaway chat.")
        try FileManager.default.removeItem(at: journals)
        await r.pass()
        #expect(r.root.statusIssue?.hasPrefix("Take Over:") == true)
        #expect(try !TaskJournal.read(task: r.task, folder: journals).contains { $0.text == .ours("The person took over this task.") })
    }

    @Test func aRetiredChatDoesNotKeepItsOldReplyFailureOrReappearFromAStaleSnapshot() async throws {
        let r = try await Rig(); defer { r.cleanUp() }
        r.daemon.failing["operator.reply"] = .timeout
        for _ in 0..<3 { await r.request("run_status") }
        #expect(r.root.statusIssue?.hasPrefix("Answering the Operator:") == true)
        r.h.workspace.mutate { $0.updateSignalTask(r.task) { $0.phase = .done; $0.thenApplied = true } }
        await r.pass(); await r.pass()
        #expect(r.h.workspace.state.operatorSession?.window == nil)
        #expect(r.root.statusIssue == nil && !r.row.shown)
        #expect(r.root.operatorTab() == nil, "The old snapshot still lists the closed tab.")
        #expect(r.daemon.requests("window.createTask").isEmpty)
        for _ in 0..<3 { await r.request("run_status") }
        #expect(r.root.statusIssue == nil && !r.row.shown, "Late reply failures from the retired generation cannot recreate attention.")
    }
}
