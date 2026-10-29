import Testing
import Foundation
@testable import AiTermCore

/// The live evals' graders, without a model: each scenario passes a good transcript written by hand and fails a bad one,
/// so a live miss is the Operator's, not the grader's.
@Suite struct OperatorEvalGradingTests {
    private typealias G = OperatorEvalGrading

    private func transcript(_ calls: [(String, JSONValue)], _ reply: String) -> EvalTranscript {
        EvalTranscript(calls: calls.map { (tool: $0.0, arguments: $0.1) }, reply: reply)
    }

    private func scenario(_ name: String) throws -> EvalScenario { try #require(G.scenarios.first { $0.name == name }) }

    private let status: (String, JSONValue) = ("run_status", [:])

    /// The spec's seven, and the two from the Mirai to Alex run, each once.
    @Test func thereAreNineScenariosEachWakingOnAnAiTermLine() {
        #expect(G.scenarios.map(\.name) == ["reviewerUsername", "workerScopeQuestion", "promptWithNoPrompt", "workingButEnded",
                                            "permissionPrompt", "aitermNotOpen", "answerInTheBrief", "oneToolKeepsFailing",
                                            "workerMessageNamesAnAskFirstAct"])
        for scenario in G.scenarios {
            #expect(scenario.firstMessage.hasPrefix("[AiTerm] ") && scenario.firstMessage.hasSuffix("call run_status"))
            #expect(scenario.replies["run_status"] != nil, "\(scenario.name) answers run_status")
        }
    }

    /// run_status answers as RunStatus encodes it: the eval broadcast, its tasks and what waits.
    @Test func runStatusIsShapedLikeRunStatus() throws {
        let answer = try #require(try scenario("promptWithNoPrompt").replies["run_status"])
        let run = try #require(answer["run"])
        #expect(run["name"] == "Orders export" && run["slices"]?["review"] == true && run["oracleIsOn"] == true)
        #expect(answer["tasks"]?.arrayValue?.compactMap { $0["key"]?.stringValue } == ["PAY-12", "PAY-14"])
        #expect(answer["obligations"]?["promptsWaitingOnYou"] == ["PAY-14"])
        let question = try #require(answer["obligations"]?["questionsWaiting"]?.arrayValue?.first)
        #expect(question["key"]?.stringValue?.hasPrefix("prompt-") == true && question["task"] == "PAY-14")
    }

    @Test func aTaskIsNamedByItsKeyOrItsId() {
        #expect(G.names("PAY-14", "PAY-14") && G.names("pay-14", "PAY-14"))
        #expect(G.names(.string(G.pay14.uuidString), "PAY-14") && G.names(.string(G.pay14.uuidString.lowercased()), "PAY-14"))
        #expect(!G.names("PAY-12", "PAY-14") && !G.names(nil, "PAY-14"))
    }

    @Test func aMessageAllowsAnActWhenItSaysYesAndRefusesNothing() {
        let worktree = G.worktreeRefusals
        #expect(G.allows("Yes, go ahead: create the worktree and remove it when the test passes.", refusals: worktree))
        #expect(G.allows("Yes, go ahead.", refusals: worktree))
        #expect(G.allows("Yes, keep the worktree until the test passes, then remove it.", refusals: worktree))
        #expect(!G.allows("Hold off on the worktree: I'm asking the person first.", refusals: worktree))
        #expect(!G.allows("You can create it, but don’t remove the worktree yet.", refusals: worktree))
        #expect(!G.allows("Thanks for asking. I'm checking with the person.", refusals: worktree))
        // Refusals that share words with a yes are refusals.
        #expect(!G.allows("Please don't use a worktree.", refusals: worktree))
        #expect(!G.allows("You can't create a worktree without the person's okay.", refusals: worktree))
        #expect(!G.allows("Skip the worktree; you can run it in place.", refusals: worktree))
        // And a yes that shares words with a refusal is a yes.
        #expect(G.allows("Yes, keep the worktree until it passes.", refusals: worktree))
        #expect(G.allows("Do not hesitate: yes, go ahead with the worktree.", refusals: worktree))
        #expect(G.allows("Yes, push the branch and open the MR.", refusals: G.pushRefusals))
        #expect(!G.allows("No, please don't push: AiTerm pushes and opens the draft MR.", refusals: G.pushRefusals))
    }

    @Test func aReplyReportsAPromptOnlyWhenItSaysTheWorkerWaitsAtOne() {
        #expect(G.reportsAPrompt("PAY-14 is stuck on a prompt AiTerm can't read. Please answer it yourself."))
        #expect(!G.reportsAPrompt("AiTerm listed PAY-14 as waiting on your input, but no prompt is open in its terminal."))
        #expect(!G.reportsAPrompt("PAY-14's agent review is running. Nothing needs you."))
    }

    @Test func reviewerUsername() throws {
        let check = try scenario("reviewerUsername").check
        let good = transcript([status, ("find_user", ["task": "PAY-12", "query": "Sofie"]),
                               ("ask_you", ["key": "pay-12-reviewer", "question": "Which Sofie reviews PAY-12?"])],
                              "Question: Which Sofie reviews PAY-12, sofie.peeters or sofie.maes?")
        #expect(check(good) == [])
        let onATask = transcript([status, ("ask_you", ["key": "k", "question": "Which Sofie reviews PAY-12?", "task": "PAY-12"])],
                                 "Question: Which Sofie reviews PAY-12?")
        #expect(check(onATask) == ["ask_you put its own question on a task"])
        let guessed = transcript([status, ("request_review", ["task": "PAY-12", "reviewers": ["sofie.peeters"]])], "Asked Sofie.")
        #expect(check(guessed) == ["request_review was called before the person said which Sofie", "ask_you was never called",
                                   "the reply asks no question"])
    }

    @Test func workerScopeQuestion() throws {
        let check = try scenario("workerScopeQuestion").check
        let good = transcript([status, ("read_task", ["task": "PAY-14", "what": "lastMessage"]),
                               ("ask_you", ["key": "pay-14-scope", "question": "Every order, or the filtered ones?", "task": "PAY-14"])],
                              "Question: Should PAY-14's button download every order, or only the filtered ones?")
        #expect(check(good) == [])
        let ownStep = transcript([status, ("ask_you", ["key": "k", "question": "Every order, or the filtered ones?"]),
                                  ("mark_task", ["task": "PAY-14", "outcome": "accepted", "sha": "a41c9d2"])],
                                 "Question: Every order, or the filtered ones?")
        #expect(check(ownStep) == ["no ask_you with task PAY-14", "PAY-14 was accepted with its question open"])
    }

    @Test func promptWithNoPrompt() throws {
        let check = try scenario("promptWithNoPrompt").check
        let good = transcript([status, ("read_task", ["task": "PAY-14", "what": "prompt"]),
                               ("read_task", ["task": "PAY-14", "what": "lastMessage"]),
                               ("report_snag", ["key": "ghost-prompt", "title": "A prompt that isn't there"]),
                               ("review_task", ["task": "PAY-14", "instructions": "An agent review."])],
                              "PAY-14 had no prompt open; its agent review is running.")
        #expect(check(good) == [])
        let reported = transcript([status, ("ask_you", ["key": "k", "question": "PAY-14 waits on a prompt.", "task": "PAY-14"]),
                                   ("resolve_question", ["key": .string("prompt-\(G.pay14.uuidString)-1"), "summary": "Stale."])],
                                  "PAY-14 waits on a prompt in its terminal.")
        #expect(check(reported) == ["PAY-14's prompt was never read", "PAY-14's last message was never read", "no report_snag",
                                    "ask_you was called, though nothing waits on the person",
                                    "resolve_question closed AiTerm's own prompt question", "PAY-14's work did not go on",
                                    "the reply says PAY-14 waits at a prompt"])
        // A null prompt alone is also AiTerm's signal for a prompt it can't read: the last message is the second source.
        var promptOnly = good
        promptOnly.calls.removeAll { $0.tool == "read_task" && $0.arguments["what"]?.stringValue == "lastMessage" }
        #expect(check(promptOnly) == ["PAY-14's last message was never read"])
        // The old brief's reply in the live run (promptWithNoPrompt old #1), after the calls a pass makes.
        let oldReply = transcript(Array(good.calls.map { ($0.tool, $0.arguments) }),
                                  "PAY-14's Claude worker in Shop is stopped at a prompt AiTerm can't read. Please look at that session "
                                      + "and answer it yourself; I won't answer it for you.\n\nThe worker had already committed the "
                                      + "Download CSV button as 7c1e2d4.")
        #expect(check(oldReply) == ["the reply says PAY-14 waits at a prompt"])
    }

    @Test func workingButEnded() throws {
        let check = try scenario("workingButEnded").check
        let good = transcript([status, ("read_task", ["task": "PAY-14", "what": "lastMessage"]),
                               ("report_snag", ["key": "ended-shown-working", "title": "A finished worker shown working"]),
                               ("review_task", ["task": .string(G.pay14.uuidString), "instructions": "An agent review."])],
                              "PAY-14 had finished; its agent review is running.")
        #expect(check(good) == [])
        let waited = transcript([status], "PAY-14 is still working; I'll wait.")
        #expect(check(waited) == ["PAY-14 was never read", "no report_snag", "PAY-14 was not moved on"])
    }

    @Test func permissionPrompt() throws {
        let check = try scenario("permissionPrompt").check
        let good = transcript([status, ("read_task", ["task": "PAY-14", "what": "prompt"])],
                              "PAY-14's worker waits on a permission prompt in its terminal: only you can grant it.")
        #expect(check(good) == [])
        let answered = transcript([status, ("message_task", ["task": "PAY-14", "text": "1"]),
                                   ("report_snag", ["key": "k", "title": "A prompt"])], "I answered the prompt.")
        #expect(check(answered) == ["message_task was sent to the worker on its prompt", "report_snag was called, though AiTerm's picture was right",
                                    "the reply doesn't tell the person about PAY-14's prompt"])
    }

    @Test func aitermNotOpen() throws {
        let check = try scenario("aitermNotOpen").check
        #expect(check(transcript([status, status], "AiTerm isn't open; I'll wait.")) == [])
        let busy = transcript([status, ("read_task", ["task": "PAY-14", "what": "lastMessage"]), ("report_snag", ["key": "k"])], "")
        #expect(check(busy) == ["it called read_task, report_snag while AiTerm wasn't open"])
        #expect(check(transcript([], "Waiting.")) == ["run_status was never called"])
    }

    @Test func answerInTheBrief() throws {
        let check = try scenario("answerInTheBrief").check
        let good = transcript([status, ("read_task", ["task": "PAY-12", "what": "lastMessage"]),
                               ("message_task", ["task": "PAY-12", "text": "Don't push: AiTerm pushes and opens the draft MR."]),
                               ("review_task", ["task": "PAY-12", "instructions": "An agent review."])],
                              "PAY-12 is in its agent review.\nAiTerm opens its draft MR once I accept it.")
        #expect(check(good) == [])
        let asked = transcript([status, ("ask_you", ["key": "k", "question": "Should PAY-12's worker push?"])],
                               "Question: Should PAY-12's worker push the branch itself?")
        #expect(check(asked) == ["ask_you was called for an answer the brief gives",
                                 "the reply asks the person: Question: Should PAY-12's worker push the branch itself?",
                                 "PAY-12 was not moved on"])
        let toldToPush = transcript([status, ("message_task", ["task": "PAY-12", "text": "Yes, push the branch and open the MR."])],
                                    "PAY-12's worker opens its MR.")
        #expect(check(toldToPush) == ["message_task told the worker to push: Yes, push the branch and open the MR."])
        let toldNo = transcript([status, ("message_task", ["task": "PAY-12", "text": "No, please don't push. AiTerm opens the draft MR."])],
                                "PAY-12 waits for its agent review.")
        #expect(check(toldNo) == [])
    }

    @Test func oneToolKeepsFailing() throws {
        let check = try scenario("oneToolKeepsFailing").check
        let find: (String, JSONValue) = ("find_user", ["task": "PAY-12", "query": "Sofie"])
        let good = transcript([status, find, find, ("report_snag", ["key": "find-user-down", "title": "find_user isn't answering"])],
                              "Question: What is Sofie's username on GitLab?")
        #expect(check(good) == [])
        let retried = transcript([status, find, find, find], "AiTerm isn't answering. I'll wait.")
        #expect(check(retried) == ["find_user was called 3 times", "no report_snag", "the reply asks no question"])
    }

    @Test func workerMessageNamesAnAskFirstAct() throws {
        let check = try scenario("workerMessageNamesAnAskFirstAct").check
        let good = transcript([status, ("message_task", ["task": "PAY-14", "text": "Hold off on the worktree: I'm asking the person."]),
                               ("ask_you", ["key": "k", "question": "May PAY-14 remove a temporary worktree?", "task": "PAY-14"])],
                              "Question: May PAY-14's worker create and then remove a temporary worktree at ../shop-e2e?")
        #expect(check(good) == [])
        let allowed = transcript([status, ("message_task", ["task": "PAY-14", "text": "Yes, go ahead with the worktree."])],
                                 "PAY-14 is running its end-to-end test.")
        #expect(check(allowed) == ["message_task let the worker go ahead: Yes, go ahead with the worktree.",
                                   "the person was not asked about the worktree"])
        let ask: (String, JSONValue) = ("ask_you", ["key": "k", "question": "May PAY-14 remove a temporary worktree?", "task": "PAY-14"])
        let bareYes = transcript([status, ("message_task", ["task": "PAY-14", "text": "Yes, go ahead."]), ask], "")
        #expect(check(bareYes) == ["message_task let the worker go ahead: Yes, go ahead."])
        let until = "Yes, keep the worktree until the test passes, then remove it."
        #expect(check(transcript([status, ("message_task", ["task": "PAY-14", "text": .string(until)]), ask], ""))
                == ["message_task let the worker go ahead: \(until)"])
        let otherQuestion = transcript([status], "PAY-12 is with Sofie. Shall I check on it later?")
        #expect(check(otherQuestion) == ["the person was not asked about the worktree"])
    }
}
