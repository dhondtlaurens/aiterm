import Foundation

/// The signal Operator's complete MCP surface. Transport registration is separate until activation.
public enum OperatorTool: String, CaseIterable, Sendable {
    case runStatus = "run_status", readTask = "read_task", messageTask = "message_task", openTab = "open_tab"
    case askYou = "ask_you", resolveQuestion = "resolve_question", reportSnag = "report_snag", jiraSearch = "jira_search"
    case resumeTask = "resume_task", finishStage = "finish_stage", note, answerWorker = "answer_worker", askOracle = "ask_oracle"
    case chooseAgent = "choose_agent"

    public var mutating: Bool {
        switch self {
        case .runStatus, .readTask, .jiraSearch: false
        case .messageTask, .openTab, .askYou, .resolveQuestion, .reportSnag, .resumeTask, .finishStage, .note, .answerWorker, .askOracle, .chooseAgent: true
        }
    }
    public var requiresKey: Bool { mutating }
    public var taskRequired: Bool {
        switch self {
        case .readTask, .messageTask, .openTab, .resumeTask, .finishStage, .note, .answerWorker, .chooseAgent: true
        case .runStatus, .askYou, .resolveQuestion, .reportSnag, .jiraSearch, .askOracle: false
        }
    }
    public var act: String? {
        switch self {
        case .messageTask, .answerWorker: "answering its worker"
        case .openTab, .resumeTask: "starting its worker"
        case .finishStage: "checking its result"
        case .chooseAgent: "choosing its agent"
        case .askOracle: "consulting the Oracle"
        case .runStatus, .readTask, .askYou, .resolveQuestion, .reportSnag, .jiraSearch, .note: nil
        }
    }
}
