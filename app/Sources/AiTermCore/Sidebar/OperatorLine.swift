import Foundation

/// One of the Operator's acts while AiTerm carries it out (spec §7, §13): the closed list, each with its
/// words. Only `loadingTheConstruct` and `consultingTheOracle` use Matrix words.
public enum OperatorAct: String, CaseIterable, Sendable {
    case loadingTheConstruct, consultingTheOracle, starting, answering, checkingTheWork, reviewingWith, openingTheMR, assigning,
         fixingReviewFeedback, merging, filingATicket, reopeningItsWindow

    /// Its words. `agent` is the agent it starts, answers or reviews with; `names` the people it assigns.
    public func words(agent: AgentKind, names: [String] = []) -> String {
        let agent = SidebarModel.agentName(agent)
        switch self {
        case .loadingTheConstruct: return "loading the construct"
        case .consultingTheOracle: return "consulting the Oracle"
        case .starting: return "starting \(agent)"
        case .answering: return "answering \(agent)"
        case .checkingTheWork: return "checking the work"
        case .reviewingWith: return "reviewing with \(agent)"
        case .openingTheMR: return "opening the MR"
        case .assigning: return "assigning " + (names.isEmpty ? "reviewers" : OperatorLine.list(names))
        case .fixingReviewFeedback: return "fixing review feedback"
        case .merging: return "merging"
        case .filingATicket: return "filing a ticket"
        case .reopeningItsWindow: return "reopening its window"
        }
    }

    /// Whether it is about one task, so the broadcast's line names the task after it:
    /// `answering Claude · PAY-231`.
    var namesItsTask: Bool { ![.loadingTheConstruct, .consultingTheOracle, .filingATicket].contains(self) }
}

/// What AiTerm carries out for the Operator now, as the status lines read it: each task's act, and each
/// broadcast's latest, its task named as the Operator names it (its `key`). The app's
/// `OperatorController` keeps it; a test or a snapshot passes values of its own.
public struct OperatorActs: Equatable, Sendable {
    public struct Broadcast: Equatable, Sendable {
        public var act: OperatorAct
        public var task: String?
        public init(act: OperatorAct, task: String? = nil) { self.act = act; self.task = task }
    }

    public var tasks: [UUID: OperatorAct]
    public var runs: [UUID: Broadcast]

    public init(tasks: [UUID: OperatorAct] = [:], runs: [UUID: Broadcast] = [:]) { self.tasks = tasks; self.runs = runs }

    /// Nothing in flight.
    public static let none = OperatorActs()

    /// The broadcast's act as `OperatorLine.broadcast` takes it.
    public func broadcast(_ run: UUID) -> (OperatorAct, task: String?)? { runs[run].map { ($0.act, task: $0.task) } }
}

/// A status line the Operator says (spec §7, §13, §14), drawn by the app's `OperatorBadge`: plain words in
/// AiTerm's caption grammar, `state` or `state · detail`, lowercase, no full stop, from a closed list.
///
/// - `quiet`: the Operator watches (`queued · after PAY-232`, `working`, `in review · waiting on Jan`,
///   `done · 4f2a91c`, `paused`).
/// - `acting`: AiTerm carries out one of its acts (`OperatorAct`); `oracle` while the Oracle is consulted.
/// - `needsYou`: a request (`waiting on you · npm install?`, `waiting on you · 2 tasks`,
///   `blocked · the tests fail on main`).
///
/// A request outranks an act. A detail is cut to fit the sidebar's third line, the whole of it in
/// `tooltip`. Nothing here says progress: the broadcast row's `2 of 8 done` is the row's.
public struct OperatorLine: Equatable, Sendable {
    public enum Look: Equatable, Sendable { case quiet, acting, needsYou }
    public var text: String
    public var look: Look
    /// The Oracle's mark joins the Operator's.
    public var oracle: Bool
    /// The whole of what the line says: the request's sentence, or the words before they were cut.
    public var tooltip: String
    /// The Oracle's agent, from the broadcast's profile: the mark drawn beside the Operator's.
    public var oracleAgent: AgentKind

    public init(_ text: String, look: Look = .quiet, oracle: Bool = false, tooltip: String? = nil, oracleAgent: AgentKind = .codex) {
        self.text = text; self.look = look; self.oracle = oracle; self.tooltip = tooltip ?? text; self.oracleAgent = oracleAgent
    }

    /// The most characters a line says before its detail is cut: what the sidebar's third line holds, in
    /// `Typography.monoChip` after the badge's mark, at the sidebar's narrowest.
    public static let maxLength = 40

    // MARK: - A driven task's line

