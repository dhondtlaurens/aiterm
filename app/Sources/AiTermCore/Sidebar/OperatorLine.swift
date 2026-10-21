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
/// - `quiet`: the Operator watches and nothing moves (`queued · after PAY-232`, `in review · waiting on
///   Jan`, `paused`).
/// - `ended`: drawn as quiet, the Operator's work on the task is over (`done · 4f2a91c`, `merged · 9b3e07d`,
///   `draft MR · !412`): the row's trailing mark is the check (1A, 21 Oct 2026).
/// - `acting`: something moves, as the row's `StatusMark` turns: the task's agent works (`working`), or
///   AiTerm carries out one of the Operator's acts (`OperatorAct`).
/// - `needsYou`: yours to act on: a request (`waiting on you`, `waiting on you · 2 tasks`, `blocked · the
///   tests fail on main`), or a publication left for you (`left for you · 4f2a91c`).
///
/// A request outranks an act. What a prompt or a question asks is in `tooltip`, not on the line: the
/// task's window, a click away, shows it whole. A blocked task's reason stays, cut to fit the sidebar's
/// status line, since no window says it. Nothing here says progress: the broadcast's `2 of 8 done` follows
/// its line.
public struct OperatorLine: Equatable, Sendable {
    public enum Look: Equatable, Sendable { case quiet, ended, acting, needsYou }
    public var text: String
    public var look: Look
    /// The whole of what the line says: the request's sentence, or the words before they were cut.
    public var tooltip: String

    public init(_ text: String, look: Look = .quiet, tooltip: String? = nil) {
        self.text = text; self.look = look; self.tooltip = tooltip ?? text
    }

    /// The most characters a line says before its detail is cut: what the sidebar's status line holds, in
    /// `Typography.monoChip`, at the sidebar's narrowest.
    public static let maxLength = 40

    // MARK: - A driven task's line

    /// The line on a driven task's row and its card; nil for a task you made yourself, one you took over
    /// (its card says `taken over`), one the Operator let go of, and every task of an ended broadcast.
    /// `tasks` names the tasks it waits for; without them the parent is "another task".
    public static func task(_ task: TaskItem, run: OperatorRun, acting: OperatorAct?, requests: [BroadcastRequest],
                            tasks: [UUID: TaskItem] = [:]) -> OperatorLine? {
        guard let operated = task.operated, operated.runId == run.id, !operated.takenOver, operated.state != .stopped,
              run.state != .stopped, run.intent != .stopped else { return nil }
        // A finished task's leftover asks nothing.
        if !operated.isFinished {
            if let request = first(requests.filter { $0.runId == run.id && $0.taskId == task.id }) {
                return line(for: request, task: task)
            }
        }
        if let acting, operated.state != .blocked { return act(acting, task: task, named: nil) }
        if operated.state == .working, let review = operated.agentReview, review.isRunning {
            return act(.reviewingWith, task: task, named: nil)
        }
        func quiet(_ text: String) -> OperatorLine { OperatorLine(text) }
        func quiet(_ state: String, _ detail: String) -> OperatorLine { OperatorLine.quiet(state, detail) }
        switch operated.state {
        case .planned, .queued:
            if let parent = operated.stackedOn ?? operated.dependsOn.first?.task {
                return quiet("queued", "after " + (label(of: tasks[parent]) ?? "another task"))
            }
            // Added to the backlog after the first plan (spec §4.1).
            return quiet(operated.firstRevision > 1 ? "added by the Operator" : "queued")
        case .working:
            // The agent works: the line moves with the row's mark.
            return OperatorLine("working", look: .acting)
        case .inReview:
            if let people = operated.peopleReview, !people.reviewers.isEmpty, !people.ended {
                return quiet("in review", "waiting on " + list(people.reviewers))
            }
            if let review = operated.agentReview { return quiet("in review · " + SidebarModel.agentName(review.agent)) }
            return quiet("in review")
        case .failed:
            return reason(operated.blockedReason).map { quiet("failed", $0) } ?? quiet("failed")
        case .blocked:
            return needsYou("blocked", reason(operated.blockedReason) ?? "it needs you", tooltip: nil)
        case .stopped:
            return nil
        case .accepted:
            if let ending = ending(of: operated) {
                // Its publication handed back: the one finished state that is yours to act on.
                return OperatorLine(ending, look: operated.publication?.leftForYou == true ? .needsYou : .ended)
            }
            if let problem = reason(operated.publication?.problem) { return needsYou("blocked", problem, tooltip: nil) }
            if let publication = operated.publication, publication.waitingSince != nil { return quiet("waiting to merge", publication.waitingReason ?? "the host is not ready") }
            // AiTerm publishes it now: something moves, as with any act.
            return OperatorLine(operated.end == .draftMR ? "opening the MR" : "merging", look: .acting)
        case .noChange, .published:
            return ending(of: operated).map { OperatorLine($0, look: .ended) }
        }
    }

