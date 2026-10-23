import Foundation

/// The Operator's tools, by the names the daemon serves them under (`daemon/aitermd/operator_mcp.py`) and the app
/// answers them by (`OperatorToolHandler.perform`). A name the daemon adds without a case here is a tool AiTerm
/// can't answer, which `OperatorToolTests` catches.
public enum OperatorTool: String, CaseIterable, Sendable {
    case runStatus = "run_status"
    case jiraSearch = "jira_search", jiraCreate = "jira_create", jiraMove = "jira_move", jiraLink = "jira_link"
    case jiraBoard = "jira_board", jiraSprint = "jira_sprint", jiraEdit = "jira_edit", jiraComment = "jira_comment"
    case createTask = "create_task", updateTask = "update_task", submitPlan = "submit_plan", readTask = "read_task"
    case reviewTask = "review_task", requestReview = "request_review", replyThread = "reply_thread", findUser = "find_user"
    case messageTask = "message_task", openTab = "open_tab", markTask = "mark_task", resumeTask = "resume_task"
    case retryTask = "retry_task", finishTask = "finish_task"
    case askYou = "ask_you", resolveQuestion = "resolve_question", reportFind = "report_find", reportSnag = "report_snag"
    case leaveForYou = "leave_for_you", logDecision = "log_decision", writeSummary = "write_summary"
}
