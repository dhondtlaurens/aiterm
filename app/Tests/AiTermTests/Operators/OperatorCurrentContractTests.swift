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

    /// The frozen broadcast saves back with none of plan F's keys on its run, its questions or its challenges: a field
    /// at its default is never written, so a state that never uses them keeps its bytes.
    @Test func theSavedBroadcastSavesBackWithNoneOfTheQuestionRecordsNewKeys() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let saved = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(try Self.load().runs))
        guard case .array(let runs) = saved else { Issue.record("runs save as a list"); return }
        func keys(_ value: JSONValue?) -> Set<String> { if case .object(let fields)? = value { Set(fields.keys) } else { [] } }
        func items(_ value: JSONValue?) -> [JSONValue] { if case .array(let items)? = value { items } else { [] } }
        let question: Set<String> = ["holds", "choices", "answeredHere", "answeredHereAt", "relayedFrom", "history"]
        for run in runs {
            #expect(!keys(run).contains("relayCheck"))
            for saved in items(run["questions"]) { #expect(keys(saved).isDisjoint(with: question)) }
            for saved in items(run["challenges"]) { #expect(!keys(saved).contains("round")) }
        }
    }

    /// The frozen save, loaded and saved again by today's code, is the same file byte for byte: no field is dropped,
    /// renamed, reordered or newly written on the way through. A change to how the records are coded shows here first.
    @Test func theFrozenSaveSavesBackToItsOwnBytes() throws {
        let scratch = try ScratchFolder.make()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = StateStore(url: scratch.appendingPathComponent("state.json"))
        try store.save(try Self.load())
        let saved = try Data(contentsOf: store.url), frozen = try Data(contentsOf: Self.folder.appendingPathComponent("state.json"))
        #expect(saved == frozen, "The frozen broadcast no longer saves back to its own bytes.")
    }

    /// A run and a task with nothing but what their initialisers require, and with every stored field set, save as the
    /// files in `Fixtures/operator-records` and load back equal: what each field writes, and what it leaves out at its
    /// default, in both directions. The frozen save never sets most of the fields added since it was captured.
    @Test(arguments: ["sparse", "full"]) func operatorRecordsSaveAsTheirFixtureAndLoadBackEqual(name: String) throws {
        let records = name == "sparse" ? OperatorRecords.sparse : OperatorRecords.full
        let file = Self.folder.deletingLastPathComponent().appendingPathComponent("operator-records/\(name).json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let saved = try encoder.encode(records)
        guard let expected = try? Data(contentsOf: file), saved == expected else {
            // For reading the difference, never an update mode: the fixture changes only by a decision about the format.
            let actual = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-operator-records-\(name).json")
            try saved.write(to: actual)
            Issue.record("\(name) no longer saves as its fixture; what it saved is at \(actual.path)")
            return
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(OperatorRecords.self, from: expected) == records)
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
        tools.vet(ToolCall(tool: "check_goal", arguments: missing))
        checkpoints["plan-more"] = await call("check_goal", missing)
        await status("additional-round")
        let met: JSONValue = ["met": true, "evidence": "The release is verified; no more task is needed."]
        tools.vet(ToolCall(tool: "check_goal", arguments: met))
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

    static let savedFormat = folder.deletingLastPathComponent().appendingPathComponent("operator-saved-format/state.json")

    /// The frozen broadcast with a publication problem of each kind, as today's writers record them: the saved format
    /// with phase 4's one new key, `problemKind`, beside each problem.
    static func savedFormatState() throws -> AppState {
        var state = try load()
        let problems: [(key: String, problem: String, kind: TaskPublication.ProblemKind)] = [
            ("SHOP-2", TaskEndChange.mergeWaitsForFinish, .hold), ("SHOP-3", "The pipeline failed.", .failure),
            ("SHOP-4", PublicationGuard.mergeSliceOff, .permanent),
        ]
        for (key, problem, kind) in problems {
            let id = try #require(state.tasks.first { $0.operated?.key == key }?.id)
            state.updateOperated(id) {
                var publication = $0.publication ?? TaskPublication()
                publication.setProblem(problem, kind: kind)
                $0.publication = publication
            }
        }
        return state
    }

    /// The saved format after its one change (`Fixtures/operator-saved-format`, captured once, see its provenance): the
    /// frozen broadcast with a problem of each kind saves as that file, the file saves back to its own bytes, and each
    /// problem reads back as the kind it was written with.
    @Test func theSavedFormatSavesAsItsFixtureAndBackToItsOwnBytes() throws {
        let scratch = try ScratchFolder.make()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = StateStore(url: scratch.appendingPathComponent("state.json"))
        try store.save(try Self.savedFormatState())
        let saved = try Data(contentsOf: store.url)
        guard let fixture = try? Data(contentsOf: Self.savedFormat), saved == fixture else {
            // For reading the difference, never an update mode: the fixture was captured once.
            let actual = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-operator-saved-format.json")
            try saved.write(to: actual)
            Issue.record("The saved format no longer saves as its fixture; what it saved is at \(actual.path)")
            return
        }
        let loaded = try StateStore(url: Self.savedFormat).load()
        try store.save(loaded)
        #expect(try Data(contentsOf: store.url) == fixture, "The saved-format fixture no longer saves back to its own bytes.")
        let kinds = Dictionary(uniqueKeysWithValues: loaded.tasks.compactMap { task in
            task.operated.flatMap { operated in operated.publication?.problemKind.map { (operated.key, $0) } }
        })
        #expect(kinds == ["SHOP-2": .hold, "SHOP-3": .failure, "SHOP-4": .permanent])
    }

    /// A save from before the kind was kept, the frozen broadcast among them, loads with each problem's kind read from its
    /// wording: the saved-format fixture with its kinds taken out reads every problem as the kind it was written with.
    @Test func aSaveWithoutTheKindReadsEachProblemByItsWording() throws {
        func strip(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let fields): .object(fields.filter { $0.key != "problemKind" }.mapValues(strip))
            case .array(let items): .array(items.map(strip))
            default: value
            }
        }
        let scratch = try ScratchFolder.make()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let legacy = scratch.appendingPathComponent("state.json")
        try JSONEncoder().encode(strip(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.savedFormat)))).write(to: legacy)
        let state = try StateStore(url: legacy).load()
        let read = Dictionary(uniqueKeysWithValues: state.tasks.compactMap { task in
            task.operated.flatMap { operated in operated.publication?.problemOutcome.map { (operated.key, $0) } }
        })
        #expect(read == ["SHOP-2": .hold, "SHOP-3": .failure, "SHOP-4": .permanent])
        #expect(state.tasks.allSatisfy { $0.operated?.publication?.problemKind == nil })
        let frozen = try Self.load()
        #expect(frozen.tasks.allSatisfy { task in
            task.operated?.publication.map { $0.problemOutcome == $0.problem.map(TaskPublication.ProblemKind.init(matching:)) } ?? true
        })
    }
}

