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
    case resolveThread = "resolve_thread", critiqueThread = "critique_thread"
    case messageTask = "message_task", openTab = "open_tab", markTask = "mark_task", resumeTask = "resume_task"
    case retryTask = "retry_task", finishTask = "finish_task", updateRequest = "update_request", retryPipeline = "retry_pipeline"
    case recordReview = "record_review"
    case checkGoal = "check_goal"
    case askYou = "ask_you", relayQuestion = "relay_question", resolveQuestion = "resolve_question", reportFind = "report_find", reportSnag = "report_snag"
    case leaveForYou = "leave_for_you", logDecision = "log_decision", writeSummary = "write_summary"

    /// What a veto's call does when the Oracle gives no answer: missing, failed, too slow, or lost with AiTerm's restart.
    public enum Unanswered: Sendable {
        case goesAhead, actsUnchecked, refused

        public var words: String {
            switch self {
            case .goesAhead: "goes ahead"
            case .actsUnchecked: "acts as not checked by the Oracle"
            case .refused: "is refused"
            }
        }
    }

    /// The tools whose challenged calls act only on the Oracle's yes (`ChallengeKind.veto`), each with the calls the
    /// Oracle challenges as a new run's brief names them, and what the call does with no answer.
    public static let vetoes: [(tool: OperatorTool, call: String, unanswered: Unanswered)] = [
        (.createTask, "create_task past the backlog limit", .refused),
        (.finishTask, "a finish_task that would merge or push with noVerify", .goesAhead),
        (.checkGoal, "check_goal", .actsUnchecked),
    ]

    public var isVeto: Bool { Self.vetoes.contains { $0.tool == self } }

    /// Whether a call of it only looks, or changes the run, its tasks or its records: the Operator has seen what a change
    /// did (the tool handler's `mutating`), and the Activity tab reads a look's line muted (`ActivityLine.reads`).
    public enum Effect: Sendable { case looks, changes }

    public var effect: Effect {
        switch self {
        case .runStatus, .readTask, .jiraSearch, .jiraBoard, .findUser: .looks
        case .jiraCreate, .jiraMove, .jiraLink, .jiraSprint, .jiraEdit, .jiraComment, .createTask, .updateTask, .submitPlan,
             .reviewTask, .requestReview, .replyThread, .resolveThread, .critiqueThread, .messageTask, .openTab, .markTask,
             .resumeTask, .retryTask, .finishTask, .updateRequest, .retryPipeline, .recordReview, .checkGoal, .askYou,
             .relayQuestion, .resolveQuestion, .reportFind, .reportSnag, .leaveForYou, .logDecision, .writeSummary: .changes
        }
    }

    /// It changes the run, its tasks or its records (`effect`).
    public var isMutating: Bool { effect == .changes }
    /// It only looks (`effect`).
    public var isReadOnly: Bool { effect == .looks }

    /// What a call of it is while it runs, as the status lines say it: an act on the task it names (the tool handler's
    /// `act(for:on:)` says which, by the task), one of the broadcast's own acts, or none.
    public enum ActKind: Equatable, Sendable { case none, onTask, onBroadcast(OperatorAct) }

    public var actKind: ActKind {
        switch self {
        case .messageTask, .markTask, .finishTask, .reviewTask, .requestReview, .replyThread: .onTask
        case .createTask, .updateTask, .submitPlan: .onBroadcast(.loadingTheConstruct)
        case .jiraCreate, .reportFind: .onBroadcast(.filingATicket)
        case .runStatus, .jiraSearch, .jiraMove, .jiraLink, .jiraBoard, .jiraSprint, .jiraEdit, .jiraComment, .readTask,
             .resolveThread, .critiqueThread, .findUser, .openTab, .resumeTask, .retryTask, .updateRequest, .retryPipeline,
             .recordReview, .checkGoal, .askYou, .relayQuestion, .resolveQuestion, .reportSnag, .leaveForYou, .logDecision,
             .writeSummary: .none
        }
    }

    /// How the Oracle may challenge a call of it (spec §8), with the Oracle on: never; with a critique the call answers
    /// (`ChallengeKind.critique`); with a yes it needs to act (`ChallengeKind.veto`, `vetoes`); or in rounds of its own, a
    /// relayed question's (`relay_question`). Which calls of a challenged tool are challenged is the tool handler's to say.
    public enum ChallengeClass: Sendable { case never, critique, veto, relay }

    public var challengeClass: ChallengeClass {
        switch self {
        case .submitPlan, .markTask: .critique
        case .createTask, .finishTask, .checkGoal: .veto
        case .relayQuestion: .relay
        case .runStatus, .jiraSearch, .jiraCreate, .jiraMove, .jiraLink, .jiraBoard, .jiraSprint, .jiraEdit, .jiraComment,
             .updateTask, .readTask, .reviewTask, .requestReview, .replyThread, .findUser, .resolveThread, .critiqueThread,
             .messageTask, .openTab, .resumeTask, .retryTask, .updateRequest, .retryPipeline, .recordReview, .askYou,
             .resolveQuestion, .reportFind, .reportSnag, .leaveForYou, .logDecision, .writeSummary: .never
        }
    }

    /// What this tool's vetoed call does with no answer from the Oracle; nil for a tool that is no veto.
    public var unanswered: Unanswered? { Self.vetoes.first { $0.tool == self }?.unanswered }
}
