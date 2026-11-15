import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct SignalSessionKeeperTests {
    @Test func aFreshSessionClosesBeforeRevokingAndCarriesOpenQuestions() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        world.state.operatorSession?.window = "old-window"
        world.state.operatorSession?.conversation = "old-conversation"
        let asked = OperatorSession.Question(id: "q", task: task, text: "Choose the scope", openedAt: world.now)
        world.state.operatorSession?.questions = [asked]
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var events: [String] = []
        let keeper = OperatorSessionKeeper(workspace: h.workspace, now: { world.now }, oracleOn: { true }, ports: .init(
            canOpen: { true }, windowIsOpen: { $0.window != nil }, close: { window in events.append("close " + window) },
            revoke: { _ in events.append("revoke") }, open: { session, digest in
                events.append("open")
                #expect(session.generation == 2 && session.conversation == nil)
                #expect(digest.waitingOnYou == 1 && digest.questions.first?.id == "q")
                let saved = try h.file.load()
                #expect(saved.operatorSession?.generation == 2)
                return "fresh-window"
            }))
        await keeper.freshIfDue(contextTokens: 150_000, idle: false, wakePending: false)
        #expect(events.isEmpty)
        await keeper.freshIfDue(contextTokens: 150_000, idle: true, wakePending: true)
        #expect(events.isEmpty)
        await keeper.freshIfDue(contextTokens: 150_000, idle: true, wakePending: false)
        #expect(events == ["close old-window", "revoke", "open"])
        #expect(h.workspace.state.operatorSession?.window == "fresh-window")
        #expect(h.workspace.state.operatorSession?.startingFresh == false)
    }

    @Test func aFailedCloseKeepsTheOldTokenAndTheIntentSurvivesARestart() async throws {
        var world = SignalWorld(); let signal = world.signal(); _ = world.workingTask(signal: signal)
        world.state.operatorSession?.window = "old-window"
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var fail = true, revoked = 0, opened = 0
        let ports = OperatorSessionKeeper.Ports(canOpen: { true }, windowIsOpen: { $0.window != nil },
            close: { _ in if fail { throw ActionUnavailable("Couldn’t close") } }, revoke: { _ in revoked += 1 },
            open: { _, _ in opened += 1; return "new-window" })
        let first = OperatorSessionKeeper(workspace: h.workspace, now: { world.now }, oracleOn: { true }, ports: ports)
        await first.freshIfDue(contextTokens: 150_000, idle: true, wakePending: false)
        #expect(revoked == 0 && opened == 0)
        #expect(h.workspace.state.operatorSession?.window == "old-window" && h.workspace.state.operatorSession?.startingFresh == true)
        fail = false
        try h.workspace.load()
        let restarted = OperatorSessionKeeper(workspace: h.workspace, now: { world.now }, oracleOn: { true }, ports: ports)
        await restarted.ensure()
        #expect(revoked == 1 && opened == 1 && h.workspace.state.operatorSession?.generation == 2)
    }
}
