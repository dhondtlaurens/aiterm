import Foundation

/// What the Activity tab says of an Operator tool call, in plain words, and why a call went the way it did.
public enum ActivityLine {
    /// The tools that only look: the tab reads their lines muted. `shell_read` is a shell command the gate let run as a
    /// plain read (spec §A.1), and `shell` any other one it judged: both are the gate's own lines, never a tool's.
    public static let reads: Set<String> = Set(OperatorTool.allCases.filter(\.isReadOnly).map(\.rawValue)).union([shellRead])

    /// The tools whose calls Activity folds away until Show everything, while they go through: the reads, and every
    /// shell command, which the Operator runs to look (it writes through its tools).
    public static let looks: Set<String> = reads.union([shell])

    /// The gate's own tool names for a shell command it let run as a plain read, and for any other one it judged.
    private static let shellRead = "shell_read", shell = "shell"

    /// The line for `tool` called with `arguments`: `task` is the task it was about, when AiTerm found one. A call
    /// that went through, or was answered from the first, says what was done (`Finished Cart drawer`); one that was
    /// challenged, refused or failed says what was asked (`finish Cart drawer`), since nothing happened. A call that
    /// went ahead despite the Oracle's challenge says so.
    public static func line(tool: String, arguments: JSONValue, task: TaskItem?, outcome: ActivityEntry.Outcome = .ok) -> String {
        func text(_ key: String) -> String { cut(arguments[key]?.stringValue ?? "") }
        let named = task?.title ?? text("task")
        // Each tool's words twice: what was done, then what was asked.
        let words: (done: String, asked: String)
        if let known = OperatorTool(rawValue: tool) { words = Self.words(known, arguments: arguments, named: named) }
        else if tool == shellRead { words = ("Read `\(text("command"))`", "read `\(text("command"))`") }
        else if tool == shell { words = ("Ran `\(text("command"))`", "run `\(text("command"))`") }
        else { words = (tool, tool) }
        switch outcome {
        // A shell command did not go through because the Oracle stopped it (spec §A.3).
        case .challenged where tool == shell: return "The Oracle stopped `\(text("command"))`"
        case .challenged, .refused, .failed: return words.asked
        case .repeated: return words.done
        case .ok:
            let kept = !(arguments["challengeReply"]?.stringValue ?? "").isEmpty
            return kept ? words.done + " · kept despite the Oracle" : words.done
        }
    }

    /// What a call of `tool` did, and what it asked, in that order: every tool has its own words.
    private static func words(_ tool: OperatorTool, arguments: JSONValue, named: String) -> (done: String, asked: String) {
        func text(_ key: String) -> String { cut(arguments[key]?.stringValue ?? "") }
        switch tool {
        case .runStatus: return ("Checked the broadcast’s status", "check the broadcast’s status")
        case .jiraSearch: return ("Searched Jira: \(text("jql"))", "search Jira: \(text("jql"))")
        case .jiraCreate: return ("Filed “\(text("summary"))” in \(text("project"))", "file “\(text("summary"))” in \(text("project"))")
        case .jiraMove: return ("Moved \(text("key")) to \(text("status"))", "move \(text("key")) to \(text("status"))")
        case .jiraLink: return ("Linked \(text("key")) to \(text("to"))", "link \(text("key")) to \(text("to"))")
        case .jiraBoard: return ("Read the Jira boards and sprints", "read the Jira boards and sprints")
        case .jiraSprint:
            let tickets = (arguments["tickets"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
            let sprint = arguments["sprint"]?.intValue.map(String.init) ?? text("sprint")
            if sprint.lowercased() == "backlog" { return ("Moved \(cut(tickets)) to the backlog", "move \(cut(tickets)) to the backlog") }
            return ("Put \(cut(tickets)) in sprint \(sprint)", "put \(cut(tickets)) in sprint \(sprint)")
        case .jiraEdit: return ("Edited \(text("ticket"))", "edit \(text("ticket"))")
        case .jiraComment: return ("Commented on \(text("ticket"))", "comment on \(text("ticket"))")
        case .createTask: return ("Added \(text("title")) to the plan", "add \(text("title")) to the plan")
        case .updateTask: return ("Changed \(named)’s plan", "change \(named)’s plan")
        case .submitPlan: return ("Submitted the plan", "submit the plan")
        case .readTask:
            let what = arguments["what"]?.stringValue.map(cut) ?? "work"
            return ("Read \(named)’s \(what)", "read \(named)’s \(what)")
        case .reviewTask: return ("Asked for an agent review of \(named)", "ask for an agent review of \(named)")
        case .requestReview: return ("Asked people to review \(named)", "ask people to review \(named)")
        case .replyThread: return ("Replied in a review thread on \(named)", "reply in a review thread on \(named)")
        case .resolveThread: return ("Resolved a review thread on \(named)", "resolve a review thread on \(named)")
        case .critiqueThread: return ("Asked the Oracle about a review thread on \(named)", "ask the Oracle about a review thread on \(named)")
        case .findUser: return ("Looked up “\(text("query"))”", "look up “\(text("query"))”")
        case .messageTask: return ("Told \(named)’s worker: \(text("text"))", "tell \(named)’s worker: \(text("text"))")
        case .openTab: return ("Opened another tab on \(named)", "open another tab on \(named)")
        case .markTask: return ("Marked \(named) \(text("outcome"))", "mark \(named) \(text("outcome"))")
        case .resumeTask: return ("Put \(named) back to work", "put \(named) back to work")
        case .retryTask: return ("Queued \(named) again", "queue \(named) again")
        case .finishTask: return ("Finished \(named)", "finish \(named)")
        case .updateRequest: return ("Changed \(named)’s request", "change \(named)’s request")
        case .retryPipeline: return ("Retried \(named)’s failed pipeline", "retry \(named)’s failed pipeline")
        case .recordReview:
            let verdict = arguments["passed"] == true ? "passed" : "not passed"
            return ("Recorded \(named)’s review: \(verdict)", "record \(named)’s review: \(verdict)")
        case .checkGoal:
            let verdict = arguments["met"] == true ? "met" : "not met"
            return ("Checked the goal: \(verdict)", "check the goal: \(verdict)")
        case .askYou: return ("Asked you: \(text("question"))", "ask you: \(text("question"))")
        case .relayQuestion: return ("Passed on \(named)’s worker’s question to you", "pass on \(named)’s worker’s question to you")
        case .resolveQuestion:
            if arguments["withdrawn"] == true { return ("Withdrew question: \(text("summary"))", "withdraw question: \(text("summary"))") }
            return ("Noted your answer: \(text("summary"))", "note your answer: \(text("summary"))")
        case .reportFind: return ("Noted a find: \(text("title"))", "note a find: \(text("title"))")
        case .reportSnag: return ("Noted a snag in AiTerm: \(text("title"))", "note a snag in AiTerm: \(text("title"))")
        case .leaveForYou: return ("Left for you: \(text("text"))", "leave for you: \(text("text"))")
        case .logDecision: return ("Decided: \(text("text"))", "decide: \(text("text"))")
        case .writeSummary: return ("Wrote the summary", "write the summary")
        }
    }

    /// Why the call went the way it did: AiTerm's answer to a refused or failed one, the Oracle's critique of
    /// a challenged one (or that it is still awaited, while the challenge's answer carries none), the note on an
    /// accepted mark, the why of a decision and a withdrawal reason the line had to cut. Nil for the rest.
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
            case "resolve_question" where arguments["withdrawn"] == true:
                guard let summary = arguments["summary"]?.stringValue, cut(summary) != summary else { return nil }
                return summary
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
