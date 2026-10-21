import Testing
import Foundation
@testable import AiTermCore

/// What the Activity tab says of each Operator tool call, in plain words.
@Suite struct ActivityLineTests {
    private func line(_ tool: String, _ arguments: JSONValue = .object([:]), task: TaskItem? = nil) -> String {
        ActivityLine.line(tool: tool, arguments: arguments, task: task)
    }
    private let cart = OperatorFixtures.task("Cart drawer")

    @Test func eachToolReadsAsAPlainSentence() {
        #expect(line("run_status") == "Checked the broadcast’s status")
        #expect(line("jira_search", ["jql": "project = SHOP"]) == "Searched Jira: project = SHOP")
        #expect(line("jira_create", ["summary": "Fix cart", "project": "SHOP"]) == "Filed “Fix cart” in SHOP")
        #expect(line("jira_move", ["key": "SHOP-1", "status": "Done"]) == "Moved SHOP-1 to Done")
        #expect(line("jira_link", ["key": "SHOP-1", "to": "SHOP-2"]) == "Linked SHOP-1 to SHOP-2")
        #expect(line("create_task", ["title": "Cart drawer"]) == "Added Cart drawer to the plan")
        #expect(line("update_task", task: cart) == "Changed Cart drawer’s plan")
        #expect(line("submit_plan") == "Submitted the plan")
        #expect(line("read_task", ["what": "diff"], task: cart) == "Read Cart drawer’s diff")
        #expect(line("read_task", task: cart) == "Read Cart drawer’s work")
        #expect(line("review_task", task: cart) == "Asked for an agent review of Cart drawer")
        #expect(line("request_review", task: cart) == "Asked people to review Cart drawer")
        #expect(line("reply_thread", task: cart) == "Replied in a review thread on Cart drawer")
        #expect(line("find_user", ["query": "Ann"]) == "Looked up “Ann”")
        #expect(line("message_task", ["text": "Use the hook"], task: cart) == "Told Cart drawer’s worker: Use the hook")
        #expect(line("open_tab", task: cart) == "Opened another tab on Cart drawer")
        #expect(line("mark_task", ["outcome": "accepted"], task: cart) == "Marked Cart drawer accepted")
        #expect(line("resume_task", task: cart) == "Put Cart drawer back to work")
        #expect(line("retry_task", task: cart) == "Queued Cart drawer again")
        #expect(line("finish_task", task: cart) == "Finished Cart drawer")
        #expect(line("ask_you", ["question": "Ship it?"]) == "Asked you: Ship it?")
        #expect(line("resolve_question", ["summary": "Yes"]) == "Noted your answer: Yes")
        #expect(line("report_find", ["title": "Flaky test"]) == "Noted a find: Flaky test")
        #expect(line("leave_for_you", ["text": "Check staging"]) == "Left for you: Check staging")
        #expect(line("log_decision", ["text": "Use SwiftUI"]) == "Decided: Use SwiftUI")
        #expect(line("write_summary") == "Wrote the summary")
        #expect(line("something_new") == "something_new")
    }

    @Test func theTaskArgumentStandsInWithoutATask() {
        #expect(line("finish_task", ["task": "SHOP-7"]) == "Finished SHOP-7")
        #expect(line("finish_task", ["task": "SHOP-7"], task: cart) == "Finished Cart drawer")
    }

    @Test func textIsCutAtItsFirstLine() {
        #expect(line("ask_you", ["question": "Ship it?\nThe long version follows."]) == "Asked you: Ship it?…")
    }

    @Test func textIsCutAtEightyCharacters() {
        let long = String(repeating: "a", count: 120)
        #expect(line("log_decision", ["text": .string(long)]) == "Decided: " + String(repeating: "a", count: 80) + "…")
        let exact = String(repeating: "a", count: 80)
        #expect(line("log_decision", ["text": .string(exact)]) == "Decided: " + exact)
    }

    @Test func aChallengeReplyIsNoted() {
        #expect(line("mark_task", ["outcome": "accepted", "challengeReply": "The check is flaky"], task: cart)
                == "Marked Cart drawer accepted · kept despite the Oracle")
        #expect(line("mark_task", ["outcome": "accepted", "challengeReply": ""], task: cart) == "Marked Cart drawer accepted")
    }

    @Test func readsAreTheToolsThatOnlyLook() {
        #expect(ActivityLine.reads == ["run_status", "read_task", "jira_search", "find_user"])
    }

    @Test func aReasonIsWhyTheCallWentTheWayItDid() {
        typealias E = ActivityEntry.Outcome
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .refused, result: "No") == "No")
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .failed, result: "Broke") == "Broke")
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .challenged,
                                    result: #"{"critique":"Tests missing"}"#) == "Tests missing")
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .challenged, result: "plain") == "plain")
        #expect(ActivityLine.reason(tool: "mark_task", arguments: ["note": "All green"], outcome: .ok, result: "x") == "All green")
        #expect(ActivityLine.reason(tool: "log_decision", arguments: ["why": "Simpler"], outcome: .ok, result: "x") == "Simpler")
        #expect(ActivityLine.reason(tool: "finish_task", arguments: ["note": "n"], outcome: .ok, result: "x") == nil)
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .repeated, result: "x") == nil)
    }
}