    /// What a finished task ended at, as its line and the debrief's Delivered row say it: `done · 4f2a91c`,
    /// `done · no change`, `merged · 9b3e07d`, `merged locally · 1c84e20`, `draft MR · !412`. Nil for a task
    /// that has not finished.
    public static func ending(of operated: OperatedTask) -> String? {
        let sha = String((operated.publication?.mergedSHA ?? operated.acceptance?.resultSHA ?? "").prefix(7))
        switch operated.state {
        case .accepted:
            if operated.publication?.leftForYou == true { return "left for you · " + sha }
            return operated.end == .commit ? "done · " + sha : nil
        case .noChange:
            return "done · no change"
        case .published:
            switch operated.end {
            case .commit: return "done · " + sha
            case .merge: return "merged · " + sha
            case .mergeLocal: return "merged locally · " + sha
            case .draftMR:
                if let publication = operated.publication, let number = publication.mergeRequestNumber {
                    return "draft MR · " + CodeHost(webURL: publication.mergeRequestURL ?? "").reference(number)
                }
                return "draft MR · " + sha
            }
        default:
            return nil
        }
    }

    // MARK: - The broadcast's line

    /// The broadcast row's line and the board's band: the one thing that needs you, else the run's own
    /// state, else what the Operator is doing, else what its tasks are doing. `acting`'s task is the
    /// task's `key` (or its id); `tasks` are the broadcast's; `ready` the working ones whose workers all
    /// ended their turn, waiting for the Operator to accept them (`TaskItem.isReadyForAcceptance(in:)`).
    public static func broadcast(_ run: OperatorRun, tasks: [TaskItem], acting: (OperatorAct, task: String?)?,
                                 requests: [BroadcastRequest], ready: Set<UUID> = []) -> OperatorLine {
        let driven = tasks.filter { $0.operated?.runId == run.id }
        // A finished task's leftover asks nothing, as on its own line.
        let finished = Set(driven.filter { $0.operated.map(\.isFinished) ?? false }.map(\.id))
        let asked = requests.filter { $0.runId == run.id && !($0.taskId.map(finished.contains) ?? false) }
        // A request outranks everything: one is said, several are counted by what asks.
        if let top = first(asked) {
            let subjects = Set(asked.map { $0.taskId?.uuidString ?? "run" })
            guard subjects.count > 1 else { return line(for: top, task: driven.first { $0.id == top.taskId }) }
            return OperatorLine("waiting on you · \(subjects.count) tasks", look: .needsYou,
                                tooltip: asked.map(\.text).joined(separator: "\n"))
        }
        func quiet(_ text: String) -> OperatorLine { OperatorLine(text) }
        if run.state == .operatorOffline { return quiet("paused · the Operator’s window is closed") }
        if run.state == .paused || run.intent == .paused { return quiet("paused") }
        if run.state == .complete { return quiet("done · debrief ready") }
        if run.state == .stopped || run.intent == .stopped { return quiet("ended") }
        if let (act, ref) = acting {
            let task = ref.flatMap { ref in driven.first { $0.operated?.key == ref || $0.id.uuidString == ref } }
            return self.act(act, task: task, named: act.namesItsTask ? (label(of: task) ?? ref) : nil)
        }
        if run.state == .planning { return OperatorLine("loading the construct", look: .acting) }
        let open = driven.filter { ($0.operated).map { !$0.takenOver && $0.state.isOpen } ?? false }
        let working = open.filter { $0.operated?.state == .working }
        let waiting = working.filter { ready.contains($0.id) }.count
        if !working.isEmpty { return counted(working: working.count - waiting, ready: waiting) }
        // Waiting only on people: the names its reviews wait on, each once.
        var names: [String] = []
        for task in open {
            guard let operated = task.operated, operated.state == .inReview, let people = operated.peopleReview, !people.ended else { continue }
            for name in people.reviewers where !names.contains(name) { names.append(name) }
        }
        if !names.isEmpty { return OperatorLine.quiet("in review", "waiting on " + list(names)) }
        return quiet("working")
    }

