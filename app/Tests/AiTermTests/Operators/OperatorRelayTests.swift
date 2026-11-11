import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// `relay_question` (B2, C2): a worker's question reaches the person only when the Operator relays it, in the worker's
/// own words, read from its last message, as one record; the Oracle looks first, as the broadcast's Worker questions
/// setting says, and an Oracle that can't answer lets it through. The fixture is the broadcast's T6: its worker's turn
/// ends on whether the confirmation covers bulk deletes.
@MainActor @Suite(.blocking) struct OperatorRelayTests {
    let git = GitRunner.hermetic()

    static let t6 = "I wired the delete button to the confirmation.\n\n"
        + "Question: Should the confirmation cover bulk deletes too, or single deletes only?\n- Bulk deletes too\n- Single deletes only"
    static let t6Question = "Question: Should the confirmation cover bulk deletes too, or single deletes only?\n- Bulk deletes too\n- Single deletes only"

    /// Task PAY-236 at work in its own worktree, its worker in conversation `conv-1`; the broadcast relays as `check` says,
    /// the Oracle answering with `runner` (on unless `oracle` is false).
    func makeWorld(check: RelayCheck? = nil, oracle: Bool = true, runner: SecondOpinionRunner = .unavailable,
                   budget: Duration = .seconds(60)) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let repo = try GitFixture.makeRepo(prefix: "op-relay-")
        let worktree = try GitFixture.folder("op-relay-wt-") + "/wt"
        try git.run(["worktree", "add", "-q", "-b", "feat/pay-236", worktree], in: repo)
        let project = OperatorServiceFixtures.project(path: repo)
        var run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: oracle, oracleAgent: .claude), projects: [project],
                                              state: .active, planRevision: 1)
        run.relayCheck = check
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PAY-236", state: .working, worktree: worktree)
        task.baseBranch = "main"
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 0))
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), git: git) { ports in
            ports.secondOpinion = runner
            ports.challengeReplyBudget = budget
        }
        world.show(sessions(run, task, .working))
        return (world, run, task)
    }

    func sessions(_ run: OperatorRun, _ task: TaskItem, _ worker: SessionState) -> [SessionInfo] {
        [OperatorServiceFixtures.session("op", window: "wo", tag: run.id),
         OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, agent: task.agent.session, state: worker, conversation: "conv-1")]
    }

    /// The worker's turn ends having said `reply`: its tab goes idle, and AiTerm reads the turn.
    func endTurn(saying reply: String = Self.t6, _ world: OperatorWorld, _ run: OperatorRun, _ task: TaskItem, leavingOracle: Int = 0) async throws {
        let folder = world.ports.home.appendingPathComponent(".claude/projects/-wt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: JSONValue = ["type": "assistant", "message": ["content": [["type": "text", "text": .string(reply)]]]]
        try (JSONEncoder().encode(record) + Data("\n".utf8)).write(to: folder.appendingPathComponent("conv-1.jsonl"))
        world.show(sessions(run, task, .idle))
        await world.ports.work.settled(leaving: leavingOracle)
    }

    func relay(_ world: OperatorWorld, _ run: OperatorRun, key: String = "pay-236-bulk", _ more: [String: JSONValue] = [:]) async -> ToolAnswer {
        await world.call(run.id, "relay_question", .object(["key": .string(key), "task": "PAY-236"].merging(more) { $1 }))
    }

    func question(_ world: OperatorWorld, _ run: OperatorRun, _ key: String = "pay-236-bulk") -> OperatorQuestion? {
        world.run(run.id)?.questions.first { $0.id == key }
    }

    // -- straight ------------------------------------------------------------------------------

    @Test func straightToYouMakesTheRecordAtOnceInTheWorkersWords() async throws {
        let (world, run, task) = try makeWorld(check: .straight)
        try await endTurn(world, run, task)
        let answer = await relay(world, run)
        #expect(answer.value?["relayed"]?.stringValue == Self.t6Question)
        let made = try #require(question(world, run))
        #expect(made.text == Self.t6Question && made.relayedFrom == "main" && made.asker == .worker && made.holdsTask)
        #expect(made.history?.map(\.kind) == [.asked] && made.history?.first?.text == Self.t6, "the worker's message in full")
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == true)

        // Its card shows it from its worker, its block says who asks, run_status says it is a worker's, and the
        // notification names the task's worker.
        let current = try #require(world.run(run.id))
        let board = BroadcastBoard.make(run: current, state: world.state, acting: world.controller.acting,
                                        requests: OperatorRequests.open(run: current, state: world.state))
        let card = try #require(board.columns.flatMap(\.cards).first { $0.id == task.id })
        #expect(card.question?.asker == .worker && card.workerAsks == nil, "relayed, the record is the card's question")
        #expect(board.waiting.first?.from == "Its worker asks · relayed by the Operator" && board.waiting.first?.why == nil)
        let waiting = try #require(world.controller.status(of: current)).obligations.questionsWaiting
        #expect(waiting.first?.asker == "worker" && waiting.first?.tab == "main")
        #expect(world.notifications.posted.contains { $0.body == "PAY-236’s worker asks: \(Self.t6Question)" })
    }

    /// The same key returns the one record; so does another key for the same worker turn.
    @Test func oneRecordPerWorkerQuestion() async throws {
        let (world, run, task) = try makeWorld(check: .straight)
        try await endTurn(world, run, task)
        let first = await relay(world, run)
        #expect(await relay(world, run) == first)
        #expect(await relay(world, run, key: "another").value?["question"] == "pay-236-bulk")
        #expect(world.run(run.id)?.questions.count == 1)
    }

    /// H2: a turn the scan doesn't call a question can still be relayed, and then holds its task out of ready.
    @Test func aTurnTheScanMissedCanBeRelayedAndHoldsItsTask() async throws {
        let (world, run, task) = try makeWorld(check: .straight)
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: task.worktreePath)
        try await endTurn(saying: "Done, and committed. I'm not sure the drafts should survive a reset; the brief is silent.", world, run, task)
        #expect(world.controller.acting.turns[task.id] == nil, "the scan says nothing")
        func ready() throws -> [String] {
            let current = try #require(world.run(run.id))
            return try #require(world.controller.status(of: current)).obligations.readyForAcceptance
        }
        #expect(try ready() == ["PAY-236"])
        _ = await relay(world, run)
        #expect(question(world, run)?.holdsTask == true)
        #expect(try ready().isEmpty, "the relayed question holds it")
    }

    // -- refused -------------------------------------------------------------------------------

    @Test func aRelayWithNothingToRelayIsRefused() async throws {
        let (world, run, task) = try makeWorld(check: .straight)
        #expect(await relay(world, run).message?.contains("no ended turn AiTerm has read") == true)
        #expect(await relay(world, run, key: "prompt-x").message?.hasPrefix("Keys starting with") == true)
        try await endTurn(world, run, task)
        #expect(await relay(world, run, ["tab": "tests"]).message == "PAY-236 has no tab tests. Its tabs are main.")
        // Answered with message_task, the worker has moved on.
        world.controller.turns.messaged(task.id)
        #expect(await relay(world, run).message == "PAY-236’s worker has moved on since it asked: answer with message_task.")
        #expect(world.run(run.id)?.questions.isEmpty == true)
    }

    @Test func aWorkerAtWorkATaskYouTookOverOrOneFinishedIsRefused() async throws {
        let (world, run, task) = try makeWorld(check: .straight)
        try await endTurn(world, run, task)
        // Back at work, its turn is over: AiTerm drops the reading, so nothing is left to pass on.
        world.show(sessions(run, task, .working))
        let atWork = await relay(world, run)
        #expect(atWork.message?.hasPrefix("PAY-236’s worker has no ended turn AiTerm has read") == true)
        try await endTurn(world, run, task)
        world.show(sessions(run, task, .idle))
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = true } }
        #expect(await relay(world, run).message == "PAY-236 is the person’s now: they answer its worker themselves.")
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = false; $0.state = .noChange } }
        #expect(await relay(world, run).message == "PAY-236 has finished: nothing waits on its worker’s answer.")
    }

    // -- the Oracle ----------------------------------------------------------------------------

    @Test func challengedOnceTheOraclesRelayMakesTheRecordAtOnce() async throws {
        let (world, run, task) = try makeWorld(runner: .answering("IMPORTANT: The brief is silent on bulk deletes.\nVERDICT: RELAY"))
        try await endTurn(world, run, task)
        #expect(await relay(world, run).value?["question"] == "pay-236-bulk")
        let made = try #require(question(world, run))
        #expect(made.history?.map(\.kind) == [.asked, .oracle] && made.history?.last?.round == 1)
    }

    @Test func challengedOnceTheOraclesAnswerComesBackAndAReplyRelaysWithBothSides() async throws {
        let critique = "MAJOR: The brief says every delete asks first, bulk ones included.\nVERDICT: ANSWER"
        let (world, run, task) = try makeWorld(runner: .answering(critique))
        try await endTurn(world, run, task)
        let first = await relay(world, run)
        #expect(first.value?["challenged"] == true && first.value?["critique"]?.stringValue == critique)
        #expect(question(world, run) == nil, "nothing was passed on")
        let id = try #require(first.value?["challengeId"]?.stringValue)
        #expect(await relay(world, run, ["challengeId": .string(id)]) == first, "no reply yet: the critique again")
        let reply = "The brief names the delete button only; bulk deletes are another screen."
        let second = await relay(world, run, ["challengeId": .string(id), "challengeReply": .string(reply)])
        #expect(second.value?["question"] == "pay-236-bulk")
        let made = try #require(question(world, run))
        #expect(made.history?.map(\.kind) == [.asked, .oracle, .reply] && made.history?.last?.text == reply)
        // Its block says why it reached you, and opens the discussion.
        let current = try #require(world.run(run.id))
        let block = try #require(BroadcastBoard.waiting(of: current, state: world.state).first)
        #expect(block.why == "The Oracle looked at it once, and the Operator kept it for you.")
        #expect(block.discussion?.map(\.said) == ["The Oracle, round 1: \(critique)", "The Operator: \(reply)"])
        // The acting call again returns the one record.
        let again = await relay(world, run, ["challengeId": .string(id), "challengeReply": .string(reply)])
        #expect(again == second)
    }

    @Test func agreedFirstRunsRoundsWithTheDiscussionUntilOnlyMinorPointsAreLeft() async throws {
        let prompts = PromptLog()
        let answers = ["IMPORTANT: The brief answers it.\nVERDICT: ANSWER", "MINOR: Say which screen.\nVERDICT: ANSWER"]
        let (world, run, task) = try makeWorld(check: .agreeFirst, runner: .answeringInTurn(answers, prompts: prompts))
        try await endTurn(world, run, task)
        let id = try #require(await relay(world, run).value?["challengeId"]?.stringValue)
        let made = await relay(world, run, ["challengeId": .string(id), "challengeReply": "The brief names one screen only."])
        #expect(made.value?["question"] == "pay-236-bulk", "only a minor point left: agreed")
        let said = await prompts.all
        #expect(said.count == 2 && said[1].contains("The Operator: The brief names one screen only.") && said[1].contains("round 1"))
        #expect(question(world, run)?.history?.map(\.kind) == [.asked, .oracle, .reply, .oracle])
        #expect(world.run(run.id)?.challenges.compactMap(\.round) == [1, 2])
    }

    /// A reply call repeated after its answer was lost returns the next round already asked, never a second Oracle call.
    @Test func aRepeatedReplyReturnsTheRoundItAlreadyStarted() async throws {
        let prompts = PromptLog()
        let answers = ["IMPORTANT: The brief answers it.\nVERDICT: ANSWER", "MAJOR: Still the brief.\nVERDICT: ANSWER"]
        let (world, run, task) = try makeWorld(check: .agreeFirst, runner: .answeringInTurn(answers, prompts: prompts))
        try await endTurn(world, run, task)
        let first = try #require(await relay(world, run).value?["challengeId"]?.stringValue)
        let reply: [String: JSONValue] = ["challengeId": .string(first), "challengeReply": "The brief names one screen only."]
        let second = await relay(world, run, reply)
        #expect(second.value?["challengeId"] != nil && second.value?["challengeId"]?.stringValue != first)
        #expect(await relay(world, run, reply) == second)
        #expect(await prompts.all.count == 2)
        #expect(world.run(run.id)?.challenges.compactMap(\.round) == [1, 2])
    }

    /// The first call repeated after its answer was lost returns the round it started, never a second Oracle call.
    @Test func aRepeatedFirstCallReturnsTheRoundItAlreadyStarted() async throws {
        let prompts = PromptLog()
        let (world, run, task) = try makeWorld(runner: .answeringInTurn(["MAJOR: The brief answers it.\nVERDICT: ANSWER"], prompts: prompts))
        try await endTurn(world, run, task)
        let first = await relay(world, run)
        #expect(first.value?["challenged"] == true)
        #expect(await relay(world, run) == first)
        #expect(await prompts.all.count == 1)
        #expect(world.run(run.id)?.challenges.count == 1)
    }

    /// A late critique fetched with its challengeId, that answer lost: the poll or the first call again returns it as it was.
    @Test func aLateCritiqueStaysReplayableAfterItsPoll() async throws {
        let gate = OracleGate(), critique = "MAJOR: The brief answers it.\nVERDICT: ANSWER"
        let (world, run, task) = try makeWorld(runner: .answering(critique, gate: gate), budget: .milliseconds(20))
        try await endTurn(world, run, task)
        let id = try #require(await relay(world, run).value?["challengeId"]?.stringValue)
        await gate.open()
        await world.ports.work.settled()
        let polled = await relay(world, run, ["challengeId": .string(id)])
        #expect(polled.value?["critique"]?.stringValue == critique)
        #expect(await relay(world, run, ["challengeId": .string(id)]) == polled)
        #expect(await relay(world, run) == polled)
    }

    @Test func agreedFirstStillApartAfterThreeRoundsReachesYouWithBothSides() async throws {
        let (world, run, task) = try makeWorld(check: .agreeFirst, runner: .answering("MAJOR: The brief answers it.\nVERDICT: ANSWER"))
        try await endTurn(world, run, task)
        var id = try #require(await relay(world, run).value?["challengeId"]?.stringValue)
        for round in 1...2 {
            let next = await relay(world, run, ["challengeId": .string(id), "challengeReply": .string("Not so, round \(round).")])
            id = try #require(next.value?["challengeId"]?.stringValue, "round \(round + 1) runs")
        }
        let last = await relay(world, run, ["challengeId": .string(id), "challengeReply": "Not so, round 3."])
        #expect(last.value?["question"] == "pay-236-bulk")
        #expect(question(world, run)?.history?.filter { $0.kind == .oracle }.count == 3)
        #expect(question(world, run)?.history?.filter { $0.kind == .reply }.count == 3)
    }

    /// Fail-open: an Oracle that can't answer, one that gives no verdict, or one lost with AiTerm's restart lets the question
    /// through, its history saying why. With the Oracle off, a relay goes straight.
    @Test func anOracleThatCantAnswerLetsTheQuestionThrough() async throws {
        let (failing, failingRun, failingTask) = try makeWorld(runner: .unavailable)
        try await endTurn(failing, failingRun, failingTask)
        _ = await relay(failing, failingRun)
        #expect(question(failing, failingRun)?.history?.last?.kind == .unchallenged)

        let (vague, vagueRun, vagueTask) = try makeWorld(runner: .answering("Hard to say."))
        try await endTurn(vague, vagueRun, vagueTask)
        _ = await relay(vague, vagueRun)
        #expect(question(vague, vagueRun)?.history?.last?.text == "The Oracle gave no clear verdict.")

        let gate = OracleGate()
        let (slow, slowRun, slowTask) = try makeWorld(runner: .answering("VERDICT: RELAY", gate: gate), budget: .milliseconds(20))
        defer { slow.controller.tools.cancelChallenges() }
        try await endTurn(slow, slowRun, slowTask)
        let pending = await relay(slow, slowRun)
        #expect(pending.value?["pending"] == true)
        let id = try #require(pending.value?["challengeId"]?.stringValue)
        #expect(slow.workspace.flush())
        let restarted = try OperatorWorld(try slow.workspace.file.load(), git: git)
        // The worker's question, read again after the restart.
        try await endTurn(restarted, slowRun, slowTask)
        #expect(restarted.controller.turns.readings[slowTask.id] != nil)
        _ = await restarted.call(slowRun.id, "relay_question", ["key": "pay-236-bulk", "task": "PAY-236", "challengeId": .string(id)])
        #expect(restarted.run(slowRun.id)?.questions.first?.history?.last?.text == "AiTerm restarted before the Oracle answered.")
        await gate.open()

        let (off, offRun, offTask) = try makeWorld(check: .agreeFirst, oracle: false, runner: .answering("VERDICT: ANSWER"))
        try await endTurn(off, offRun, offTask)
        _ = await relay(off, offRun)
        #expect(question(off, offRun)?.history?.map(\.kind) == [.asked], "the Oracle off, it goes straight")
    }

    /// A round saved mid-discussion keeps its number and the Operator's reply across AiTerm's restart, so Agreed first
    /// neither runs extra rounds nor loses a reply from the discussion.
    @Test func aRoundKeepsItsNumberAndReplyAcrossARestart() throws {
        var record = ChallengeRecord(id: "r2", tool: "relay_question", askedAt: Date(timeIntervalSince1970: 0), round: 2)
        record.reply = "The brief names one screen only."
        let read = try JSONDecoder().decode(ChallengeRecord.self, from: JSONEncoder().encode(record))
        #expect(read.round == 2 && read.reply == record.reply)
    }

    /// The Oracle answers after the worker moved past its question (the person answered it in its tab): nothing is relayed,
    /// and the task doesn't wait.
    @Test func aWorkerThatMovedOnWhileTheOracleReadRelaysNothing() async throws {
        let held = HeldGate()
        let runner = SecondOpinionRunner(locate: { "/opt/bin/\($0)" }, run: { _, _, _, _, _ in
            await held.wait()
            let json = String(decoding: try JSONEncoder().encode(["result": "VERDICT: RELAY"]), as: UTF8.self)
            return ProcessOutput(status: 0, stdout: json, stderr: "", timedOut: false)
        })
        let (world, run, task) = try makeWorld(runner: runner)
        try await endTurn(world, run, task)
        let relaying = Task { await relay(world, run) }
        await held.started()
        world.show(sessions(run, task, .working))
        await held.release()
        let answer = await relaying.value
        #expect(answer.message?.hasPrefix("PAY-236’s worker has no ended turn AiTerm has read") == true)
        #expect(question(world, run) == nil)
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) != true)
    }

    /// A round the Oracle answers late belongs to the question it read: once the worker asks something else, calling again
    /// with its challengeId relays nothing.
    @Test func aLateRoundNeverJudgesTheWorkersNextQuestion() async throws {
        let gate = OracleGate()
        let (world, run, task) = try makeWorld(runner: .answering("VERDICT: RELAY", gate: gate), budget: .milliseconds(20))
        defer { world.controller.tools.cancelChallenges() }
        try await endTurn(world, run, task)
        let id = try #require(await relay(world, run).value?["challengeId"]?.stringValue)
        world.show(sessions(run, task, .working))
        try await endTurn(saying: "Done with the button.\n\nQuestion: Should the dialog name the item?", world, run, task, leavingOracle: 1)
        let late = await relay(world, run, ["challengeId": .string(id)])
        #expect(late.message == "PAY-236’s worker has asked something else since the Oracle read its question. "
                + "Call relay_question again without challengeId.")
        #expect(question(world, run) == nil)
        await gate.open()
    }

    // -- the card ------------------------------------------------------------------------------

    /// Before it is relayed, the worker's question is the Operator's: its card shows it muted, and message_task clears it.
    @Test func theCardShowsTheWorkersQuestionUntilItIsAnsweredOrRelayed() async throws {
        let (world, run, task) = try makeWorld(check: .straight)
        try await endTurn(world, run, task)
        func card() throws -> BroadcastBoard.Card {
            let current = try #require(world.run(run.id))
            return try #require(BroadcastBoard.make(run: current, state: world.state, acting: world.controller.acting, requests: [],
                                                    sessions: world.live.sessions).columns.flatMap(\.cards).first { $0.id == task.id })
        }
        let asking = try card()
        #expect(asking.workerAsks == Self.t6Question)
        #expect(asking.line?.text == "asking the Operator")
        world.controller.turns.messaged(task.id)
        #expect(try card().workerAsks == nil, "answered with message_task")
    }
}

/// The prompts an Oracle was asked, in order.
actor PromptLog {
    private(set) var all: [String] = []
    func append(_ prompt: String) { all.append(prompt) }
}

/// A count an Oracle fake takes its next answer by.
private actor Turn {
    private var next = 0
    func take() -> Int { defer { next += 1 }; return next }
}

extension SecondOpinionRunner {
    /// A second opinion that answers `answers` in turn, the last one again once they run out, each prompt logged.
    static func answeringInTurn(_ answers: [String], prompts: PromptLog) -> SecondOpinionRunner {
        let turn = Turn()
        return SecondOpinionRunner(locate: { "/opt/bin/\($0)" }, run: { _, arguments, _, _, _ in
            if let at = arguments.firstIndex(of: "-p"), at + 1 < arguments.count { await prompts.append(arguments[at + 1]) }
            let answer = answers[min(await turn.take(), answers.count - 1)]
            let json = String(decoding: try JSONEncoder().encode(["result": answer]), as: UTF8.self)
            return ProcessOutput(status: 0, stdout: json, stderr: "", timedOut: false)
        })
    }
}
