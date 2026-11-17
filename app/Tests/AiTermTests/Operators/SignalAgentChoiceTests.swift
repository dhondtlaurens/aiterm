import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// The Operator proposes a stage's agent row (and project), the Oracle agrees or critiques, and the
/// choice never reaches the person.
@MainActor @Suite struct SignalAgentChoiceTests {
    static let codex = AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")
    static let sonnet = AgentChoice(agent: .claude, model: "claude-sonnet-5-5", reasoning: nil)

    /// One harness with a scripted Oracle and recorded launches and tabs.
    @MainActor final class Rig {
        let world: SignalWorld, h: SignalHarness
        /// The Oracle's answers in order; once they run out it agrees.
        var answers: [OracleRunner.Verdict] = []
        lazy var oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { [world] in world.now }) { [unowned self] _ in
            self.answers.isEmpty ? .critique("YES") : self.answers.removeFirst()
        }
        var oracleOn: Bool {
            get { oracle.settings.oracle.isOn }
            set { oracle.settings.oracle.isOn = newValue }
        }
        /// What each check quoted to the Oracle.
        var asked: [JSONValue] { get throws { try oracle.prompts.indices.map(oracle.quoted) } }
        var launched: [(UUID, AgentKind, String)] = []
        var tabs: [(String, AgentChoice)] = []
        var tabReasons: [String] = []
        lazy var stages = StageRunner(workspace: h.workspace, journal: h.journal, now: { [world] in world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { [h] task, _ in
                // As the app's checkout does: the worktree saved on the task.
                h.workspace.mutate { $0.updateSignalItem(task.id) { $0.worktreePath = "/synthetic/shop/.worktrees/" + task.id.uuidString } }
                h.workspace.flush(); return try #require(h.workspace.state.task(id: task.id))
            },
            launch: { [unowned self] task, _ in self.launched.append((task.id, task.agent, task.model)); return "window-" + task.id.uuidString },
            restore: { $0 }))
        lazy var choices = AgentChoiceRounds(workspace: h.workspace, now: { [world] in world.now }, oracle: oracle.consult, ports: .init(
            weeklyUsage: { [:] }, installedAgents: { [.claude, .codex] }))
        lazy var handler: SignalOperatorToolHandler = {
            let off = ScriptedOracle(h.workspace, folder: h.folder, now: { [world] in world.now }, on: false)
            let questions = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { [world] in world.now }, oracle: off.consult, ports: .init(
                question: { _, _ in nil }, deliver: { _, _, _ in }))
            return SignalOperatorToolHandler(workspace: h.workspace, stages: stages, questions: questions, choices: choices, journal: h.journal,
                now: { [world] in world.now }, ports: .init(oracleEnabled: { [unowned self] in self.oracleOn }, workerQuestion: { _, _ in false },
                    read: { _ in [:] }, message: { _, _, _, _ in },
                    openTab: { [unowned self] _, key, row, _, why, _ in self.tabs.append((key, row)); self.tabReasons.append(why); return ["status": "opened", "tab": .string(key)] },
                    jiraSearch: { _ in [] }, consult: { _, _ in .agreed("", round: 1) }, installedAgents: { [.claude, .codex] }))
        }()
        init(_ world: SignalWorld) throws { self.world = world; h = try SignalHarness(world) }
        var router: ItemRouter { ItemRouter(workspace: h.workspace, now: { [world] in world.now }) }
        func route(_ signal: UUID, _ keys: [String] = ["PAY-1"]) -> [UUID] {
            router.apply(signals: [signal], read: SignalRead(items: keys.map(world.ticket), complete: true))
        }
        func record(_ id: UUID) -> SignalTask? { h.workspace.state.signalItem(id: id)?.signalTask }
        func call(_ tool: String, _ id: UUID, key: String, _ extra: [String: JSONValue]) async -> ToolAnswer {
            let record = record(id)
            var args: [String: JSONValue] = ["task": .string(id.uuidString), "stage": .int(record?.stage ?? 1), "ownership": .int(record?.ownership ?? 0), "key": .string(key)]
            args.merge(extra) { _, new in new }
            return await handler.respond(OperatorRequest(requestId: UUID().uuidString, operatorId: h.workspace.state.operatorSession!.id.uuidString,
                                                         tool: tool, arguments: .object(args), generation: h.workspace.state.operatorSession!.generation))
        }
        func choose(_ id: UUID, key: String, row: AgentChoice, project: UUID? = nil, reason: String = "Codex has room this week.",
                    challenge: String? = nil) async -> ToolAnswer {
            var extra: [String: JSONValue] = ["agent": .string(row.agent.rawValue), "model": .string(row.model), "reason": .string(reason)]
            if let reasoning = row.reasoning { extra["reasoning"] = .string(reasoning) }
            if let project { extra["project"] = .string(project.uuidString) }
            if let challenge { extra["challengeId"] = .string(challenge) }
            return await call("choose_agent", id, key: key, extra)
        }
        func journal(_ id: UUID) throws -> [String] {
            try TaskJournal.read(task: id, folder: h.folder.appendingPathComponent("journals")).compactMap {
                if case .ours(let text) = $0.text { text } else { nil }
            }
        }
    }
    func rig(agents: [AgentChoice] = [SignalWorld.agent, Self.codex], configure: (inout SignalWorld) -> Void = { _ in }) throws -> (Rig, UUID) {
        var world = SignalWorld(); let signal = world.signal(agents: agents)
        world.state.operatorSession = .open(createdAt: world.now)
        configure(&world)
        return (try Rig(world), signal)
    }

    @Test func theOracleAgreesAndTheWorkerLaunchesOnTheProposedRowWithItsReasonJournaled() async throws {
        let (r, signal) = try rig(); defer { r.h.cleanUp() }
        let id = try #require(r.route(signal).first)
        #expect(r.record(id)?.phase == .choosing && r.record(id)?.choosableRows == [SignalWorld.agent, Self.codex])
        let answer = await r.choose(id, key: "c1", row: Self.codex)
        #expect(answer.value?["status"] == "chosen" && answer.value?["decided"] == "oracleAgreed")
        #expect(r.launched.map(\.1) == [.codex] && r.record(id)?.phase == .working)
        let asked = try r.asked
        #expect(asked.count == 1 && asked[0]["proposal"]?["row"]?.stringValue == Self.codex.label)
        #expect(asked[0]["permittedRows"] == .array([SignalWorld.agent, Self.codex].map { .string($0.label) }))
        #expect(try r.journal(id).contains { $0.contains("Agent row: Codex · gpt-6-astra · medium") && $0.contains("Codex has room this week.") && $0.contains("the Oracle agreed") })
        let status = try #require(await r.call("run_status", id, key: "s", [:]).value)
        let line = try #require(status["tasks"]?.arrayValue?.first)
        #expect(line["choice"]?["row"]?["agent"] == "codex" && line["choice"]?["reason"] == "Codex has room this week.")
        #expect(status["installedAgents"] == ["claude", "codex"])
    }

    @Test func aCritiqueReturnsAChallengeAndTheRevisedProposalIsAgreedInRoundTwo() async throws {
        let (r, signal) = try rig(); defer { r.h.cleanUp() }
        let id = try #require(r.route(signal).first)
        r.answers = [.critique("NO: Claude is at 92% this week; take Codex.")]
        let first = await r.choose(id, key: "c1", row: SignalWorld.agent, reason: "Planning suits Opus.")
        #expect(first.value?["status"] == "challenged" && first.value?["round"] == 1)
        let challenge = try #require(first.value?["challengeId"]?.stringValue)
        #expect(r.launched.isEmpty && r.record(id)?.phase == .choosing)
        let unnamed = await r.choose(id, key: "c2", row: Self.codex)
        #expect(unnamed.value?["status"] == "challenged" && r.oracle.prompts.count == 1, "A revision must name the open round.")
        let revised = await r.choose(id, key: "c3", row: Self.codex, challenge: challenge)
        #expect(revised.value?["status"] == "chosen" && r.record(id)?.choice?.round == 2)
        #expect(try r.asked.last?["discussion"]?.arrayValue?.count == 2 && r.launched.map(\.1) == [.codex])
        #expect(r.h.workspace.state.operatorSession?.oracleRounds.isEmpty == true)
    }

    @Test func threeDisagreeingRoundsFallBackToTheFirstPermittedRowAndSaySo() async throws {
        let (r, signal) = try rig(); defer { r.h.cleanUp() }
        let id = try #require(r.route(signal).first)
        r.answers = [.critique("NO 1"), .critique("NO 2"), .critique("NO 3: still Opus.")]
        var challenge: String?
        for round in 1...2 {
            let answer = await r.choose(id, key: "c\(round)", row: Self.codex, challenge: challenge)
            #expect(answer.value?["status"] == "challenged" && answer.value?["round"] == .int(round))
            challenge = answer.value?["challengeId"]?.stringValue
        }
        let last = await r.choose(id, key: "c3", row: Self.codex, challenge: challenge)
        #expect(last.value?["status"] == "chosen" && last.value?["decided"] == "disagreed")
        #expect(r.record(id)?.choice?.row == SignalWorld.agent && r.record(id)?.choice?.note == "NO 3: still Opus.")
        #expect(r.launched.map(\.1) == [.claude])
        #expect(try r.journal(id).contains { $0.contains("disagreed for three rounds, so the first permitted row applies") })
        #expect(r.h.workspace.state.operatorSession?.questions.isEmpty == true, "The choice never comes to the person.")
    }

    @Test(arguments: [false, true]) func withTheOracleOffOrUnavailableTheProposalApplies(unavailable: Bool) async throws {
        let (r, signal) = try rig(); defer { r.h.cleanUp() }
        let id = try #require(r.route(signal).first)
        if unavailable { r.answers = [.unanswered("The Oracle timed out.")] } else { r.oracleOn = false }
        let answer = await r.choose(id, key: "c1", row: Self.codex)
        #expect(answer.value?["decided"] == (unavailable ? "oracleUnavailable" : "oracleOff"))
        #expect(r.oracle.prompts.count == (unavailable ? 1 : 0) && r.launched.map(\.1) == [.codex])
        if unavailable { #expect(r.record(id)?.choice?.note?.contains("timed out") == true) }
    }

    @Test func aCheckInvalidatedByChangedSettingsKeepsTheTaskChoosingAndAsksForANewProposal() async throws {
        let (r, signal) = try rig(); defer { r.h.cleanUp() }
        let id = try #require(r.route(signal).first)
        r.oracle.answer = { [unowned oracle = r.oracle] _ in oracle.settings.revision += 1; return .critique("YES") }
        let answer = await r.choose(id, key: "c1", row: Self.codex)
        #expect(answer.value?["status"] == "retry" && r.record(id)?.phase == .choosing && r.launched.isEmpty)
        #expect(r.h.workspace.state.operatorSession?.oracleRounds.isEmpty == true)
        r.oracle.answer = { _ in .critique("YES") }
        #expect(await r.choose(id, key: "c2", row: Self.codex).value?["status"] == "chosen")
    }

    @Test func aSingleRowSignalLaunchesAsTodayWithoutAProposalOrAnOracleRound() async throws {
        let (r, signal) = try rig(agents: [SignalWorld.agent]); defer { r.h.cleanUp() }
        let id = try #require(r.route(signal).first)
        #expect(r.record(id)?.phase == .launching)
        await r.stages.run(id)
        #expect(r.launched.map(\.1) == [.claude] && r.oracle.prompts.isEmpty && r.record(id)?.choice == nil)
        #expect(try r.journal(id).allSatisfy { !$0.contains("Agent row") })
    }

    @Test func aLaterStageChoosesAgainButASavedConversationKeepsItsAgent() async throws {
        var later: UUID?, keep: UUID?, id: UUID?
        let (r, _) = try rig { world in
            let first = world.signal(name: "Plan", agents: [SignalWorld.agent])
            later = world.signal(name: "Review", agents: [SignalWorld.agent, Self.sonnet, Self.codex])
            keep = world.signal(name: "Fix", agents: [SignalWorld.agent, Self.codex])
            id = world.workingTask(signal: first)
            world.state.updateSignalItem(id!) { $0.conversations = [TaskConversation(agent: .claude, id: "planning")] }
        }
        defer { r.h.cleanUp() }
        let task = try #require(id)
        for signal in [try #require(later), try #require(keep)] {
            let configuration = try #require(r.h.workspace.state.signal(id: signal))
            r.h.workspace.mutate { $0.updateSignalTask(task) { $0.pendingStages.append(SignalStage(signal: signal, item: $0.current.item, matchedAt: r.world.now, configuration: configuration, prompt: "Next.")) } }
        }
        try await r.stages.finish(task, action: .finish(.operatorJudges))
        #expect(r.record(task)?.phase == .choosing && r.record(task)?.choosableRows == [SignalWorld.agent, Self.sonnet])
        #expect(await r.choose(task, key: "c1", row: Self.codex).message?.contains("choosableRows") == true)
        #expect(await r.choose(task, key: "c2", row: Self.sonnet, reason: "A review needs less depth.").value?["status"] == "chosen")
        #expect(r.launched.map(\.2) == ["claude-sonnet-5-5"])
        r.h.workspace.mutate { $0.updateSignalTask(task) { $0.phase = .working } }
        try await r.stages.finish(task, action: .finish(.operatorJudges))
        #expect(r.launched.map(\.2) == ["claude-sonnet-5-5", "claude-opus-5-5"] && r.record(task)?.choice == nil)
        #expect(r.oracle.prompts.count == 1, "One Claude row for a Claude conversation: no proposal, no round.")
    }

    @Test func oneCallSettlesBothTheProjectAndTheRowAndAProjectAloneNeedsNoOracle() async throws {
        var second = Project.make(name: "shop-admin", path: "/synthetic/admin", provider: .gitlab, remoteUrl: "git@git.example:shop/admin.git")
        let (r, signal) = try rig { world in
            second.jiraProjects = world.project.jiraProjects; world.state.append(project: second)
        }
        defer { r.h.cleanUp() }
        let id = try #require(r.route(signal).first)
        #expect(r.record(id)?.phase == .choosing && r.record(id)?.candidateProjects?.count == 2)
        #expect(await r.choose(id, key: "c0", row: Self.codex).message?.contains("candidates") == true)
        let answer = await r.choose(id, key: "c1", row: Self.codex, project: second.id, reason: "The admin repository holds this screen.")
        let asked = try #require(try r.asked.first)
        #expect(answer.value?["status"] == "chosen" && asked["candidateProjects"]?.arrayValue?.count == 2 && asked["project"]?["id"]?.stringValue == second.id.uuidString)
        #expect(r.h.workspace.state.task(id: id)?.projectId == second.id && r.launched.map(\.1) == [.codex])

        let (alone, single) = try rig(agents: [SignalWorld.agent]) { world in
            second.jiraProjects = world.project.jiraProjects; world.state.append(project: second)
        }
        defer { alone.h.cleanUp() }
        let task = try #require(alone.route(single).first)
        #expect(alone.record(task)?.phase == .choosing && alone.record(task)?.choosableRows == [SignalWorld.agent])
        let entries = SidebarModel.entries(state: alone.h.workspace.state, sessions: [], branchByCwd: [:], projectBranch: [:])
        #expect(SignalSidebar(state: alone.h.workspace.state, entries: entries).signals.first?.tasks.first?.operatorLine?.text == "Operator choosing its project")
        let picked = await alone.call("choose_agent", task, key: "p", ["project": .string(second.id.uuidString), "reason": "The admin repository."])
        #expect(picked.value?["decided"] == "operatorAlone" && alone.oracle.prompts.isEmpty && alone.launched.count == 1)
    }

    @Test func twoRowsAndThreeTicketsStartThreeWorkersWithoutEverNeedingThePerson() async throws {
        let (r, signal) = try rig(); defer { r.h.cleanUp() }
        func noOneNeedsThePerson() {
            let state = r.h.workspace.state
            #expect(!state.allSignalTasks.contains { $0.signalTask?.phase == .blocked })
            let rows = SignalSidebar(state: state, entries: SidebarModel.entries(state: state, sessions: [], branchByCwd: [:], projectBranch: [:])).signals.flatMap(\.tasks)
            #expect(rows.count == 3 && rows.allSatisfy { $0.status != .needsInput && $0.operatorLine?.look != .needsYou })
            #expect(SignalOperatorRowValue.make(state: state, sessions: []).status != .needsInput)
        }
        let ids = r.route(signal, ["PAY-1", "PAY-2", "PAY-3"])
        #expect(ids.count == 3); noOneNeedsThePerson()
        for (index, id) in ids.enumerated() {
            let row = index == 0 ? SignalWorld.agent : Self.codex
            #expect(await r.choose(id, key: "c\(index)", row: row, reason: "Reason \(index).").value?["status"] == "chosen")
            noOneNeedsThePerson()
        }
        #expect(r.launched.count == 3)
        for (index, id) in ids.enumerated() { #expect(try r.journal(id).contains { $0.hasPrefix("Agent row:") && $0.contains("Reason \(index).") }) }
    }

    @Test func aWorkTabOnSeveralRowsIsCheckedByTheOracleBeforeItOpens() async throws {
        var id: UUID?
        let (r, _) = try rig { world in
            let signal = world.signal(name: "Work", agents: [SignalWorld.agent, Self.codex]); id = world.workingTask(signal: signal)
        }
        defer { r.h.cleanUp() }
        let task = try #require(id)
        r.answers = [.critique("NO: Codex is at 95%.")]
        var extra: [String: JSONValue] = ["agent": "codex", "model": .string(Self.codex.model), "reasoning": "medium", "prompt": "Review the edge.", "why": "A second pair of eyes."]
        let first = await r.call("open_tab", task, key: "second", extra)
        #expect(first.value?["status"] == "challenged" && r.tabs.isEmpty)
        let asked = try #require(try r.asked.first)
        #expect(asked["choosing"] == "the agent row for a new work tab" && asked["brief"] == "Review the edge.", "The Oracle judges the row against the tab's own work.")
        extra = ["agent": "claude", "model": .string(SignalWorld.agent.model), "reasoning": "high", "prompt": "Review the edge.", "why": "Claude has room.",
                 "challengeId": first.value!["challengeId"]!]
        #expect(await r.call("open_tab", task, key: "third", extra).value?["status"] == "opened")
        #expect(r.tabs.map(\.0) == ["third"] && r.tabs.first?.1 == SignalWorld.agent)
        #expect(try r.journal(task).contains { $0.hasPrefix("Work tab third: Agent row: Claude") })
    }

    @Test func aFallbackWorkTabCarriesTheFallbackReasonNotTheRejectedOne() async throws {
        var id: UUID?
        let (r, _) = try rig { world in
            let signal = world.signal(name: "Work", agents: [SignalWorld.agent, Self.codex]); id = world.workingTask(signal: signal)
        }
        defer { r.h.cleanUp() }
        let task = try #require(id)
        r.answers = [.critique("NO 1"), .critique("NO 2"), .critique("NO 3")]
        var challenge: JSONValue?
        for key in ["t1", "t2", "t3"] {
            var extra: [String: JSONValue] = ["agent": "codex", "model": .string(Self.codex.model), "reasoning": "medium", "prompt": "Review.", "why": "Codex has more quota."]
            if let challenge { extra["challengeId"] = challenge }
            challenge = await r.call("open_tab", task, key: key, extra).value?["challengeId"]
        }
        #expect(r.tabs.map(\.1) == [SignalWorld.agent])
        #expect(r.tabReasons.first?.hasPrefix("The Operator proposed Codex") == true)
    }
    @Test func resumeKeepsTheDecidedRowAndAChangeGoesThroughTheChoice() async throws {
        var id: UUID?
        let (r, _) = try rig { world in
            let signal = world.signal(name: "Work", agents: [SignalWorld.agent, Self.codex]); id = world.workingTask(signal: signal)
            world.state.updateSignalTask(id!) { $0.phase = .blocked; $0.blockedReason = "Its worker did not start." }
            world.state.updateSignalItem(id!) { $0.windowId = nil }
        }
        defer { r.h.cleanUp() }
        let task = try #require(id)
        #expect(await r.call("resume_task", task, key: "r0", ["agent": "codex", "model": .string(Self.codex.model), "reasoning": "medium"]).message?.contains("choose_agent") == true)
        #expect(await r.call("resume_task", task, key: "r1", [:]).value?["status"] == "resumed")
        #expect(r.launched.map(\.1) == [.claude])
        r.h.workspace.mutate { $0.updateSignalTask(task) { $0.phase = .blocked } }
        #expect(await r.choose(task, key: "c1", row: Self.codex).value?["status"] == "chosen")
        #expect(r.launched.map(\.1) == [.claude, .codex] && r.oracle.prompts.count == 1)

        let (other, signal) = try rig(); defer { other.h.cleanUp() }
        let choosing = try #require(other.route(signal).first)
        #expect(await other.call("resume_task", choosing, key: "r", [:]).message?.contains("choose_agent") == true)
    }

    @Test func aTakeOverDuringTheOracleRoundRefusesTheLateChoice() async throws {
        let (r, signal) = try rig(); defer { r.h.cleanUp() }
        let id = try #require(r.route(signal).first)
        let entered = TestLatch(), release = TestLatch()
        let held = ScriptedOracle(r.h.workspace, folder: r.h.folder, now: { r.world.now }) { _ in
            entered.signal(); await release.wait(); return .critique("YES")
        }
        let rounds = AgentChoiceRounds(workspace: r.h.workspace, now: { r.world.now }, oracle: held.consult, ports: .init(
            weeklyUsage: { [:] }, installedAgents: { [.claude, .codex] }))
        let task = try #require(r.h.workspace.state.task(id: id))
        let pending = Task { try await rounds.decide(task: task, scope: .stage, rows: [SignalWorld.agent, Self.codex], projects: nil,
                                                     proposal: .init(row: Self.codex, project: nil, reason: "r"), challenge: nil) }
        await entered.wait()
        r.h.workspace.mutate { $0.takeOver(id) }
        release.signal()
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(r.launched.isEmpty)
    }
}
