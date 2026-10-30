import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The current Operator's external contract, captured before the refactor. Unlike an encode/decode
/// round trip, these inputs cannot silently move together with a changed persistence implementation.
@MainActor @Suite struct OperatorCurrentContractTests {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/operator-current")

    static func load() throws -> AppState {
        try StateStore(url: folder.appendingPathComponent("state.json")).load()
    }

    @Test func currentSavedBroadcastRetainsItsWorkersReviewsAndGoal() throws {
        let state = try Self.load()
        let run = try #require(state.runs.first)
        #expect(state.runs.map(\.id) == [UUID(uuidString: "12345678-0000-4000-8000-000000000002")!])
        #expect(state.tasks.count == 4 && state.tasks.allSatisfy { $0.operated?.runId == run.id })
        #expect(state.tasks.compactMap(\.operated).flatMap(\.extraTabs).count == 6)
        #expect(state.tasks.compactMap(\.operated).flatMap(\.reviewVerdicts).count == 3)
        #expect(run.goalChecks.count == 1 && run.roundsUsed == 1)
        #expect(run.profile.oracle.isOn && run.profile.slices == Slices(jira: true, review: true, merge: true))
        #expect(run.taskSettings.end == .merge && run.goal?.extraRounds == 2)
        #expect(Set(state.tasks.compactMap { $0.operated?.state }) == [.working, .accepted, .published])
    }

    @Test func statusAndToolRepliesPreserveTheSuccessfulWorkflowAcrossRestart() async throws {
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.folder.appendingPathComponent("contract.json")))
        #expect(try await Self.journey(Self.load()) == expected)
    }

    /// Exercise the app's tool boundary with fake external observations. The publication and Oracle
    /// adapters have their own integration tests; here their recorded outcomes drive the same run.
    static func journey(_ state: AppState) async throws -> JSONValue {
        let world = try OperatorWorld(state) { ports in
            ports.clock.now = { [epoch] in epoch }
            ports.secondOpinion = .answering("YES\nThe recorded result meets the goal.")
        }
        defer { world.controller.stop() }
        let runId = try #require(state.runs.first?.id)
        let working = try #require(state.tasks.first { $0.operated?.state == .working })
        let tools = world.controller.tools
        // Fixed session identities and model labels; never connect to the installed app or daemon.
        var sessions = state.tasks.enumerated().flatMap { index, task -> [SessionInfo] in
            var first = OperatorServiceFixtures.session("main-\(index)", window: "window-\(index)", tag: task.id,
                                                        state: task.id == working.id ? .working : .done,
                                                        conversation: "conversation-\(index)", cwd: task.worktreePath)
            first.tabIndex = 0
            let extras = (task.operated?.extraTabs ?? []).enumerated().map { place, tab -> SessionInfo in
                var session = OperatorServiceFixtures.session(tab.sessionId ?? "extra-\(index)-\(place)", window: first.windowId,
                                                              tag: task.id, agent: .codex, state: .done,
                                                              conversation: tab.conversation, cwd: task.worktreePath)
                session.tabKey = tab.key
                session.tabIndex = place + 1
                return session
            }
            return [first] + extras
        }
        world.live.sessions = sessions
        var checkpoints: [String: JSONValue] = [:]
        func call(_ name: String, _ arguments: JSONValue = [:]) async -> JSONValue {
            guard let run = world.run(runId) else { return ["error": "Run disappeared"] }
            do { return ["result": try await tools.perform(ToolCall(tool: name, arguments: arguments), in: run)] }
            catch { return ["error": .string((error as? ToolRefusal)?.message ?? error.localizedDescription)] }
        }
        func status(_ name: String) async { checkpoints[name] = await call("run_status") }
        await status("working")
        checkpoints["question"] = await call("ask_you", ["key": "finish-copy", "question": "May the task finish without a code change?",
                                                          "task": .string(working.operated!.key)])
        await status("waiting-for-person")
        checkpoints["answer"] = await call("resolve_question", ["key": "finish-copy", "summary": "Yes, its existing implementation is correct."])
        checkpoints["unknown-tab"] = await call("read_task", ["task": .string(working.operated!.key), "what": "lastMessage", "tab": "missing"])
        world.workspace.mutate { $0.updateRun(id: runId) { $0.intent = .paused } }
        checkpoints["paused-write"] = await call("mark_task", ["task": .string(working.operated!.key), "outcome": "noChange"])
        await status("paused")
        world.workspace.mutate { $0.updateRun(id: runId) { $0.intent = nil } }
        for i in sessions.indices { sessions[i].state = .done }
        world.live.sessions = sessions
        checkpoints["no-change"] = await call("mark_task", ["task": .string(working.operated!.key), "outcome": "noChange"])
        // The fake host reports the already-accepted task as merged. No git or host write occurs.
        world.workspace.mutate { state in
            for task in state.tasks where task.operated?.state == .accepted {
                state.updateOperated(task.id) { $0.state = .published; $0.publication = TaskPublication(merged: true, mergedSHA: "bbbbbbb") }
            }
        }
        world.controller.runChanged(runId)
        await status("goal-due")
        let missing: JSONValue = ["met": false, "evidence": "One final verification remains.", "missing": ["Verify the release."]]
        tools.vettedCalls.insert(OperatorToolHandler.invocation(ToolCall(tool: "check_goal", arguments: missing)))
        checkpoints["plan-more"] = await call("check_goal", missing)
        await status("additional-round")
        let met: JSONValue = ["met": true, "evidence": "The release is verified; no more task is needed."]
        tools.vettedCalls.insert(OperatorToolHandler.invocation(ToolCall(tool: "check_goal", arguments: met)))
        checkpoints["goal-met"] = await call("check_goal", met)
        world.controller.runChanged(runId)
        checkpoints["summary"] = await call("write_summary", ["text": "All planned work is merged and verified."])
        await status("complete")
        #expect(world.workspace.flush())
        let restored = try world.workspace.file.load()
        let restarted = try OperatorWorld(restored) { $0.clock.now = { [epoch] in epoch } }
        defer { restarted.controller.stop() }
        restarted.live.sessions = sessions
        checkpoints["after-restart"] = try restarted.controller.tools.currentStatus(of: #require(restored.runs.first)).map(JSONValue.init(encoding:))
        return .object(checkpoints)
    }
}