    /// The line on a driven task's row and its card; nil for a task you made yourself, one you took over
    /// (its card says `taken over`), one the Operator let go of, and every task of an ended broadcast.
    /// `tasks` names the tasks it waits for; without them the parent is "another task".
    public static func task(_ task: TaskItem, run: OperatorRun, acting: OperatorAct?, requests: [BroadcastRequest],
                            tasks: [UUID: TaskItem] = [:]) -> OperatorLine? {
        guard let operated = task.operated, operated.runId == run.id, !operated.takenOver, operated.state != .stopped,
              run.state != .stopped, run.intent != .stopped else { return nil }
        let oracle = run.profile.oracle.agent
        // A finished task's leftover asks nothing.
        if !SidebarModel.isFinished(operated.state) {
            if let request = first(requests.filter { $0.runId == run.id && $0.taskId == task.id }) {
                return line(for: request, task: task, oracle: oracle)
            }
        }
        if let acting, operated.state != .blocked { return act(acting, task: task, named: nil, oracle: oracle) }
        if operated.state == .working, let review = operated.agentReview, review.isRunning {
            return act(.reviewingWith, task: task, named: nil, oracle: oracle)
        }
        let sha = String((operated.publication?.mergedSHA ?? operated.acceptance?.resultSHA ?? "").prefix(7))
        func quiet(_ text: String) -> OperatorLine { OperatorLine(text, oracleAgent: oracle) }
        switch operated.state {
        case .planned, .queued:
            if let parent = operated.stackedOn ?? operated.dependsOn.first?.task {
                return quiet(fit("queued", "after " + (label(of: tasks[parent]) ?? "another task")))
            }
            // Added to the backlog after the first plan (spec §4.1).
            return quiet(operated.firstRevision > 1 ? "added by the Operator" : "queued")
        case .working:
            return quiet("working")
        case .inReview:
            if let people = operated.peopleReview, !people.reviewers.isEmpty, !people.ended {
                return quiet(fit("in review", "waiting on " + list(people.reviewers)))
            }
            if let review = operated.agentReview { return quiet("in review · " + SidebarModel.agentName(review.agent)) }
            return quiet("in review")
        case .failed:
            return quiet(reason(operated.blockedReason).map { fit("failed", $0) } ?? "failed")
        case .blocked:
            return needsYou("blocked", reason(operated.blockedReason) ?? "it needs you", tooltip: nil, oracle: oracle)
        case .stopped:
            return nil
        case .accepted:
            return quiet("done · " + sha)
        case .noChange:
            return quiet("done · no change")
        case .published:
            switch operated.end {
            case .commit: return quiet("done · " + sha)
            case .merge: return quiet("merged · " + sha)
            case .mergeLocal: return quiet("merged locally · " + sha)
            case .draftMR:
                if let publication = operated.publication, let number = publication.mergeRequestNumber {
                    return quiet("draft MR · " + CodeHost(webURL: publication.mergeRequestURL ?? "").reference(number))
                }
                return quiet("draft MR · " + sha)
            }
        }
    }

    // MARK: - The broadcast's line

    /// The broadcast row's line and the board's band: the one thing that needs you, else the run's own
    /// state, else what the Operator is doing, else what its tasks are doing. `acting`'s task is the
    /// task's `key` (or its id); `tasks` are the broadcast's.
    public static func broadcast(_ run: OperatorRun, tasks: [TaskItem], acting: (OperatorAct, task: String?)?,
                                 requests: [BroadcastRequest]) -> OperatorLine {
        let oracle = run.profile.oracle.agent
        let driven = tasks.filter { $0.operated?.runId == run.id }
        let asked = requests.filter { $0.runId == run.id }
        // A request outranks everything: one is said, several are counted by what asks.
        if let top = first(asked) {
            let subjects = Set(asked.map { $0.taskId?.uuidString ?? "run" })
            guard subjects.count > 1 else { return line(for: top, task: driven.first { $0.id == top.taskId }, oracle: oracle) }
            return OperatorLine("waiting on you · \(subjects.count) tasks", look: .needsYou,
                                tooltip: asked.map(\.text).joined(separator: "\n"), oracleAgent: oracle)
        }
        func quiet(_ text: String) -> OperatorLine { OperatorLine(text, oracleAgent: oracle) }
        if run.state == .operatorOffline { return quiet("paused · the Operator’s window is closed") }
        if run.state == .paused || run.intent == .paused { return quiet("paused") }
        if run.state == .complete { return quiet("done · debrief ready") }
        if run.state == .stopped || run.intent == .stopped { return quiet("ended") }
        if let (act, ref) = acting {
            let task = ref.flatMap { ref in driven.first { $0.operated?.key == ref || $0.id.uuidString == ref } }
            return self.act(act, task: task, named: act.namesItsTask ? (label(of: task) ?? ref) : nil, oracle: oracle)
        }
        if run.state == .planning { return OperatorLine("loading the construct", look: .acting, oracleAgent: oracle) }
        let open = driven.filter { ($0.operated).map { !$0.takenOver && $0.state.isOpen } ?? false }
        let working = open.filter { $0.operated?.state == .working }.count
        if working > 0 { return quiet("working · \(working) \(working == 1 ? "task" : "tasks")") }
        // Waiting only on people: the names its reviews wait on, each once.
        var names: [String] = []
        for task in open {
            guard let operated = task.operated, operated.state == .inReview, let people = operated.peopleReview, !people.ended else { continue }
            for name in people.reviewers where !names.contains(name) { names.append(name) }
        }
        if !names.isEmpty { return quiet(fit("in review", "waiting on " + list(names))) }
        return quiet("working")
    }

