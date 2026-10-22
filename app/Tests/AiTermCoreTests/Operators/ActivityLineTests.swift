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
        #expect(line("jira_board") == "Read the Jira boards and sprints")
        #expect(line("jira_sprint", ["tickets": ["SHOP-1", "SHOP-2"], "sprint": 41]) == "Put SHOP-1, SHOP-2 in sprint 41")
        #expect(line("jira_sprint", ["tickets": ["SHOP-1"], "sprint": "41"]) == "Put SHOP-1 in sprint 41")
        #expect(line("jira_sprint", ["tickets": ["SHOP-1"], "sprint": "backlog"]) == "Moved SHOP-1 to the backlog")
        #expect(line("jira_edit", ["key": "e1", "ticket": "SHOP-1"]) == "Edited SHOP-1")
        #expect(line("jira_comment", ["key": "c1", "ticket": "SHOP-1"]) == "Commented on SHOP-1")
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
        #expect(line("report_snag", ["title": "Stale state"]) == "Noted a snag in AiTerm: Stale state")
        #expect(line("leave_for_you", ["text": "Check staging"]) == "Left for you: Check staging")
        #expect(line("log_decision", ["text": "Use SwiftUI"]) == "Decided: Use SwiftUI")
        #expect(line("write_summary") == "Wrote the summary")
        #expect(line("something_new") == "something_new")
    }

    /// The gate's own lines for the Operator's shell commands (spec §A): a read is muted, a command the Oracle
    /// stopped says so.
    @Test func aShellCommandReadsAsTheCommand() {
        #expect(line("shell_read", ["command": "git status"]) == "Read `git status`")
        #expect(line("shell", ["command": "npm install"]) == "Ran `npm install`")
        #expect(ActivityLine.line(tool: "shell", arguments: ["command": "npm run deploy"], task: nil, outcome: .challenged)
                == "The Oracle stopped `npm run deploy`")
        #expect(ActivityLine.line(tool: "shell", arguments: ["command": "npm run deploy"], task: nil, outcome: .refused)
                == "run `npm run deploy`")
    }

    /// A call that did not go through says what was asked, in the imperative; one answered from the first keeps
    /// the past tense, as the call it repeats.
    @Test func aCallThatDidNotGoThroughSaysWhatWasAsked() {
        func asked(_ tool: String, _ arguments: JSONValue = .object([:]), task: TaskItem? = nil,
                   as outcome: ActivityEntry.Outcome = .refused) -> String {
            ActivityLine.line(tool: tool, arguments: arguments, task: task, outcome: outcome)
        }
        #expect(asked("run_status") == "check the broadcast’s status")
        #expect(asked("jira_search", ["jql": "project = SHOP"]) == "search Jira: project = SHOP")
        #expect(asked("jira_create", ["summary": "Fix cart", "project": "SHOP"]) == "file “Fix cart” in SHOP")
        #expect(asked("jira_move", ["key": "SHOP-1", "status": "Done"]) == "move SHOP-1 to Done")
        #expect(asked("jira_link", ["key": "SHOP-1", "to": "SHOP-2"]) == "link SHOP-1 to SHOP-2")
        #expect(asked("jira_board") == "read the Jira boards and sprints")
        #expect(asked("jira_sprint", ["tickets": ["SHOP-1", "SHOP-2"], "sprint": 41]) == "put SHOP-1, SHOP-2 in sprint 41")
        #expect(asked("jira_sprint", ["tickets": ["SHOP-1"], "sprint": "backlog"]) == "move SHOP-1 to the backlog")
        #expect(asked("jira_edit", ["ticket": "SHOP-1"]) == "edit SHOP-1")
        #expect(asked("jira_comment", ["ticket": "SHOP-1"]) == "comment on SHOP-1")
        #expect(asked("create_task", ["title": "Cart drawer"]) == "add Cart drawer to the plan")
        #expect(asked("update_task", task: cart) == "change Cart drawer’s plan")
        #expect(asked("submit_plan", as: .challenged) == "submit the plan")
        #expect(asked("read_task", ["what": "diff"], task: cart) == "read Cart drawer’s diff")
        #expect(asked("read_task", task: cart) == "read Cart drawer’s work")
        #expect(asked("review_task", task: cart) == "ask for an agent review of Cart drawer")
        #expect(asked("request_review", task: cart) == "ask people to review Cart drawer")
        #expect(asked("reply_thread", task: cart) == "reply in a review thread on Cart drawer")
        #expect(asked("find_user", ["query": "Ann"]) == "look up “Ann”")
        #expect(asked("message_task", ["text": "Use the hook"], task: cart) == "tell Cart drawer’s worker: Use the hook")
        #expect(asked("open_tab", task: cart) == "open another tab on Cart drawer")
        #expect(asked("mark_task", ["outcome": "accepted"], task: cart, as: .challenged) == "mark Cart drawer accepted")
        #expect(asked("resume_task", task: cart) == "put Cart drawer back to work")
        #expect(asked("retry_task", task: cart) == "queue Cart drawer again")
        #expect(asked("finish_task", task: cart, as: .failed) == "finish Cart drawer")
        #expect(asked("ask_you", ["question": "Ship it?"]) == "ask you: Ship it?")
        #expect(asked("resolve_question", ["summary": "Yes"]) == "note your answer: Yes")
        #expect(asked("report_find", ["title": "Flaky test"]) == "note a find: Flaky test")
        #expect(asked("report_snag", ["title": "Stale state"]) == "note a snag in AiTerm: Stale state")
        #expect(asked("leave_for_you", ["text": "Check staging"]) == "leave for you: Check staging")
        #expect(asked("log_decision", ["text": "Use SwiftUI"]) == "decide: Use SwiftUI")
        #expect(asked("write_summary") == "write the summary")
        #expect(asked("something_new") == "something_new")
        // The suffix is for a call that acted: a challenged one did not, whatever it replied.
        #expect(asked("mark_task", ["outcome": "accepted", "challengeReply": "Flaky"], task: cart, as: .challenged) == "mark Cart drawer accepted")
        // Answered from the first: the first's past tense.
        #expect(asked("finish_task", task: cart, as: .repeated) == "Finished Cart drawer")
        #expect(asked("finish_task", task: cart, as: .ok) == "Finished Cart drawer")
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
        #expect(ActivityLine.reads == ["run_status", "read_task", "jira_search", "jira_board", "find_user", "shell_read"])
    }

    @Test func aReasonIsWhyTheCallWentTheWayItDid() {
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .refused, result: "No") == "No")
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .failed, result: "Broke") == "Broke")
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .challenged,
                                    result: #"{"critique":"Tests missing"}"#) == "Tests missing")
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .challenged, result: "plain") == "plain")
        // A challenge still waiting on the Oracle answers with no critique yet: the line says so, not the JSON.
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .challenged,
                                    result: #"{"challenged":true,"challengeId":"c1","pending":true}"#) == "Waiting on the Oracle’s answer.")
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .challenged,
                                    result: #"{"challenged":true,"critique":null,"pending":true}"#) == "Waiting on the Oracle’s answer.")
        #expect(ActivityLine.reason(tool: "mark_task", arguments: ["note": "All green"], outcome: .ok, result: "x") == "All green")
        #expect(ActivityLine.reason(tool: "log_decision", arguments: ["why": "Simpler"], outcome: .ok, result: "x") == "Simpler")
        #expect(ActivityLine.reason(tool: "finish_task", arguments: ["note": "n"], outcome: .ok, result: "x") == nil)
        #expect(ActivityLine.reason(tool: "mark_task", arguments: .null, outcome: .repeated, result: "x") == nil)
    }
}
