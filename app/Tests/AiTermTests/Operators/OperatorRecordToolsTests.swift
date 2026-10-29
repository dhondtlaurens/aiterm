import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The Operator's read and record tools (spec §6): run_status, its questions, decisions, finds, snags and summary, and what
/// every tool call shares, answered from the workspace.
@MainActor @Suite struct OperatorRecordToolsTests {
    let pluto = JiraProjectRef(id: "1", key: "PLUTO", name: "Pluto", siteURL: URL(string: "https://acme.atlassian.net")!)
    let project: Project
    init() { project = OperatorServiceFixtures.project(jira: [pluto]) }
    /// The world these tests read Jira in. Its Jira budget is long: the fake answers at once, and a loaded machine (a full
    /// run's main-actor tests) must never turn a read that succeeds into Jira not answering. The budget's own test sets a
    /// short one of its own.
    func makeWorld(_ run: OperatorRun, jira: FakeJira? = nil) throws -> OperatorWorld {
        try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { ports in
            if let jira { ports.jira = { jira } }
            ports.jiraSearchBudget = .seconds(600)
        }
    }

    @Test func runStatusIsNumberedByWhatChanged() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "run_status").value?["revision"] == 1)
        #expect(await world.call(run.id, "run_status").value?["revision"] == 1)
        _ = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale is the default?"])
        #expect(await world.call(run.id, "run_status").value?["revision"] == 2)
    }

    @Test func askingTwiceWithOneKeyKeepsOneQuestionNotifiesOnceAndResolvingClosesIt() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        let first = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale is the default?"])
        let again = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale, again?"])
        #expect(first.value?["open"] == true && again.value?["open"] == true)
        #expect(world.run(run.id)?.questions.map(\.text) == ["Which locale is the default?"])
        #expect(world.notifications.posted.map(\.body) == ["The Operator asks: Which locale is the default?"])
        let resolved = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "nl-BE"])
        #expect(world.notifications.withdrawn == ["request-\(run.id.uuidString)-question-locale"])
        #expect(resolved.value?["open"] == false)
        #expect(world.run(run.id)?.questions.first?.resolution == "nl-BE")
        #expect(await world.call(run.id, "resolve_question", ["key": "nope", "summary": "x"]).message == "No question nope in this broadcast.")
    }

    @Test func aDecisionIsWrittenOncePerKey() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        for _ in 0..<2 {
            _ = await world.call(run.id, "log_decision", ["key": "d1", "text": "Kept the old endpoint."])
        }
        #expect(world.run(run.id)?.decisions.map(\.text) == ["Kept the old endpoint."])
    }

    /// The Operator writes the summary once the broadcast is complete; the run keeps it with the time it came.
    @Test func writeSummaryIsRefusedBeforeComplete() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "write_summary", ["text": "Done."]).message == "The broadcast isn\u{2019}t complete yet.")
        #expect(world.run(run.id)?.summary == nil && world.run(run.id)?.summaryAt == nil)
    }

    @Test func writeSummaryStoresIt() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .complete)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { $0.now = { at } }
        let answer = await world.call(run.id, "write_summary", ["text": "  Two tasks merged; one needed a retry.\n"])
        #expect(answer.value?["written"] == true)
        #expect(world.run(run.id)?.summary == "Two tasks merged; one needed a retry.", "surrounding whitespace is trimmed")
        #expect(world.run(run.id)?.summaryAt == at)
    }

    @Test func writeSummaryAgainReplacesIt() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .complete)
        let world = try makeWorld(run)
        _ = await world.call(run.id, "write_summary", ["text": "First."])
        _ = await world.call(run.id, "write_summary", ["text": "Second."])
        #expect(world.run(run.id)?.summary == "Second.")
    }

    @Test func writeSummaryNeedsText() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .complete)
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "write_summary", [:]).message == "write_summary needs `text`.")
        #expect(await world.call(run.id, "write_summary", ["text": "  \n "]).message == "write_summary needs `text`.")
        #expect(world.run(run.id)?.summary == nil)
    }

    /// The summary is a change the Operator has seen: the call counts as its own news, so the wake does not echo it.
    @Test func writeSummaryIsAMutatingTool() {
        #expect(OperatorToolHandler.mutating.contains(.writeSummary))
    }

    /// An off-brief find goes to the summary, once per key, and run_status shows it.
    @Test func reportFindRecordsIt() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        let find = ["key": "leak", "title": "A token in the payments log", "why": "Anyone with log access can pay as the shop."] as JSONValue
        let answer = await world.call(run.id, "report_find", find)
        #expect(answer.value?["find"] == "leak" && answer.value?["recorded"] == true)
        _ = await world.call(run.id, "report_find", ["key": "leak", "title": "Again", "why": "Again."])
        #expect(world.run(run.id)?.finds == [OffBriefFind(key: "leak", title: "A token in the payments log",
                                                          why: "Anyone with log access can pay as the shop.")])
        #expect(await world.call(run.id, "run_status").value?["run"]?["finds"]?.arrayValue?.first?["key"] == "leak")
        #expect(await world.call(run.id, "report_find", ["key": "x", "title": "t"]).message == "report_find needs `why`.")
    }

    /// AiTerm's own mistake is recorded once per key, with the task's key and branch and the app's version, and
    /// run_status lists it by key and title.
    @Test func reportSnagRecordsItOnceAndRunStatusListsIt() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PAY-240", state: .working)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { $0.appVersion = "0.28.0" }
        let snag = ["key": "stale-prompt", "title": "A prompt shows as working", "showed": "The row said working.",
                    "actual": "The worker was waiting on a prompt.", "workaround": "Answered it in its tab.",
                    "evidence": "Tab 2 showed Allow edits?", "task": "PAY-240"] as JSONValue
        let answer = await world.call(run.id, "report_snag", snag)
        #expect(answer.value?["snag"] == "stale-prompt" && answer.value?["recorded"] == true)
        _ = await world.call(run.id, "report_snag", ["key": "stale-prompt", "title": "Again", "showed": "s", "actual": "a", "workaround": "w"])

        let recorded = try #require(world.run(run.id)?.snags)
        #expect(recorded.count == 1)
        #expect(recorded.first?.title == "A prompt shows as working" && recorded.first?.evidence == "Tab 2 showed Allow edits?")
        #expect(recorded.first?.task == task.id && recorded.first?.taskKey == "PAY-240" && recorded.first?.branch == "feat/pay-240")
        #expect(recorded.first?.appVersion == "0.28.0")

        let listed = await world.call(run.id, "run_status").value?["run"]?["snags"]?.arrayValue
        #expect(listed == [["key": "stale-prompt", "title": "A prompt shows as working"]])
        let missing = await world.call(run.id, "report_snag", ["key": "x", "title": "t", "showed": "s", "workaround": "w"])
        #expect(missing.message == "report_snag needs `actual`.")
    }

    /// The Operator says why in a sentence, and the summary shows it under the decision.
    @Test func aDecisionCarriesItsWhy() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        _ = await world.call(run.id, "log_decision", ["key": "d1", "text": "Added Retry failed payments (PAY-240)",
                                                      "why": "The provider switch left failed payments with no retry."])
        _ = await world.call(run.id, "log_decision", ["key": "d2", "text": "Kept the old endpoint."])
        let decisions = try #require(world.run(run.id)?.decisions)
        #expect(decisions.map(\.why) == ["The provider switch left failed payments with no retry.", nil])
    }

    /// The Operator decided against the Oracle: the decision keeps the objection.
    @Test func aDecisionCarriesTheObjectionItOverruled() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        _ = await world.call(run.id, "log_decision", ["key": "d1", "text": "Kept one task.", "objection": "It is two changes."])
        #expect(world.run(run.id)?.decisions.first?.objection == "It is two changes.")
    }

    /// The model rule needs each installed agent's own list and its default (spec §15).
    @Test func runStatusListsEachInstalledAgentsModels() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { $0.installedAgents = { [.codex] } }
        let agents = try #require(await world.call(run.id, "run_status").value?["run"]?["agents"])
        #expect(agents["claude"] == nil, "an agent not installed is left out")
        #expect(agents["codex"]?["models"] == ["gpt-6-astra", "gpt-6-mini"])
        let fallback = world.controller.tools.defaultModel(for: .codex)
        #expect(agents["codex"]?["defaultModel"]?.stringValue == fallback.model)
    }

    @Test func finishTaskIsAToolAndAnUnknownToolOrRunIsAnError() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "finish_task", ["task": "x"]).message == "No task x in this broadcast.")
        #expect(await world.call(run.id, "merge_everything").message == "AiTerm has no tool called merge_everything.")
        #expect(await world.call(UUID(), "run_status").message == "This broadcast is no longer in AiTerm.")
    }

    @Test func aRequestIsAnsweredThroughTheDaemonWithItsId() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        world.controller.handle(.operatorRequest(OperatorRequest(requestId: "r7", runId: run.id.uuidString, tool: "merge_everything", arguments: [:])))
        await world.controller.tools.lastReply?.value
        let reply = try #require(world.daemon.requests("operator.reply").first)
        #expect(reply.params["requestId"] as? String == "r7")
        #expect(reply.params["error"] as? String == "AiTerm has no tool called merge_everything.")
        #expect(reply.params["result"] == nil)
    }

    /// A started task of `run`, as an operator names it by its key.
    func workingTask(in run: OperatorRun, key: String = "T1") -> TaskItem {
        OperatorServiceFixtures.task(in: run, project: project, key: key, state: .working, worktree: "/tmp/aiterm-operators-wt-\(key)")
    }

    func makeWorld(_ run: OperatorRun, tasks: [TaskItem]) throws -> OperatorWorld {
        try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: tasks))
    }

    @Test func aQuestionAboutATaskMarksItWaitingOnYouUntilNoneOfItsQuestionsIsOpen() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = workingTask(in: run)
        let world = try makeWorld(run, tasks: [task])
        func waiting() -> Bool { world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == true }
        _ = await world.call(run.id, "ask_you", ["key": "a", "question": "First?", "task": "T1"])
        _ = await world.call(run.id, "ask_you", ["key": "b", "question": "Second?", "task": .string(task.id.uuidString)])
        #expect(waiting())
        #expect(world.run(run.id)?.questions.map(\.task) == [task.id, task.id])
        _ = await world.call(run.id, "resolve_question", ["key": "a", "summary": "yes"])
        #expect(waiting())
        _ = await world.call(run.id, "resolve_question", ["key": "b", "summary": "no"])
        #expect(!waiting())
    }

    /// A worker's prompt is AiTerm's to close, when its worker leaves the prompt; a merge on the host is the person's to
    /// decide, so the Operator closes that question once the person has answered in its chat.
    @Test func aPromptIsAiTermsToCloseAndAMergeOnTheHostIsClosedOnceThePersonAnswers() async throws {
        var run = OperatorServiceFixtures.run(projects: [project])
        let prompted = workingTask(in: run), merged = workingTask(in: run, key: "T2")
        let prompt = OperatorQuestion(id: "prompt-\(prompted.id.uuidString)-1", text: "Claude asks to run npm install", task: prompted.id, askedAt: Date(timeIntervalSince1970: 0))
        let merge = OperatorQuestion(id: "merged-on-host-\(merged.id.uuidString)", text: "The host merged it.", task: merged.id, askedAt: Date(timeIntervalSince1970: 0))
        run.questions = [prompt, merge]
        let world = try makeWorld(run, tasks: [prompted, merged])
        world.workspace.mutate { state in
            for id in [prompted.id, merged.id] { state.updateOperated(id) { $0.flags.insert(.waitingOnYou) } }
        }
        let refused = await world.call(run.id, "resolve_question", ["key": .string(prompt.id), "summary": "Done."])
        #expect(refused.message == "\(prompt.id) is a worker’s prompt: AiTerm closes its question itself once the worker leaves the prompt. If it looks stale, record it with report_snag.")
        let resolved = await world.call(run.id, "resolve_question", ["key": .string(merge.id), "summary": "Go on without PAY-14."])
        #expect(resolved.value?["open"] == false)
        #expect(world.run(run.id)?.questions.map(\.resolution) == [nil, "Go on without PAY-14."])
        #expect(world.task(prompted.id)?.operated?.flags.contains(.waitingOnYou) == true)
        #expect(world.task(merged.id)?.operated?.flags.contains(.waitingOnYou) == false, "its last open question")
    }

    @Test func askYouRefusesAiTermsQuestionKeys() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        for key in ["prompt-mine", "merged-on-host-mine", "gate-mine"] {
            #expect(await world.call(run.id, "ask_you", ["key": .string(key), "question": "Q?"]).message
                    == "Keys starting with “prompt-”, “merged-on-host-” or “gate-” are AiTerm’s own questions. Choose another key.")
        }
        #expect(world.run(run.id)?.questions.isEmpty == true)
    }

    @Test func askYouOnATaskSaysWhatThatDoes() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = workingTask(in: run)
        let world = try makeWorld(run, tasks: [task])
        let onTask = await world.call(run.id, "ask_you", ["key": "a", "question": "Stuck?", "task": "T1"])
        #expect(onTask.value?["note"] == "Your row in the sidebar now shows waiting on the person, naming this task, and they answer in this chat. The task waits: it isn't ready to accept and isn't watched for stalls until you resolve the question.")
        #expect(await world.call(run.id, "ask_you", ["key": "b", "question": "Which scope?"]).value?["note"] == nil)
    }

    /// A repeat of a key already resolved says so, and not that the task now waits on the person.
    @Test func askYouAgainOnAResolvedQuestionSaysNothingOfWaiting() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = workingTask(in: run)
        let world = try makeWorld(run, tasks: [task])
        _ = await world.call(run.id, "ask_you", ["key": "a", "question": "Stuck?", "task": "T1"])
        _ = await world.call(run.id, "resolve_question", ["key": "a", "summary": "No."])
        let again = await world.call(run.id, "ask_you", ["key": "a", "question": "Stuck?", "task": "T1"])
        #expect(again.value?["open"] == false)
        #expect(again.value?["note"] == nil)
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == false)
    }

    @Test func aRepeatedResolveReturnsTheRecordedResolution() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        _ = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale?"])
        _ = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "nl-BE"])
        let again = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "fr-BE"])
        #expect(again.value?["open"] == false)
        #expect(again.value?["resolution"] == "nl-BE")
        #expect(world.run(run.id)?.questions.first?.resolution == "nl-BE")
    }

    @Test func withdrawingAnOwnQuestionKeepsItsReasonAndStopsWaiting() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = workingTask(in: run)
        let world = try makeWorld(run, tasks: [task])
        _ = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale?", "task": "T1"])
        let answer = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "The worker no longer needs this.", "withdrawn": true])
        #expect(answer.value?["withdrawn"] == true && answer.value?["open"] == false)
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == false)
        #expect(world.notifications.withdrawn == ["request-\(run.id.uuidString)-question-locale"])
        let status = await world.call(run.id, "run_status")
        #expect(status.value?["obligations"]?["questionsWaiting"]?.arrayValue?.isEmpty == true)
        let saved = try JSONEncoder().encode(#require(world.run(run.id)))
        let restored = try JSONDecoder().decode(OperatorRun.self, from: saved)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(restored))
        #expect(json["questions"]?.arrayValue?.first?["withdrawn"] == true)
        #expect(restored.questions.first?.resolution == "The worker no longer needs this.")
        let again = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "Another reason.", "withdrawn": true])
        #expect(again.value == answer.value)
        let answered = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "Yes."])
        #expect(answered.value == answer.value)
    }

    @Test func withdrawingOneQuestionKeepsWaitingForTheOther() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = workingTask(in: run)
        let world = try makeWorld(run, tasks: [task])
        for key in ["a", "b"] {
            _ = await world.call(run.id, "ask_you", ["key": .string(key), "question": "Which locale?", "task": "T1"])
        }
        _ = await world.call(run.id, "resolve_question", ["key": "a", "summary": "Moot.", "withdrawn": true])
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == true)
    }

    @Test func withdrawalDoesNotReplaceAnAnswer() async throws {
        var run = OperatorServiceFixtures.run(projects: [project])
        run.questions = [OperatorQuestion(id: "window", text: "Locale?", task: nil, askedAt: Date(), answeredInWindow: "nl-BE")]
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "resolve_question", ["key": "window", "summary": "Moot.", "withdrawn": true]).message
                == "window may already be answered in its worker’s window; check it and resolve it as an answer.")
        #expect(world.run(run.id)?.questions.first?.resolution == nil)
        #expect(world.run(run.id)?.questions.first?.answeredInWindow == "nl-BE")
        _ = await world.call(run.id, "resolve_question", ["key": "window", "summary": "nl-BE"])
        let again = await world.call(run.id, "resolve_question", ["key": "window", "summary": "Moot.", "withdrawn": true])
        #expect(again.value?["resolution"] == "nl-BE" && again.value?["withdrawn"] == nil)
    }

    @Test func withdrawalRefusesAiTermsPromptAndHostMergeQuestions() async throws {
        var run = OperatorServiceFixtures.run(projects: [project])
        run.questions = ["prompt-worker-1", "merged-on-host-worker"].map {
            OperatorQuestion(id: $0, text: "Decide?", task: nil, askedAt: Date())
        }
        let world = try makeWorld(run)
        for question in run.questions {
            #expect(await world.call(run.id, "resolve_question", ["key": .string(question.id), "summary": "Moot.", "withdrawn": true]).message != nil)
        }
        #expect(world.run(run.id)?.questions == run.questions)
    }

    @Test func oldQuestionRecordsStillDecodeWithoutAWithdrawalMarker() throws {
        let data = Data(#"{"id":"old","text":"Locale?","askedAt":0,"resolution":"nl-BE"}"#.utf8)
        let question = try JSONDecoder().decode(OperatorQuestion.self, from: data)
        #expect(question.resolution == "nl-BE")
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(question))
        #expect(encoded["withdrawn"] != true)
    }

    @Test func withdrawalRefusesValuesThatAreNotBooleans() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        _ = await world.call(run.id, "ask_you", ["key": "locale", "question": "Locale?"])
        let invalid: [JSONValue] = ["true", 1, [], [:]]
        for value in invalid {
            let answer = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "Moot.", "withdrawn": value])
            #expect(answer.message == "withdrawn must be true or false.")
            #expect(world.run(run.id)?.questions.first?.resolution == nil)
        }
    }

    @Test func nullAndFalseWithdrawalFlagsStillRecordAnswers() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        for (key, value) in [("null", JSONValue.null), ("false", JSONValue.bool(false))] {
            _ = await world.call(run.id, "ask_you", ["key": .string(key), "question": "Locale?"])
            let answer = await world.call(run.id, "resolve_question", ["key": .string(key), "summary": "nl-BE", "withdrawn": value])
            #expect(answer.value?["resolution"] == "nl-BE" && answer.value?["withdrawn"] == nil)
        }
    }

    @Test func withdrawalNeedsAOneLineReason() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        _ = await world.call(run.id, "ask_you", ["key": "locale", "question": "Locale?"])
        #expect(await world.call(run.id, "resolve_question", ["key": "locale", "summary": "First.\nSecond.", "withdrawn": true]).message != nil)
        #expect(world.run(run.id)?.questions.first?.resolution == nil)
    }

    @Test func anEndedBroadcastsToolsDoNotAct() async throws {
        let stopped = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        let world = try makeWorld(stopped)
        let ended = "This broadcast has ended; its tools no longer act."
        #expect(await world.call(stopped.id, "ask_you", ["key": "k", "question": "Q?"]).message == ended)
        #expect(world.run(stopped.id)?.questions.isEmpty == true)
        // Ended by you, its state not yet caught up.
        let live = OperatorServiceFixtures.run(projects: [project])
        let second = try makeWorld(live)
        second.workspace.mutate { $0.updateRun(id: live.id) { $0.intent = .stopped } }
        #expect(await second.call(live.id, "run_status").message == ended)
    }

    @Test func aMissingArgumentOrAnUnknownTaskIsSaidPlainly() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "ask_you", ["key": "k"]).message == "ask_you needs `question`.")
        #expect(await world.call(run.id, "ask_you", ["key": "k", "question": "   "]).message == "ask_you needs `question`.")
        #expect(await world.call(run.id, "jira_search").message == "jira_search needs `jql`.")
        #expect(await world.call(run.id, "log_decision", ["key": "d", "text": "t", "task": "nope"]).message == "No task nope in this broadcast.")
        #expect(await world.call(run.id, "ask_you", ["key": "k", "question": "Q?", "task": "nope"]).message == "No task nope in this broadcast.")
        #expect(world.run(run.id)?.questions.isEmpty == true && world.run(run.id)?.decisions.isEmpty == true)
    }

    @Test func aToolThatActsOnATaskTellsWhenItStartsAndStops() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = workingTask(in: run)
        let world = try makeWorld(run, tasks: [task])
        var events: [String] = []
        world.controller.tools.onActing = { activity, on in
            events.append("\(activity.task == task.id ? "T1" : "?") \(activity.act.rawValue) \(on)")
        }
        _ = await world.call(run.id, "finish_task", ["task": "T1"])
        #expect(events == ["T1 checkingTheWork true", "T1 checkingTheWork false"])
        events = []
        _ = await world.call(run.id, "message_task", ["task": .string(task.id.uuidString), "text": "hi"])
        #expect(events == ["T1 answering true", "T1 answering false"])
        // A tool that is none of the Operator's acts, or names no task of the run, tells nothing.
        events = []
        _ = await world.call(run.id, "run_status")
        _ = await world.call(run.id, "finish_task", ["task": "nope"])
        #expect(events.isEmpty)
        #expect(world.controller.acting == .none)
    }

    /// Each tool that is one of the Operator's acts maps to its act, by what the task is doing and how it ends.
    @Test func eachActingToolIsItsAct() {
        let run = OperatorServiceFixtures.run(projects: [project])
        func act(_ tool: OperatorTool, _ state: OperatedState = .working, end: TaskEnd = .commit, request: Bool = false) -> OperatorAct? {
            var task = workingTask(in: run)
            task.operated?.state = state
            task.operated?.end = end
            if request { task.operated?.publication = TaskPublication(mergeRequestURL: "https://gitlab.example/a/-/merge_requests/1") }
            return OperatorToolHandler.act(for: tool, on: task)
        }
        #expect(act(.messageTask) == .answering)
        #expect(act(.messageTask, .inReview) == .relayingFeedback)
        #expect(act(.replyThread, .inReview) == .relayingFeedback)
        #expect(act(.markTask) == .checkingTheWork)
        #expect(act(.reviewTask) == nil, "a refused tool starts no review activity")
        #expect(act(.requestReview) == .assigning)
        #expect(act(.finishTask) == .checkingTheWork)
        #expect(act(.finishTask, end: .draftMR) == .openingTheMR)
        #expect(act(.finishTask, end: .merge) == .openingTheMR)
        #expect(act(.finishTask, .inReview, end: .merge, request: true) == .merging)
        #expect(act(.finishTask, end: .mergeLocal) == .merging)
        #expect(act(.runStatus) == nil && act(.readTask) == nil)
        #expect(OperatorToolHandler.actsOnBroadcast[.submitPlan] == .loadingTheConstruct)
        #expect(OperatorToolHandler.actsOnBroadcast[.jiraCreate] == .filingATicket)
        #expect(OperatorToolHandler.actsOnBroadcast[.reportSnag] == nil, "it files nothing")
    }

    @Test func leftForYouIsRecordOnlyAndIdempotentAfterRestart() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        _ = await world.call(run.id, "leave_for_you", ["key": "push", "text": "Push main: merged locally."])
        #expect(world.workspace.flush())
        let restarted = try OperatorWorld(try world.workspace.file.load())
        _ = await restarted.call(run.id, "leave_for_you", ["key": "push", "text": "Another text."])
        #expect(restarted.run(run.id)?.leftForYou == ["Push main: merged locally."])
        #expect(restarted.state.tasks.isEmpty && restarted.run(run.id)?.questions.isEmpty == true)
    }
}