    // MARK: - The words

    /// An act's line: the words in the task's agent (a review's in its reviewer's), and on the broadcast's
    /// line the task it is about after them.
    private static func act(_ act: OperatorAct, task: TaskItem?, named label: String?, oracle: AgentKind) -> OperatorLine {
        let agent: AgentKind
        if act == .reviewingWith {
            // The reviewer is the other family unless the review says which (`review_task`).
            agent = task?.operated?.agentReview?.agent ?? ((task?.agent ?? .claude) == .claude ? .codex : .claude)
        } else {
            agent = task?.agent ?? .claude
        }
        let words = act.words(agent: agent, names: task?.operated?.peopleReview?.reviewers ?? [])
        let whole = label.map { words + " · " + $0 } ?? words
        return OperatorLine(label.map { fit(words, $0) } ?? cut(words), look: .acting, oracle: act == .consultingTheOracle,
                            tooltip: whole, oracleAgent: oracle)
    }

    /// The request a line says, of several: an agent's prompt first, then a question, then what blocks.
    private static func first(_ requests: [BroadcastRequest]) -> BroadcastRequest? {
        let order: [BroadcastRequest.Kind] = [.permission, .question, .blocked, .problem]
        return requests.min { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }

    /// A request as a line: `waiting on you · npm install?`, `waiting on you · retry policy?`,
    /// `blocked · the tests fail on main`; the request's sentence its tooltip.
    private static func line(for request: BroadcastRequest, task: TaskItem?, oracle: AgentKind) -> OperatorLine {
        switch request.kind {
        case .permission:
            return needsYou("waiting on you", permission(request.text, task: task), tooltip: request.text, oracle: oracle)
        case .question:
            let prefix = "The Operator asks: "
            let asked = request.text.hasPrefix(prefix) ? String(request.text.dropFirst(prefix.count)) : request.text
            return needsYou("waiting on you", asked.trimmingCharacters(in: .whitespacesAndNewlines), tooltip: request.text, oracle: oracle)
        case .blocked:
            return needsYou("blocked", reason(task?.operated?.blockedReason) ?? "it needs you", tooltip: request.text, oracle: oracle)
        case .problem:
            return needsYou("blocked", reason(task?.operated?.blockedReason) ?? "a problem in AiTerm", tooltip: request.text, oracle: oracle)
        }
    }

    /// What a prompt asks, as a short question: `npm install?` from "Codex asks to run npm install in …",
    /// and `permission?` while AiTerm knows no more of it than that it is one.
    private static func permission(_ text: String, task: TaskItem?) -> String {
        guard let asks = text.range(of: " asks to ") else { return "permission?" }
        var phrase = String(text[asks.upperBound...])
        if let task, let place = phrase.range(of: " in \(task.title)", options: .backwards) { phrase = String(phrase[..<place.lowerBound]) }
        phrase = phrase.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if phrase.hasPrefix("run ") { phrase = String(phrase.dropFirst(4)) }
        return phrase.isEmpty ? "permission?" : phrase + "?"
    }

    private static func needsYou(_ state: String, _ detail: String, tooltip: String?, oracle: AgentKind) -> OperatorLine {
        OperatorLine(fit(state, detail), look: .needsYou, tooltip: tooltip ?? state + " · " + detail, oracleAgent: oracle)
    }

    /// A reason as a detail: trimmed, its full stop dropped.
    private static func reason(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        while text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// How a line names a task: its ticket's key, or its title.
    private static func label(of task: TaskItem?) -> String? { task.map { $0.jira?.key ?? $0.title } }

    /// Names as a sentence lists them: `Jan`, `Jan and Piet`, `Jan, Piet and An`.
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// `state · detail`, the detail cut at a word, with an ellipsis, so the whole is at most `maxLength`.
    public static func fit(_ state: String, _ detail: String) -> String {
        let whole = state + " · " + detail
        guard whole.count > maxLength else { return whole }
        let room = maxLength - state.count - 4   // the separator and the ellipsis
        guard room > 0 else { return cut(whole) }
        return state + " · " + shortened(detail, to: room)
    }

    /// Words with no detail, cut the same way.
    private static func cut(_ text: String) -> String {
        text.count > maxLength ? shortened(text, to: maxLength - 1) : text
    }

    private static func shortened(_ text: String, to room: Int) -> String {
        var kept = String(text.prefix(room))
        // At a word, unless that loses more than half of what fits.
        if let space = kept.lastIndex(of: " "), kept.distance(from: kept.startIndex, to: space) > room / 2 {
            kept = String(kept[..<space])
        }
        return kept.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:·")) + "…"
    }
}
