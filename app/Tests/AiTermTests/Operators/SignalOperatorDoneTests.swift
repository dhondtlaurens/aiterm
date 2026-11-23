import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// A stage whose Done the Operator decides: `finish_stage(done)` goes to the Oracle with the evidence, up to three
/// rounds; its yes finishes the stage, a critique comes back to answer, and disagreement or an Oracle that is off goes
/// to the person, whose recorded yes finishes it. With merge when ready, an agreed done waits for AiTerm's merge.
@MainActor @Suite struct SignalOperatorDoneTests {
    static let operatorDone = SignalTrigger(source: .operator, description: "A merge request is open and green", query: "")

    func world(merges: Bool = false) -> (SignalWorld, UUID) {
        var world = SignalWorld()
        let signal = world.signal(done: Self.operatorDone, merges: merges)
        let id = world.workingTask(signal: signal)
        return (world, id)
    }

    @Test func theOraclesYesFinishesTheStage() async throws {
        let (world, id) = world()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .critique("YES. !7 is open and green.") }
        let handler = make(h, world: world, oracle: oracle)
        let answer = await handler.respond(finish(h, id, key: "f1"))
        #expect(answer.value?["status"] == "finished")
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .done)
        let quoted = try oracle.quoted(0)
        #expect(quoted["evidence"] == "Opened !7; its pipeline is green." && quoted["doneLooksLike"] == "A merge request is open and green")
        #expect(quoted["workerTurn"] == "Opened !7." && quoted["brief"] == "/psg:plan")
        #expect(h.workspace.state.operatorSession?.oracleRounds.isEmpty == true)
    }

    @Test func aCritiqueComesBackAndTheRevisedDoneNamesIt() async throws {
        let (world, id) = world()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var answers = ["NO: the lockfile was not committed.", "YES. Committed now."]
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .critique(answers.removeFirst()) }
        let handler = make(h, world: world, oracle: oracle)
        let first = await handler.respond(finish(h, id, key: "f1"))
        #expect(first.value?["status"] == "challenged" && first.value?["round"] == 1)
        let challenge = try #require(first.value?["challengeId"]?.stringValue)
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        // A new done without the critique's id gets the open round back, without asking the Oracle again.
        let again = await handler.respond(finish(h, id, key: "f2"))
        #expect(again.value?["challengeId"]?.stringValue == challenge && oracle.prompts.count == 1)
        let revised = await handler.respond(finish(h, id, key: "f3", extra: ["challengeId": .string(challenge)]))
        #expect(revised.value?["status"] == "finished")
        #expect(try oracle.quoted(1)["discussion"]?.arrayValue?.count == 2)
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .done)
    }

    @Test func threeDisagreementsGoToThePersonWhoseYesFinishesIt() async throws {
        let (world, id) = world()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .critique("NO: not done.") }
        let handler = make(h, world: world, oracle: oracle)
        var challenge: String?
        for round in 1...2 {
            var extra: [String: JSONValue] = [:]
            if let challenge { extra["challengeId"] = .string(challenge) }
            let reply = await handler.respond(finish(h, id, key: "f\(round)", extra: extra))
            #expect(reply.value?["status"] == "challenged")
            challenge = reply.value?["challengeId"]?.stringValue
        }
        let third = await handler.respond(finish(h, id, key: "f3", extra: ["challengeId": .string(challenge!)]))
        #expect(third.value?["status"] == "ask_you")
        #expect(third.value?["reason"]?.stringValue?.hasPrefix("The Operator and Oracle still disagree after three rounds.") == true)
        let key = try #require(third.value?["questionKey"]?.stringValue)
        // A later done goes to the person again, under the same question, without the Oracle.
        let fourth = await handler.respond(finish(h, id, key: "f4"))
        #expect(fourth.value?["status"] == "ask_you" && fourth.value?["questionKey"]?.stringValue == key && oracle.prompts.count == 3)
        #expect(await handler.respond(request(h, tool: "ask_you", arguments(id, key: key, extra: ["text": "Is the update done?"]))).message == nil)
        #expect(await handler.respond(request(h, tool: "resolve_question", ["question": .string(key), "answer": "Yes, it is done.", "key": "r1"])).message == nil)
        let decided = await handler.respond(finish(h, id, key: "f5", extra: ["fromQuestion": .string(key)]))
        #expect(decided.value?["status"] == "finished" && decided.value?["decided"] == "The person said it is done.")
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .done && oracle.prompts.count == 3)
    }

    /// A yes to some other question, asked before this stage's done went to the person, is no consent to finish it.
    @Test func anUnrelatedYesDoesNotFinish() async throws {
        let (world, id) = world()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let handler = make(h, world: world, oracle: ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }, on: false))
        _ = await handler.respond(request(h, tool: "ask_you", arguments(id, key: "q0", extra: ["text": "Should I try another approach?"])))
        _ = await handler.respond(request(h, tool: "resolve_question", ["question": "q0", "answer": "Yes", "key": "r0"]))
        #expect(await handler.respond(finish(h, id, key: "f0", extra: ["fromQuestion": "q0"])).message
                == "That recorded answer is not the person's answer to whether this stage is done.")
        // Asked after the done went to the person, another question's yes is still no consent.
        #expect(await handler.respond(finish(h, id, key: "f1")).value?["status"] == "ask_you")
        _ = await handler.respond(request(h, tool: "ask_you", arguments(id, key: "q2", extra: ["text": "Should I retry the build?"])))
        _ = await handler.respond(request(h, tool: "resolve_question", ["question": "q2", "answer": "Yes", "key": "r2"]))
        #expect(await handler.respond(finish(h, id, key: "f2", extra: ["fromQuestion": "q2"])).message
                == "That recorded answer is not the person's answer to whether this stage is done.")
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .working)
    }

    /// With merge when ready on and a host AiTerm cannot read, the done is refused rather than finished unmerged.
    @Test func anUnconnectedHostCannotSayThereIsNoMergeRequest() async throws {
        let (world, id) = world(merges: true)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { SignalConnections() })
        await #expect(throws: ActionUnavailable.self) { try await io.hasOpenRequest(h.workspace.state.task(id: id)!) }
    }

    @Test func thePersonsNoDoesNotFinish() async throws {
        let (world, id) = world()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let handler = make(h, world: world, oracle: ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }, on: false))
        let asked = await handler.respond(finish(h, id, key: "f1"))
        let key = try #require(asked.value?["questionKey"]?.stringValue)
        #expect(asked.value?["status"] == "ask_you" && key.hasPrefix("done-"))
        _ = await handler.respond(request(h, tool: "ask_you", arguments(id, key: key, extra: ["text": "Is it done?"])))
        _ = await handler.respond(request(h, tool: "resolve_question", ["question": .string(key), "answer": "No, also bump the major.", "key": "r1"]))
        #expect(await handler.respond(finish(h, id, key: "f2", extra: ["fromQuestion": .string(key)])).value?["status"] == "not_done")
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        // Once the missing work is done, the next done asks again under a new question, whose yes finishes it.
        let again = await handler.respond(finish(h, id, key: "f3"))
        let next = try #require(again.value?["questionKey"]?.stringValue)
        #expect(again.value?["status"] == "ask_you" && next != key)
        _ = await handler.respond(request(h, tool: "ask_you", arguments(id, key: next, extra: ["text": "Done now?"])))
        _ = await handler.respond(request(h, tool: "resolve_question", ["question": .string(next), "answer": "Yes.", "key": "r2"]))
        #expect(await handler.respond(finish(h, id, key: "f4", extra: ["fromQuestion": .string(next)])).value?["status"] == "finished")
    }

    @Test func anOracleThatIsOffOrCallsForThePersonAsksThePerson() async throws {
        for oracle in [false, true] {
            let (world, id) = world()
            let h = try SignalHarness(world); defer { h.cleanUp() }
            let scripted = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }, on: oracle) { _ in .critique("PERSON: theirs to judge.") }
            let reply = await make(h, world: world, oracle: scripted).respond(finish(h, id, key: "f1"))
            #expect(reply.value?["status"] == "ask_you")
            #expect(reply.value?["reason"] == (oracle ? "PERSON: theirs to judge." : "The Oracle is off."))
            #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        }
    }

    /// The open merge request is read from the host, so one the watch has not found yet still waits for the merge.
    @Test func withMergeWhenReadyAnAgreedDoneWaitsForAiTermsMerge() async throws {
        let (world, id) = world(merges: true)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .critique("YES.") }
        var reads = 0
        let handler = make(h, world: world, oracle: oracle, openRequest: { _ in reads += 1; return true })
        let first = await handler.respond(finish(h, id, key: "f1"))
        #expect(first.value?["status"] == "watching")
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .watching)
        // AiTerm merges and hands the stage back to its worker; the next agreed done ends it.
        h.workspace.mutate { state in state.updateSignalTask(id) { record in
            var merge = SignalMerge(request: SignalRequestRef(remote: "https://git.example/shop/web", number: 7), head: "abc1234")
            merge.accepted = true; merge.handBackOwed = false
            record.merge = merge; record.phase = .working
        } }
        let second = await handler.respond(finish(h, id, key: "f2"))
        #expect(second.value?["status"] == "finished")
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .done)
        #expect(reads == 1, "a merge the host confirmed is AiTerm's: no second read")
    }

    /// A merge AiTerm saved but the host never confirmed is not taken as merged: the host says whether it is still open.
    @Test func anUnconfirmedMergeIsCheckedOnTheHost() async throws {
        let (world, id) = world(merges: true)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { state in state.updateSignalTask(id) {
            $0.merge = SignalMerge(request: SignalRequestRef(remote: "https://git.example/shop/web", number: 7), head: "abc1234")
        } }
        let handler = make(h, world: world, oracle: ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }), openRequest: { _ in true })
        #expect(await handler.respond(finish(h, id, key: "f1")).value?["status"] == "watching")
    }

    /// A host that cannot be read refuses the done before the Oracle is asked, so no round is spent.
    @Test func anUnreadableHostRefusesBeforeTheOracle() async throws {
        let (world, id) = world(merges: true)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now })
        let handler = make(h, world: world, oracle: oracle, openRequest: { _ in throw ActionUnavailable("GitLab is down.") })
        let answer = await handler.respond(finish(h, id, key: "f1"))
        #expect(answer.message?.hasPrefix("AiTerm couldn’t read its merge request to merge it first:") == true)
        #expect(oracle.prompts.isEmpty && h.workspace.state.task(id: id)?.signalTask?.phase == .working)
    }

    @Test func withMergeWhenReadyAndNoMergeRequestAnAgreedDoneFinishes() async throws {
        let (world, id) = world(merges: true)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let handler = make(h, world: world, oracle: ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }))
        #expect(await handler.respond(finish(h, id, key: "f1")).value?["status"] == "finished")
    }

    @Test func aQueryDoneStageRefusesTheOperatorDonesFields() async throws {
        var world = SignalWorld(); let id = world.workingTask(signal: world.signal())
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let handler = make(h, world: world, oracle: ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }))
        #expect(await handler.respond(finish(h, id, key: "f1", extra: ["challengeId": "x"])).message
                == "challengeId and fromQuestion belong to a done stage whose Done the Operator decides.")
        #expect(await handler.respond(finish(h, id, key: "f2")).value?["status"] == "recorded")
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .watching)
    }

    /// No query reads an Operator Done: its baseline and every watch read say it does not match, so only the Operator's
    /// agreed done, or a merged or closed merge request, ends the stage.
    @Test func anOperatorDoneNeverMatchesAQueryAndAMergeStillEndsIt() async throws {
        let (world, id) = world()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let git = RecordingGitRunner()
        let io = SignalHostIO(workspace: h.workspace, git: git, connections: { SignalConnections() })
        let task = try #require(h.workspace.state.task(id: id))
        #expect(try await io.doneMatches(task) == false)
        let snapshot = try await io.read(task)
        #expect(snapshot.facts.doneMatches == false && git.calls.isEmpty)
        var facts = DoneCheck.Facts()
        #expect(!DoneCheck.reached(facts, before: false))
        facts.merged = true
        #expect(DoneCheck.reached(facts, before: false))
    }

    // MARK: Helpers

    private func finish(_ h: SignalHarness, _ id: UUID, key: String, extra: [String: JSONValue] = [:]) -> OperatorRequest {
        var args: [String: JSONValue] = ["outcome": "done", "evidence": "Opened !7; its pipeline is green."]
        args.merge(extra) { _, new in new }
        return request(h, tool: "finish_stage", arguments(id, key: key, extra: args))
    }
    private func make(_ h: SignalHarness, world: SignalWorld, oracle: ScriptedOracle,
                      openRequest: @escaping @MainActor (TaskItem) async throws -> Bool = { _ in false }) -> SignalOperatorToolHandler {
        let stages = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in task }, launch: { _, _ in "window" }, restore: { $0 }))
        let questions = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, oracle: oracle.consult, ports: .init(
            question: { _, _ in nil }, deliver: { _, _, _ in }))
        let choices = AgentChoiceRounds(workspace: h.workspace, now: { world.now }, oracle: oracle.consult, ports: .init(weeklyUsage: { [:] }, installedAgents: { [] }))
        return SignalOperatorToolHandler(workspace: h.workspace, stages: stages, questions: questions, choices: choices, journal: h.journal,
            now: { world.now }, ports: .init(oracleEnabled: { oracle.consult.isOn }, workerQuestion: { _, _ in false },
                read: { _ in ["workers": ["workers": [["tab": "main", "lastMessage": "Opened !7."]]], "source": [:]] },
                message: { _, _, _, _ in }, openTab: { _, _, _, _, _, _ in [:] }, jiraSearch: { _ in [] },
                consult: { _, _ in .unavailable(.off) }, openRequest: openRequest))
    }
    private func request(_ h: SignalHarness, tool: String, _ args: JSONValue) -> OperatorRequest {
        OperatorRequest(requestId: UUID().uuidString, operatorId: h.workspace.state.operatorSession!.id.uuidString,
                        tool: tool, arguments: args, generation: h.workspace.state.operatorSession!.generation)
    }
    private func arguments(_ id: UUID, key: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var args: [String: JSONValue] = ["task": .string(id.uuidString), "stage": 1, "ownership": 0]
        args.merge(extra) { _, new in new }; if let key { args["key"] = .string(key) }; return .object(args)
    }
}
