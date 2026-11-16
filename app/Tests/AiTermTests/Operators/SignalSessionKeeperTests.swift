import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct SignalSessionKeeperTests {
    @Test func anIdleSessionSavesItsNextOpeningBeforeCallingTheDaemon() async throws {
        var world = SignalWorld(); let signal = world.signal(); _ = world.workingTask(signal: signal)
        world.state.operatorSession?.generation = 2
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let keeper = OperatorSessionKeeper(workspace: h.workspace, now: { world.now }, oracleOn: { true }, ports: .init(
            canOpen: { true }, windowIsOpen: { $0.window != nil }, close: { _ in }, revoke: { _ in }, open: { session, _ in
                let saved = try h.file.load().operatorSession
                #expect(session.generation == 2 && saved?.generation == 2)
                #expect(saved?.startingFresh == true && saved?.handover == .opening)
                throw ActionUnavailable("The opening reply was lost")
            }))
        await keeper.ensure()
        #expect(h.workspace.state.operatorSession?.handover == .opening)
    }

    @Test func retirementAdoptsAnUnrecordedOpeningBeforeClosingAndRevoking() async throws {
        var world = SignalWorld()
        var session = OperatorSession(createdAt: world.now); session.startingFresh = true; session.handover = .opening
        world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var events: [String] = []
        let keeper = OperatorSessionKeeper(workspace: h.workspace, now: { world.now }, oracleOn: { true }, ports: .init(
            canOpen: { true }, windowIsOpen: { $0.window != nil }, close: { window in
                let saved = try h.file.load().operatorSession
                #expect(saved?.window == window && saved?.finishing == true && saved?.handover == .closing)
                events.append("close " + window)
            }, revoke: { _ in events.append("revoke") }, open: { _, _ in
                Issue.record("Recovery must adopt and retire, not create a chat"); return "unexpected"
            }, existingWindow: { saved in
                #expect(saved.id == session.id && saved.handover == .opening)
                events.append("adopt"); return "orphan-window"
            }))
        await keeper.finishIfIdle(idle: true, wakePending: false)
        #expect(events == ["adopt", "close orphan-window", "revoke"])
        #expect(h.workspace.state.operatorSession?.generation == 2 && h.workspace.state.operatorSession?.window == nil)
    }

    @Test func aRealGlobalQuestionKeepsItsChatUntilAnswered() async throws {
        var world = SignalWorld()
        var session = OperatorSession(createdAt: world.now); session.window = "question-window"
        session.questions = [.init(id: "global", task: nil, text: "Which project should future signals use?", openedAt: world.now)]
        world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var closed = 0
        let keeper = OperatorSessionKeeper(workspace: h.workspace, now: { world.now }, oracleOn: { true }, ports: .init(
            canOpen: { true }, windowIsOpen: { $0.window != nil }, close: { _ in closed += 1 }, revoke: { _ in },
            open: { _, _ in Issue.record("No chat is needed after the answer"); return "unexpected" }))
        await keeper.finishIfIdle(idle: true, wakePending: false)
        #expect(closed == 0 && SignalQuestionNotification.make(state: h.workspace.state) != nil)
        let answeredAt = world.now
        h.workspace.mutate { $0.operatorSession?.questions[0].resolvedAt = answeredAt }
        await keeper.finishIfIdle(idle: true, wakePending: false)
        #expect(closed == 1 && h.workspace.state.operatorSession?.window == nil)
    }

    @Test func retirementSurvivesAFailedRevokeAndRestartWithoutOpeningAnotherChat() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        world.state.updateSignalTask(task) { $0.phase = .done; $0.thenApplied = true }
        world.state.operatorSession?.window = "old-window"
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var events: [String] = [], fail = true
        let ports = OperatorSessionKeeper.Ports(canOpen: { true }, windowIsOpen: { $0.window != nil },
            close: { _ in events.append("close") }, revoke: { _ in
                #expect(try h.file.load().operatorSession?.finishing == true)
                if fail { throw ActionUnavailable("Revoke failed") }; events.append("revoke")
            }, open: { _, _ in Issue.record("A finished workload must not open a chat"); return "unexpected" })
        let first = OperatorSessionKeeper(workspace: h.workspace, now: { world.now }, oracleOn: { true }, ports: ports)
        await first.finishIfIdle(idle: true, wakePending: false)
        #expect(h.workspace.state.operatorSession?.handover == .revoking)
        #expect(h.workspace.state.operatorSession?.window == nil)
        fail = false; try h.workspace.load()
        let restarted = OperatorSessionKeeper(workspace: h.workspace, now: { world.now }, oracleOn: { true }, ports: ports)
        await restarted.finishIfIdle(idle: false, wakePending: true)
        #expect(events == ["close", "revoke"])
        #expect(h.workspace.state.operatorSession?.generation == 2)
        #expect(h.workspace.state.operatorSession?.finishing == nil && h.workspace.state.operatorSession?.handover == nil)
    }

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
