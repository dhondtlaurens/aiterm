import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor struct SignalFreshSessionTests {
    @Test func aLostCloseReplyCanFinishItsSavedHandoverAfterRestart() async throws {
        var world = SignalWorld(); var session = OperatorSession(createdAt: world.now)
        session.window = "already-closed"; session.startingFresh = true; session.handover = .closing
        world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let root = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace), work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.tabsKnown = true; root.sourceRegistrations = { _ in [] }
        root.start(); await ports.work.settled()
        #expect(h.workspace.state.operatorSession?.generation == 2)
        #expect(h.workspace.state.operatorSession?.startingFresh == false)
        #expect(daemon.requests("window.close").isEmpty, "A missing window must be confirmed, never closed by an old number.")
        #expect(daemon.requests("window.createTask").count == 1)
        root.stop()
    }
    @Test func nativeHandoverClosesRevokesAndOpensWithCurrentContextAndTheSavedDigest() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        var session = OperatorSession(createdAt: world.now)
        session.window = "old-window"; session.conversation = "old-conversation"
        session.questions = [.init(id: "scope", task: id, text: "Which scope?", openedAt: world.now)]
        var round = ChallengeRecord(id: "waiting-round", tool: "answer_worker", askedArguments: "{}", askedAt: world.now)
        round.stage = .delivered; round.critique = "Check the original scope before answering."
        session.oracleRounds = [round]
        world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon()
        var ports = OperatorPorts.scratch(); defer { try? FileManager.default.removeItem(at: ports.home) }
        let now = world.now; ports.clock.now = { now }
        var tab = OperatorServiceFixtures.session("operator", window: "old-window", tag: session.id, state: .done, conversation: "old-conversation")
        tab.contextTokens = 50_000; live.sessions = [tab]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        #expect(daemon.requests("session.closeIdle").isEmpty)
        tab.contextTokens = 150_000; live.sessions = [tab]
        await root.reconcile(); await ports.work.settled()
        let names = daemon.requests.map(\.method)
        let close = try #require(names.firstIndex(of: "session.closeIdle")), revoke = try #require(names.firstIndex(of: "operator.revoke"))
        let open = try #require(names.firstIndex(of: "window.createTask"))
        #expect(close < revoke && revoke < open)
        #expect(h.workspace.state.operatorSession?.generation == 2)
        let folder = SignalOperatorCommand.folder(home: ports.home)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let text = try files.filter { $0.pathExtension == "json" || $0.pathExtension == "md" }.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        #expect(text.contains("Which scope?") && text.contains("waiting-round"))
        #expect(!text.contains("old-conversation"))
        root.stop()
    }
    @Test(arguments: [false, true]) func anOracleOffOnCycleDiscardsTheEarlierAnswer(shell: Bool) async throws {
        var world = SignalWorld(); world.state.operatorSession = OperatorSession(createdAt: world.now)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var ports = OperatorPorts.scratch(); defer { try? FileManager.default.removeItem(at: ports.home) }
        nonisolated(unsafe) let defaults = ports.preferences
        let profile = OperatorProfile(model: "opus", reasoning: "high", oracle: .init(isOn: true, agent: .claude, model: "oracle", reasoning: nil))
        try OperatorProfileStore.save(profile, defaults)
        ports.profile = { profile }
        ports.secondOpinion = SecondOpinionRunner(locate: { _ in "/synthetic/claude" }, run: { _, _, _, _, _ in
            try await MainActor.run {
                var changed = profile; changed.oracle.isOn = false
                try OperatorProfileStore.save(changed, defaults)
                try OperatorProfileStore.save(profile, defaults)
            }
            return ProcessOutput(status: 0, stdout: #"{"result":"YES"}"#, stderr: "", timedOut: false)
        })
        let root = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace), work: WorkInFlight(), ports: ports,
            daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.start(); await ports.work.settled()
        let session = try #require(h.workspace.state.operatorSession)
        let request = OperatorRequest(requestId: "opinion", runId: session.id.uuidString,
            tool: shell ? "gate_command" : "ask_oracle", arguments: shell
                ? ["command": "./deploy", "directory": .string(h.folder.path)]
                : ["key": "check", "question": "Is this sound?", "context": "Inspect the current head."], generation: 1)
        if shell { #expect(await root.gate.respond(request)["decision"] == "deny") }
        else { #expect(await root.tools.respond(request).value?["status"] == "ask_you") }
        root.stop(); await ports.work.settled()
    }
    @Test func acceptingAWakeDoesNotMakeItsStillIdleSnapshotSafeToRotate() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        var session = OperatorSession(createdAt: world.now); session.window = "operator-window"; session.conversation = "op"
        world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon()
        var ports = OperatorPorts.scratch(); defer { try? FileManager.default.removeItem(at: ports.home) }
        let now = world.now; ports.clock.now = { now }
        var tab = OperatorServiceFixtures.session("operator", window: "operator-window", tag: session.id, state: .done, conversation: "op")
        live.sessions = [tab]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        tab.contextTokens = 150_000; live.sessions = [tab]
        root.native.onTurn(id)
        await root.reconcile(); await ports.work.settled()
        #expect(!daemon.requests("session.deliver").isEmpty)
        #expect(daemon.requests("session.closeIdle").isEmpty, "The delivered wake has not been read yet.")
        root.handle(.operatorRequest(.init(requestId: "read", runId: session.id.uuidString, tool: "run_status", arguments: [:], generation: 1)))
        await ports.work.settled(); await root.reconcile(); await ports.work.settled()
        #expect(!daemon.requests("session.closeIdle").isEmpty)
        root.stop()
    }
}
