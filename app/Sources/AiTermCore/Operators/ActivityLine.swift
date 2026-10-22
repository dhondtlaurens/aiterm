import Foundation

/// What the Activity tab says of an Operator tool call, in plain words, and why a call went the way it did.
public enum ActivityLine {
    /// The tools that only look: the tab reads their lines muted. `shell_read` is a shell command the gate let run as a
    /// plain read (spec §A.1), and `shell` any other one it judged: both are the gate's own lines, never a tool's.
    public static let reads: Set<String> = ["run_status", "read_task", "jira_search", "find_user", "shell_read"]

    /// The line for `tool` called with `arguments`: `task` is the task it was about, when AiTerm found one. A call
    /// that went through, or was answered from the first, says what was done (`Finished Cart drawer`); one that was
    /// challenged, refused or failed says what was asked (`finish Cart drawer`), since nothing happened. A call that
    /// went ahead despite the Oracle's challenge says so.
    public static func line(tool: String, arguments: JSONValue, task: TaskItem?, outcome: ActivityEntry.Outcome = .ok) -> String {
        func text(_ key: String) -> String { cut(arguments[key]?.stringValue ?? "") }
        let named = task?.title ?? text("task")
        // Each tool's words twice: what was done, then what was asked.
        let words: (done: String, asked: String)
        switch tool {
        case "run_status": words = ("Checked the broadcast’s status", "check the broadcast’s status")
        case "jira_search": words = ("Searched Jira: \(text("jql"))", "search Jira: \(text("jql"))")
        case "jira_create": words = ("Filed “\(text("summary"))” in \(text("project"))", "file “\(text("summary"))” in \(text("project"))")
        case "jira_move": words = ("Moved \(text("key")) to \(text("status"))", "move \(text("key")) to \(text("status"))")
        case "jira_link": words = ("Linked \(text("key")) to \(text("to"))", "link \(text("key")) to \(text("to"))")
        case "create_task": words = ("Added \(text("title")) to the plan", "add \(text("title")) to the plan")
        case "update_task": words = ("Changed \(named)’s plan", "change \(named)’s plan")
        case "submit_plan": words = ("Submitted the plan", "submit the plan")
        case "read_task":
            let what = arguments["what"]?.stringValue.map(cut) ?? "work"
            words = ("Read \(named)’s \(what)", "read \(named)’s \(what)")
        case "review_task": words = ("Asked for an agent review of \(named)", "ask for an agent review of \(named)")
        case "request_review": words = ("Asked people to review \(named)", "ask people to review \(named)")
        case "reply_thread": words = ("Replied in a review thread on \(named)", "reply in a review thread on \(named)")
        case "find_user": words = ("Looked up “\(text("query"))”", "look up “\(text("query"))”")
        case "message_task": words = ("Told \(named)’s worker: \(text("text"))", "tell \(named)’s worker: \(text("text"))")
        case "open_tab": words = ("Opened another tab on \(named)", "open another tab on \(named)")
        case "mark_task": words = ("Marked \(named) \(text("outcome"))", "mark \(named) \(text("outcome"))")
        case "resume_task": words = ("Put \(named) back to work", "put \(named) back to work")
        case "retry_task": words = ("Queued \(named) again", "queue \(named) again")
        case "finish_task": words = ("Finished \(named)", "finish \(named)")
        case "ask_you": words = ("Asked you: \(text("question"))", "ask you: \(text("question"))")
        case "resolve_question": words = ("Noted your answer: \(text("summary"))", "note your answer: \(text("summary"))")
        case "report_find": words = ("Noted a find: \(text("title"))", "note a find: \(text("title"))")
        case "report_snag": words = ("Noted a snag in AiTerm: \(text("title"))", "note a snag in AiTerm: \(text("title"))")
        case "leave_for_you": words = ("Left for you: \(text("text"))", "leave for you: \(text("text"))")
        case "log_decision": words = ("Decided: \(text("text"))", "decide: \(text("text"))")
        case "write_summary": words = ("Wrote the summary", "write the summary")
        case "shell_read": words = ("Read `\(text("command"))`", "read `\(text("command"))`")
        case "shell": words = ("Ran `\(text("command"))`", "The Oracle stopped `\(text("command"))`")
        default: words = (tool, tool)
        }
        switch outcome {
        case .challenged, .refused, .failed: return words.asked
        case .repeated: return words.done
        case .ok:
            let kept = !(arguments["challengeReply"]?.stringValue ?? "").isEmpty
            return kept ? words.done + " · kept despite the Oracle" : words.done
        }
    }

    /// Why the call went the way it did: AiTerm's answer to a refused or failed one, the Oracle's critique of
    /// a challenged one (or that it is still awaited, while the challenge's answer carries none), the note on an
    /// accepted mark and the why of a decision. Nil for the rest.
    public static func reason(tool: String, arguments: JSONValue, outcome: ActivityEntry.Outcome, result: String) -> String? {
        switch outcome {
        case .refused, .failed: return result
        case .challenged:
            guard case .object(let answer)? = try? JSONDecoder().decode(JSONValue.self, from: Data(result.utf8)) else { return result }
            return answer["critique"]?.stringValue ?? "Waiting on the Oracle’s answer."
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
