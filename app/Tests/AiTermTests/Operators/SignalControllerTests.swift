import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalControllerTests {
    @Test func oneControllerStartsOnePersistentOperatorAndServesSignalStatus() async throws {
        var world = SignalWorld(); _ = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        let controller = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        controller.tabsKnown = true
        controller.start()
        await ports.work.settled()
        await controller.reconcile()
        await controller.reconcile()
        let session = try #require(h.workspace.state.operatorSession)
        #expect(daemon.requests("operator.register").contains { $0.params["generation"] as? Int == session.generation })
        #expect(daemon.requests("window.createTask").count == 1)
        controller.handle(.operatorRequest(OperatorRequest(requestId: "status", runId: session.id.uuidString,
            tool: "run_status", arguments: [:], generation: session.generation)))
        await ports.work.settled()
        let reply = try #require(daemon.requests("operator.reply").last)
        #expect(reply.params["error"] == nil)
        #expect((reply.params["result"] as? JSONValue)?["signals"]?.arrayValue?.count == 1)
        controller.stop()
        try? FileManager.default.removeItem(at: ports.home)
    }
    @Test func aStaleShellRequestGetsARealGateDenialAndNeverAGenericToolError() async throws {
        var world = SignalWorld(); world.state.operatorSession = OperatorSession(createdAt: world.now)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        let controller = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        controller.start(); await ports.work.settled()
        controller.handle(.operatorRequest(OperatorRequest(requestId: "gate", runId: world.state.operatorSession!.id.uuidString,
            tool: "gate_command", arguments: ["command": "cat README.md", "directory": .string(h.folder.path)], generation: 0)))
        await ports.work.settled()
        let reply = try #require(daemon.requests("operator.reply").last)
        #expect((reply.params["result"] as? JSONValue)?["decision"] == "deny")
        #expect(reply.params["error"] == nil)
        controller.stop()
    }
    @Test func toolsAndSkippedItemsKeepTheirOnDiskActivityWithoutABoard() async throws {
        var world = SignalWorld(); let signal = world.signal()
        world.state.operatorSession = OperatorSession(createdAt: world.now)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let controller = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace),
            work: WorkInFlight(), ports: ports, daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        let session = try #require(h.workspace.state.operatorSession)
        _ = await controller.tools.respond(OperatorRequest(requestId: "status", runId: session.id.uuidString,
            tool: "run_status", arguments: [:], generation: session.generation))
        _ = controller.router.apply(signals: [signal], read: SignalRead(items: [world.ticket("NOPE-1")], complete: true, full: true))
        await ports.work.settled()
        let entries = ActivityLog.read(runFolder: SignalOperatorCommand.folder(home: ports.home)).entries
        #expect(Set(entries.map(\.tool)) == ["run_status", "signal_match"])
        #expect(entries.contains { $0.line.contains("NOPE-1") && $0.line.contains("No project") })
        #expect(h.workspace.state.tasks.isEmpty)
    }

}
