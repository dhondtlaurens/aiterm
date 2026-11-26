import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor struct SignalFreshSessionTests {
    @Test func aScopedStatusCannotAcknowledgeCoalescedUpdatesForOtherTasks() async throws {
        var world = SignalWorld(); let signal = world.signal(), first = world.workingTask(signal: signal)
        let second = world.workingTask(signal: signal)
        let session = OperatorSession.open(createdAt: world.now, conversation: "op")
        world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("operator", window: "operator-window", tag: session.id, state: .done, conversation: "op")]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        root.native.onTurn(first); root.native.onTurn(second)
        await root.reconcile(); await ports.work.settled()
        #expect(h.workspace.state.operatorSession?.lifecycle.wake == .sent)
        root.handle(.operatorRequest(.init(requestId: "scoped", operatorId: session.id.uuidString, tool: "run_status",
            arguments: ["task": .string(first.uuidString)], generation: 1)))
        await ports.work.settled()
        #expect(h.workspace.state.operatorSession?.lifecycle.wake == .sent)
        #expect((daemon.requests("operator.reply").last?.params["error"] as? String)?.contains("without task") == true)
        let recorded = ActivityLogReader.read(folder: OperatorLaunch.folder(home: ports.home)).entries.last { $0.tool == "run_status" }
        #expect(recorded?.outcome != .ok && recorded?.result.contains("without task") == true)
        root.handle(.operatorRequest(.init(requestId: "all", operatorId: session.id.uuidString, tool: "run_status", arguments: [:], generation: 1)))
        await ports.work.settled()
        let result = daemon.requests("operator.reply").last?.params["result"] as? JSONValue
        #expect(result?["tasks"]?.arrayValue?.count == 2)
        #expect(h.workspace.state.operatorSession?.lifecycle == .open(since: world.now, wake: nil))
        root.stop()
    }
    @Test(arguments: [DeliveryCode?.some(.unsentInput), .some(.itermRefused), .some(.sessionClosed), .some(.unknown), nil])
    func freshCloseOnlyRollsBackForAKnownRefusalBeforeTheCloseWasAttempted(code: DeliveryCode?) async throws {
        var world = SignalWorld(); let signal = world.signal(); _ = world.workingTask(signal: signal)
        let session = OperatorSession.open(createdAt: world.now, conversation: "op"); world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon()
        var ports = OperatorPorts.scratch(); defer { try? FileManager.default.removeItem(at: ports.home) }
        let now = world.now; ports.clock.now = { now }
        var tab = OperatorServiceFixtures.session("operator", window: "operator-window", tag: session.id, state: .done, conversation: "op")
        tab.contextTokens = 10_000; live.sessions = [tab]
        daemon.idleClosures = [Delivery(result: .refused, reason: "Idle close refused.", code: code)]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        tab.contextTokens = 150_000; live.sessions = [tab]
        await root.reconcile(); await ports.work.settled()
        let certain = code == .unsentInput
        // A deferred close puts the chat back open, saved; any other refusal leaves the renewal's close for the next pass.
        #expect(try h.file.load().operatorSession?.lifecycle == (certain ? .open(since: now, wake: nil) : .closing(then: .renew)))
        #expect(h.workspace.state.operatorSession?.generation == 1 && h.workspace.state.operatorSession?.window == "operator-window")
        #expect(daemon.requests("operator.revoke").isEmpty)
        let answer = await root.tools.respond(.init(requestId: "reply", operatorId: session.id.uuidString, tool: "run_status", arguments: [:], generation: 1))
        #expect((answer.message == nil) == certain)
        root.stop(); await ports.work.settled()
    }
    @Test func oracleChecksReadStandingInstructionsAndDiscardAnAnswerWhenTheyChange() async throws {
        var world = SignalWorld(); world.state.operatorSession = OperatorSession(createdAt: world.now)
        let h = try SignalHarness(world); defer { h.cleanUp() }; var ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }; nonisolated(unsafe) let defaults = ports.preferences
        let profile = OperatorProfile(model: "opus", reasoning: "high", oracle: .init(isOn: true, agent: .claude, model: "oracle", reasoning: nil), instructions: "Never move tickets to Done.")
        OperatorProfileStore.save(profile, defaults); ports.profile = { profile }
        ports.oracle = OracleRunner(locate: { _ in "/synthetic/claude" }, run: { _, arguments, _, _, _ in
            #expect(arguments.joined(separator: " ").contains(profile.instructions))
            await MainActor.run { var changed = profile; changed.instructions = "Ask before any merge."; OperatorProfileStore.save(changed, defaults) }
            return ProcessOutput(status: 0, stdout: #"{"result":"YES"}"#, stderr: "", timedOut: false)
        })
        let root = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace), work: WorkInFlight(), ports: ports,
            daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.start(); await ports.work.settled()
        let session = try #require(h.workspace.state.operatorSession)
        let answer = await root.gate.respond(.init(requestId: "shell", operatorId: session.id.uuidString, tool: "gate_command",
            arguments: ["command": "./deploy", "directory": .string(h.folder.path)], generation: session.generation))
        #expect(answer["decision"] == "deny")
        root.stop(); await ports.work.settled()
    }
    @Test func aLostCloseReplyCanFinishItsSavedHandoverAfterRestart() async throws {
        var world = SignalWorld(); var session = OperatorSession(createdAt: world.now)
        session.window = "already-closed"; session.lifecycle = .closing(then: .renew)
        world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let root = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace), work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.tabsKnown = true; root.sourceRegistrations = { _ in [] }
        root.start(); await ports.work.settled()
        #expect(h.workspace.state.operatorSession?.generation == 2)
        #expect(h.workspace.state.operatorSession?.lifecycle == .idle)
        #expect(daemon.requests("window.close").isEmpty, "A missing window must be confirmed, never closed by an old number.")
        #expect(daemon.requests("window.createTask").isEmpty, "A recovered handover with no workload retires without opening another chat.")
        root.stop()
    }
    @Test func nativeHandoverClosesRevokesAndOpensOnOneLineWithTheSavedStatus() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        var session = OperatorSession.open(createdAt: world.now, window: "old-window", conversation: "old-conversation")
        session.questions = [.init(id: "scope", task: id, text: "Which scope?", openedAt: world.now)]
        session.oracleRounds = [OracleRound(id: "waiting-round", tool: "answer_worker", stage: .delivered,
                                            critique: "Check the original scope before answering.", askedAt: world.now)]
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
        let folder = OperatorLaunch.folder(home: ports.home)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let text = try files.filter { $0.pathExtension == "json" || $0.pathExtension == "md" }.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        #expect(!text.contains("old-conversation"))
        // The fresh chat opens on one line; its first run_status reads the question and round the renewal kept.
        #expect(try String(contentsOf: folder.appendingPathComponent(OperatorLaunch.firstMessageFile), encoding: .utf8) == OperatorLaunch.firstMessage)
        let status = OperatorDigest(state: h.workspace.state, at: now, oracleOn: true)
        #expect(status.questions.map(\.id) == ["scope"] && status.oracleRounds.map(\.id) == ["waiting-round"])
        root.stop()
    }
    @Test(arguments: [false, true]) func anOracleOffOnCycleDiscardsTheEarlierAnswer(shell: Bool) async throws {
        var world = SignalWorld(); world.state.operatorSession = OperatorSession(createdAt: world.now)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var ports = OperatorPorts.scratch(); defer { try? FileManager.default.removeItem(at: ports.home) }
        nonisolated(unsafe) let defaults = ports.preferences
        let profile = OperatorProfile(model: "opus", reasoning: "high", oracle: .init(isOn: true, agent: .claude, model: "oracle", reasoning: nil))
        OperatorProfileStore.save(profile, defaults)
        ports.profile = { profile }
        ports.oracle = OracleRunner(locate: { _ in "/synthetic/claude" }, run: { _, _, _, _, _ in
            await MainActor.run {
                var changed = profile; changed.oracle.isOn = false
                OperatorProfileStore.save(changed, defaults)
                OperatorProfileStore.save(profile, defaults)
            }
            return ProcessOutput(status: 0, stdout: #"{"result":"YES"}"#, stderr: "", timedOut: false)
        })
        let root = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace), work: WorkInFlight(), ports: ports,
            daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.start(); await ports.work.settled()
        let session = try #require(h.workspace.state.operatorSession)
        let request = OperatorRequest(requestId: "opinion", operatorId: session.id.uuidString,
            tool: shell ? "gate_command" : "ask_oracle", arguments: shell
                ? ["command": "./deploy", "directory": .string(h.folder.path)]
                : ["key": "check", "question": "Is this sound?", "context": "Inspect the current head."], generation: 1)
        if shell { #expect(await root.gate.respond(request)["decision"] == "deny") }
        else { #expect(await root.tools.respond(request).value?["status"] == "retry") }
        root.stop(); await ports.work.settled()
    }
    @Test func acceptingAWakeDoesNotMakeItsStillIdleSnapshotSafeToRotate() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let session = OperatorSession.open(createdAt: world.now, conversation: "op")
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
        root.handle(.operatorRequest(.init(requestId: "read", operatorId: session.id.uuidString, tool: "run_status", arguments: [:], generation: 1)))
        await ports.work.settled(); await root.reconcile(); await ports.work.settled()
        #expect(!daemon.requests("session.closeIdle").isEmpty)
        root.stop()
    }
}