    // MARK: - The words

    /// What the broadcast's line counts its working tasks as, each with its words: kept here alone, so
    /// renaming one is one edit.
    public enum Count: Sendable {
        /// Its agent is at work.
        case working
        /// Its workers all ended their turn: its result waits for the Operator to check and accept it.
        case readyToAccept

        public var words: String {
            switch self {
            case .working: "working"
            case .readyToAccept: "ready to accept"
            }
        }
    }

    /// The working tasks counted: `working · 2 tasks`, `ready to accept · 1 task`, or both, `working · 2 tasks
    /// · 1 ready to accept`. While one is at work the line moves with the row's mark; with every one ready it
    /// waits on the Operator, quiet.
    static func counted(working: Int, ready: Int) -> OperatorLine {
        func tasks(_ count: Int) -> String { "\(count) \(count == 1 ? "task" : "tasks")" }
        guard working > 0 else { return OperatorLine(Count.readyToAccept.words + " · " + tasks(ready)) }
        let waiting = ready > 0 ? " · \(ready) " + Count.readyToAccept.words : ""
        return OperatorLine(Count.working.words + " · " + tasks(working) + waiting, look: .acting)
    }

    /// An act's line: the words in the task's agent (a review's in its reviewer's), and on the broadcast's
    /// line the task it is about after them.
    private static func act(_ act: OperatorAct, task: TaskItem?, named label: String?) -> OperatorLine {
        let agent: AgentKind
        if act == .reviewingWith {
            // The reviewer is the other family unless the review says which (`review_task`).
            agent = task?.operated?.agentReview?.agent ?? ((task?.agent ?? .claude) == .claude ? .codex : .claude)
        } else {
            agent = task?.agent ?? .claude
        }
        let words = act.words(agent: agent, names: task?.operated?.peopleReview?.reviewers ?? [])
        let whole = label.map { words + " · " + $0 } ?? words
        return OperatorLine(label.map { fit(words, $0) } ?? cut(words), look: .acting, tooltip: whole)
    }

    /// The request a line says, of several: an agent's prompt first, then a question, then what blocks.
    /// The board's card opens the place of the same one.
    static func first(_ requests: [BroadcastRequest]) -> BroadcastRequest? {
        let order: [BroadcastRequest.Kind] = [.permission, .question, .blocked, .problem]
        return requests.min { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }

    /// A request as a line: `waiting on you` for a prompt or a question, its sentence the tooltip;
    /// `blocked · the tests fail on main` for what blocks, the reason kept.
    private static func line(for request: BroadcastRequest, task: TaskItem?) -> OperatorLine {
        switch request.kind {
        case .permission, .question:
            return OperatorLine("waiting on you", look: .needsYou, tooltip: request.text)
        case .blocked:
            return needsYou("blocked", reason(task?.operated?.blockedReason) ?? "it needs you", tooltip: request.text)
        case .problem:
            return needsYou("blocked", reason(task?.operated?.publication?.problem ?? task?.operated?.blockedReason) ?? "a problem in AiTerm", tooltip: request.text)
        }
    }

    /// A quiet `state · detail`, cut to fit, the whole of it in the tooltip.
    private static func quiet(_ state: String, _ detail: String) -> OperatorLine {
        OperatorLine(fit(state, detail), tooltip: state + " · " + detail)
    }

    private static func needsYou(_ state: String, _ detail: String, tooltip: String?) -> OperatorLine {
        OperatorLine(fit(state, detail), look: .needsYou, tooltip: tooltip ?? state + " · " + detail)
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
