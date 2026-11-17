import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// Every Oracle use goes through one consult: settings changed mid-check is retry, and only finished rounds are saved.
@MainActor @Suite struct OracleConsultTests {
    private static let question = OracleLaunch.Question.workerAnswer(question: "Which key?", workerMessage: "Question: Which key?",
                                                                     proposal: "Use A.", brief: "")
    private static func binding(_ claim: SignalClaim?, proposal: String = "Use A.") -> OracleConsult.Binding {
        .init(claim: claim, round: .init(key: "bound", arguments: "{}", proposal: proposal))
    }
    private func rig() throws -> (SignalHarness, SignalClaim, SignalWorld) {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world)
        return (h, try #require(world.state.task(id: id).flatMap(SignalClaim.init)), world)
    }
    private func rounds(_ h: SignalHarness) -> [OracleRound] { h.workspace.state.operatorSession?.oracleRounds ?? [] }

    @Test func aCritiqueIsSavedAsARoundTheNextProposalContinues() async throws {
        let (h, claim, world) = try rig(); defer { h.cleanUp() }
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .critique("NO: use B.") }
        let first = await oracle.consult.consult(Self.question, binding: Self.binding(claim))
        guard case .critique(let text, 1, let id?) = first else { Issue.record("Expected a saved critique, got \(first)"); return }
        #expect(text == "NO: use B.")
        let saved = try #require(oracle.consult.saved(tool: "answer_worker", key: "bound"))
        #expect(saved.id == id && saved.stage == .delivered && saved.round == 1 && saved.critique == "NO: use B." && saved.reply == "Use A.")
        #expect(OracleConsult.discussion(of: saved) == ["Operator: Use A.", "Oracle: NO: use B."])
        let second = await oracle.consult.consult(Self.question, binding: Self.binding(claim, proposal: "Use B."), continuing: saved)
        guard case .critique(_, 2, let next?) = second else { Issue.record("Expected round two, got \(second)"); return }
        #expect(try oracle.quoted(1)["discussion"] == ["Operator: Use A.", "Oracle: NO: use B."])
        #expect(rounds(h).map(\.id) == [next] && rounds(h).first?.round == 2)
        #expect(OracleConsult.discussion(of: rounds(h).first).count == 4)
    }

    @Test func aThirdCritiqueReturnsNoIdAndLeavesNothingSaved() async throws {
        let (h, claim, world) = try rig(); defer { h.cleanUp() }
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .critique("NO") }
        var previous: OracleRound?
        for round in 1...3 {
            let outcome = await oracle.consult.consult(Self.question, binding: Self.binding(claim), continuing: previous)
            if round < 3 {
                guard case .critique(_, round, let id?) = outcome else { Issue.record("Round \(round): \(outcome)"); return }
                previous = rounds(h).first { $0.id == id }
            } else { #expect(outcome == .critique("NO", round: 3, challengeId: nil)) }
        }
        #expect(rounds(h).isEmpty)
    }

    @Test func agreementRemovesTheRoundItContinued() async throws {
        let (h, claim, world) = try rig(); defer { h.cleanUp() }
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .critique("NO") }
        _ = await oracle.consult.consult(Self.question, binding: Self.binding(claim))
        let saved = try #require(rounds(h).first)
        oracle.answer = { _ in .critique("YES, sound.") }
        #expect(await oracle.consult.consult(Self.question, binding: Self.binding(claim), continuing: saved) == .agreed("YES, sound.", round: 2))
        #expect(rounds(h).isEmpty)
    }

    enum Change: CaseIterable { case setting, instructions, revision, stopped }

    @Test(arguments: Change.allCases) func settingsChangedWhileItReadIsRetryForEveryUse(change: Change) async throws {
        let (h, claim, world) = try rig(); defer { h.cleanUp() }
        let status = OperatorDigest(state: h.workspace.state, at: world.now, oracleOn: true)
        let uses: [OracleLaunch.Question] = [Self.question,
            .agentChoice(.init(forTab: false, item: "PAY-1", title: "t", stagePrompt: "p", work: nil, project: .gone(UUID()), candidateProjects: nil,
                               permittedRows: [SignalWorld.agent], row: SignalWorld.agent, reason: "r", weeklyUsage: [:], installed: [])),
            .mergeVeto(head: "abc", status: status), .secondOpinion(question: "q", context: "c"),
            .shellGate(command: "./deploy", directory: "/w", reason: nil, status: status)]
        for use in uses {
            let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .critique("NO") }
            var previous: OracleRound?
            if use.tool != nil {
                _ = await oracle.consult.consult(use, binding: Self.binding(claim))
                previous = try #require(rounds(h).first)
            }
            oracle.answer = { [unowned oracle] _ in
                switch change {
                case .setting: oracle.settings.oracle.model = "another"
                case .instructions: oracle.settings.instructions = "Ask before any merge."
                case .revision: oracle.settings.revision += 1
                case .stopped: oracle.running = false
                }
                return .critique("YES")
            }
            #expect(await oracle.consult.consult(use, binding: Self.binding(claim), continuing: previous) == .retry)
            #expect(rounds(h).isEmpty, "Nothing is saved, and the round it continued is gone.")
        }
    }

    @Test func anOracleSwitchedOffAndOnWhileItReadIsRetry() async throws {
        let (h, claim, world) = try rig(); defer { h.cleanUp() }
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now })
        oracle.answer = { [unowned oracle] _ in oracle.settings.oracle.isOn = false; oracle.settings.revision += 1; oracle.settings.oracle.isOn = true; oracle.settings.revision += 1; return .critique("YES") }
        #expect(await oracle.consult.consult(Self.question, binding: Self.binding(claim)) == .retry)
    }

    @Test func offOrStoppedIsUnavailableWithoutRunning() async throws {
        let (h, claim, world) = try rig(); defer { h.cleanUp() }
        let off = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }, on: false)
        #expect(await off.consult.consult(Self.question, binding: Self.binding(claim)) == .unavailable(.off))
        let stopped = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }); stopped.running = false
        #expect(await stopped.consult.consult(.secondOpinion(question: "q", context: "c"), binding: .none) == .unavailable(.off))
        #expect(off.prompts.isEmpty && stopped.prompts.isEmpty)
    }

    @Test func aRunnerFailureAndAnUnclearReplyAreUnavailable() async throws {
        let (h, claim, world) = try rig(); defer { h.cleanUp() }
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .unanswered("The Oracle didn’t answer within 5 minutes.") }
        #expect(await oracle.consult.consult(Self.question, binding: Self.binding(claim)) == .unavailable(.failed("The Oracle didn’t answer within 5 minutes.")))
        oracle.answer = { _ in .critique("Hard to say.") }
        #expect(await oracle.consult.consult(Self.question, binding: Self.binding(claim)) == .unavailable(.unclear("The Oracle gave no clear agreement.")))
        oracle.answer = { _ in .critique("PERSON: a product decision.") }
        #expect(await oracle.consult.consult(Self.question, binding: Self.binding(claim)) == .person("PERSON: a product decision."))
        #expect(rounds(h).isEmpty)
    }

    @Test func aHeldCheckSavesNothingAndIsNotIdle() async throws {
        let (h, claim, world) = try rig(); defer { h.cleanUp() }
        let entered = TestLatch(), release = TestLatch()
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in entered.signal(); await release.wait(); return .critique("NO") }
        #expect(oracle.consult.isIdle)
        let before = rounds(h)
        let check = Task { await oracle.consult.consult(Self.question, binding: Self.binding(claim)) }
        await entered.wait()
        #expect(rounds(h) == before && !oracle.consult.isIdle)
        #expect(oracle.prompts.first?.hasPrefix("Standing instructions from the person, which apply to this check:\nYou are careful.\n\n") == true)
        release.signal()
        if case .critique(_, 1, _?) = await check.value {} else { Issue.record("Expected a saved critique") }
        #expect(oracle.consult.isIdle && rounds(h).count == 1)
    }

    @Test func aClaimThatChangedWhileItReadSavesNothing() async throws {
        let (h, claim, world) = try rig(); defer { h.cleanUp() }
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .critique("NO") }
        _ = await oracle.consult.consult(Self.question, binding: Self.binding(claim))
        let saved = try #require(rounds(h).first)
        oracle.answer = { _ in h.workspace.mutate { $0.takeOver(claim.task) }; return .critique("NO, again.") }
        let outcome = await oracle.consult.consult(Self.question, binding: Self.binding(claim), continuing: saved)
        #expect(outcome == .critique("NO, again.", round: 2, challengeId: nil))
        #expect(rounds(h) == [saved], "Nothing new is saved for a task that changed hands.")
    }
}
