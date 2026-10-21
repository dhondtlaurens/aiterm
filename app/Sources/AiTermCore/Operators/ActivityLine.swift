import Foundation

/// What the Activity tab says of an Operator tool call, in plain words, and why a call went the way it did.
public enum ActivityLine {
    /// The tools that only look: the tab can fold their lines away.
    public static let reads: Set<String> = ["run_status", "read_task", "jira_search", "find_user"]

    /// The line for `tool` called with `arguments`: `task` is the task it was about, when AiTerm found one.
    /// A call that went ahead despite the Oracle's challenge says so.
    public static func line(tool: String, arguments: JSONValue, task: TaskItem?) -> String {
        func text(_ key: String) -> String { cut(arguments[key]?.stringValue ?? "") }
        let named = task?.title ?? text("task")
        let words: String
        switch tool {
        case "run_status": words = "Checked the broadcast’s status"
        case "jira_search": words = "Searched Jira: \(text("jql"))"
        case "jira_create": words = "Filed “\(text("summary"))” in \(text("project"))"
        case "jira_move": words = "Moved \(text("key")) to \(text("status"))"
        case "jira_link": words = "Linked \(text("key")) to \(text("to"))"
        case "create_task": words = "Added \(text("title")) to the plan"
        case "update_task": words = "Changed \(named)’s plan"
        case "submit_plan": words = "Submitted the plan"
        case "read_task": words = "Read \(named)’s \(arguments["what"]?.stringValue.map(cut) ?? "work")"
        case "review_task": words = "Asked for an agent review of \(named)"
        case "request_review": words = "Asked people to review \(named)"
        case "reply_thread": words = "Replied in a review thread on \(named)"
        case "find_user": words = "Looked up “\(text("query"))”"
        case "message_task": words = "Told \(named)’s worker: \(text("text"))"
        case "open_tab": words = "Opened another tab on \(named)"
        case "mark_task": words = "Marked \(named) \(text("outcome"))"
        case "resume_task": words = "Put \(named) back to work"
        case "retry_task": words = "Queued \(named) again"
        case "finish_task": words = "Finished \(named)"
        case "ask_you": words = "Asked you: \(text("question"))"
        case "resolve_question": words = "Noted your answer: \(text("summary"))"
        case "report_find": words = "Noted a find: \(text("title"))"
        case "leave_for_you": words = "Left for you: \(text("text"))"
        case "log_decision": words = "Decided: \(text("text"))"
        case "write_summary": words = "Wrote the summary"
        default: words = tool
        }
        let kept = !(arguments["challengeReply"]?.stringValue ?? "").isEmpty
        return kept ? words + " · kept despite the Oracle" : words
    }

    /// Why the call went the way it did: AiTerm's answer to a refused or failed one, the Oracle's critique of
    /// a challenged one, the note on an accepted mark and the why of a decision. Nil for the rest.
    public static func reason(tool: String, arguments: JSONValue, outcome: ActivityEntry.Outcome, result: String) -> String? {
        switch outcome {
        case .refused, .failed: return result
        case .challenged:
            let data = Data(result.utf8)
            return (try? JSONDecoder().decode(JSONValue.self, from: data))?["critique"]?.stringValue ?? result
        case .ok:
            switch tool {
            case "mark_task": return arguments["note"]?.stringValue
            case "log_decision": return arguments["why"]?.stringValue
            default: return nil
            }
        case .repeated: return nil
        }
    }

    /// `text` cut at its first line and at 80 characters, with `…` when anything was left out.
    private static func cut(_ text: String) -> String {
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let shortened = String(first.prefix(80))
        return shortened == text ? text : shortened.trimmingCharacters(in: .whitespaces) + "…"
    }
}