/// A run and one of its tasks as the workspace file holds them, for `operatorRecordsSaveAsTheirFixtureAndLoadBackEqual`.
/// `full` sets every stored field of every Operator record to something other than its default; a field added to a
/// record is added here and to the fixture, by a decision about the saved format.
struct OperatorRecords: Codable, Equatable {
    var run: OperatorRun
    var task: OperatedTask

    private static let at = Date(timeIntervalSince1970: 1_800_000_000)
    private static func id(_ n: Int) -> UUID { UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", n))")! }
    private static let sha = "1111111111111111111111111111111111111111", other = "2222222222222222222222222222222222222222"

    static let sparse = OperatorRecords(
        run: OperatorRun(id: id(1), name: "Sparse", profile: OperatorProfile(model: "claude-opus-5-5", reasoning: nil),
                         prompt: "Do the work.", createdAt: at),
        task: OperatedTask(runId: id(1), key: "sparse", brief: "Do the work.", revision: 1))

    static let full = OperatorRecords(run: fullRun, task: fullTask)

    private static var fullRun: OperatorRun {
        var question = OperatorQuestion(id: "ask-1", text: "Which copy?", task: id(3), askedAt: at, resolution: "The short one.",
                                        tab: "docs", gate: GateRequest(command: "git push", directory: "/repo"),
                                        answeredInWindow: "Use the short one", withdrawn: true, about: OperatorQuestion.fixRounds,
                                        answeredOnCard: "oneMoreRound", holds: false, choices: ["Short", "Long"],
                                        answeredHere: "Short", answeredHereAt: at.addingTimeInterval(60), relayedFrom: "main",
                                        history: [QuestionStep(kind: .asked, text: "Short or long?", at: at),
                                                  QuestionStep(kind: .oracle, text: "Only the person knows.", at: at, round: 1)])
        question.answeredOnCard = "oneMoreRound"
        var challenge = ChallengeRecord(id: "challenge-1", tool: "finish_task", kind: .veto, stage: .acted, critique: "Looks right.",
                                        approved: true, askedArguments: "{\"task\":\"full\"}", askedSHA: sha,
                                        unchallengedReason: "The Oracle was too slow.", actedArguments: "{\"task\":\"full\"}",
                                        result: "{\"merged\":true}", askedAt: at, askedMerge: true, askedEvidence: "checks: green", round: 2)
        challenge.reply = "It stays as it is."
        var run = OperatorRun(
            id: id(2), name: "Full",
            profile: OperatorProfile(model: "claude-opus-5-5", reasoning: "high", slices: Slices(jira: true, review: true, merge: true),
                                     oracle: OracleSetting(isOn: true, agent: .codex, model: "gpt-6-astra", reasoning: "medium"),
                                     instructions: "House rules."),
            projectIds: [id(10)], jiraProjectKeys: ["PLUTO"], prompt: "Ship it.", state: .complete, intent: .paused,
            planRevision: 3, firstPlanSize: 4, questions: [question],
            decisions: [OperatorDecision(key: "decision-1", text: "Split the task.", task: id(3), at: at, challenge: "Why split?",
                                         why: "Two owners.", objection: "One would do.")],
            finds: [OffBriefFind(key: "find-1", title: "Stale cache", why: "Seen while testing.", ticket: "PLUTO-9")],
            snags: [OperatorSnag(key: "snag-1", title: "Wrong count", showed: "2 ahead", actual: "3 ahead", workaround: "Read git.",
                                 evidence: "git rev-list", task: id(3), taskKey: "full", branch: "feat/full", appVersion: "0.45.0", at: at)],
            leftForYou: ["Rotate the key."], operatorConversation: "conversation-operator", operatorWindowId: "window-operator",
            operatorSessionId: "session-operator", challenges: [challenge], jiraCreated: ["create-1": "PLUTO-10"],
            threadReplies: ["reply-1": "thread-7"], pendingWrites: ["jira_create/create-2"], createdAt: at,
            summary: "All merged.", summaryAt: at.addingTimeInterval(120), completedAt: at.addingTimeInterval(90),
            summaryGivenUp: true, endedAt: at.addingTimeInterval(180),
            agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high"),
                     AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: nil)],
            taskSettings: TaskSettings(review: "Review the diff.", end: .merge, closeWhenDone: false, deleteMergedBranch: true),
            goal: BroadcastGoal(text: "The release is verified.", extraRounds: 3))
        run.leftForYouRecords = ["leave-1": "Rotate the key."]
        run.jiraSprinted = ["sprint-1": "backlog"]
        run.jiraCommented = ["comment-1": "10042"]
        run.gateAllowances = [GateRequest(command: "git push", directory: "/repo")]
        run.goalCheckDue = true
        run.roundsUsed = 2
        run.goalChecks = [GoalCheck(round: 1, met: false, evidence: "One check is missing.", missing: ["Verify the release."],
                                    oracleAgreed: true, at: at)]
        run.goalOutcome = .notMet
        run.revisionAtLastCheck = 2
        var finished = FinishedTaskRecord(task: id(4), key: "done", title: "Done", ticket: "PLUTO-1", project: id(10), agent: .codex,
                                          model: "gpt-6-astra", reasoning: "medium", end: .merge, state: .published, acceptedSHA: sha,
                                          branch: "feat/done", mergeRequestURL: "https://example.com/mr/1", mergedSHA: other,
                                          result: "merged", branchDeleted: true, at: at)
        finished.diffBaseSHA = other
        run.finished = [finished]
        run.closedAt = at.addingTimeInterval(200)
        run.pausedWorkers = [PausedWorker(task: id(3), tab: "docs", ownership: 1)]
        run.relayCheck = .agreeFirst
        return run
    }

    private static var fullTask: OperatedTask {
        var publication = TaskPublication(pushedSHA: sha, mergeRequestURL: "https://example.com/mr/2", mergeRequestNumber: 2,
                                          targetBranch: "main", waitingSince: at, readySince: at.addingTimeInterval(30), merged: true,
                                          mergedSHA: other, mergedHead: sha, problem: "The pipeline failed.", conditionsHeld: sha,
                                          repository: "example.com/pluto/web", leftForYou: true, waitingReason: "Waiting for checks.",
                                          mergeRefusal: "The Oracle said no.", lastPushFailure: "lint failed", lastPushFailureSHA: sha,
                                          landedSHA: sha)
        publication.conditionsEvidence = "checks: green"
        // Added by decision with the plan's one saved-format change (2026-11-10, phase 4).
        publication.setProblem("The pipeline failed.", kind: .failure)
        publication.requested = RequestContent(title: "Add the block", description: "What and why.", assignee: "someone")
        publication.assigning = true
        publication.assignee = "someone"
        publication.unanswered = sha
        var work = ExtraTab(key: "docs", agent: .codex, model: "gpt-6-astra", reasoning: "medium", modelReason: "Cheap enough.",
                            brief: "Write the docs.", agentPinned: true,
                            launch: LaunchAttempt(number: 2, requestedAt: at, openedAt: at.addingTimeInterval(5), workerPending: true),
                            sessionId: "session-docs", failure: "The daemon refused.", conversation: "conversation-docs", role: .work)
        work.requestedLaunch = LaunchRequest(model: "gpt-6-astra", reasoning: "medium")
        let review = ExtraTab(key: "review-1", agent: .claude, model: "claude-opus-5-5", reasoning: nil, modelReason: "Careful.",
                              brief: "Review the head.", launch: LaunchAttempt(number: 1, requestedAt: at), role: .review)
        var task = OperatedTask(
            runId: id(2), key: "full", state: .blocked, end: .merge, brief: "Add the block.",
            dependsOn: [TaskDependency(task: id(5), kind: .code), TaskDependency(task: id(6), kind: .order)], stackedOn: id(5),
            revision: 3, firstRevision: 1,
            acceptance: TaskAcceptance(resultSHA: sha, prerequisiteSHAs: [other], checkOutput: "42 passed", note: "Clean.", at: at),
            publication: publication, takenOver: true, ownership: 2,
            launch: LaunchAttempt(number: 3, requestedAt: at, openedAt: at.addingTimeInterval(4), workerPending: false),
            retriesUsed: 1, runtimeUsed: 120, totalRuntimeUsed: 300, runtimeHead: sha,
            blockedReason: "Its parent failed.", blockedFrom: .working, flags: Set(OperatedFlag.allCases),
            lastFailure: "The build broke.", modelReason: "Hard change.", agentPinned: true, problem: "issue-12",
            agentReview: AgentReviewResult(agent: .codex, instructions: "Read the diff.", head: sha, startedAt: at,
                                           findings: "Nothing blocking.", failure: "Timed out once.", at: at.addingTimeInterval(40)),
            peopleReview: PeopleReview(reviewers: ["someone"], threads: ["thread-7": true], notes: ["thread-7": "someone:abc"],
                                       approvals: ["someone"], ended: true, startedAt: at),
            branchDrift: BranchDrift(source: .lastMessage, branch: "feat/elsewhere", sha: other, found: "It committed elsewhere."),
            extraTabs: [work, review], reopenedFrom: other,
            reviewVerdicts: [ReviewVerdict(tab: "review-1", sha: sha, passed: false, round: 1, rounds: 2, critical: 1, important: 2,
                                           minor: 3, summary: "One blocker.", at: at, key: "verdict-1")])
        task.requestedLaunch = LaunchRequest(model: "claude-opus-5-5", reasoning: "high")
        task.keptReason = "Unsaved work in its worktree."
        task.closingWait = .agentTurn
        task.diffBaseSHA = other
        task.acceptanceWorktreeFingerprint = "fingerprint-1"
        task.threadCritiques = [ThreadCritique(thread: "thread-7", note: "someone:abc", head: sha, critique: "Answer it.", at: at)]
        return task
    }
}
