import Foundation
import AiTermCore

/// What an operation's overview draws (spec §10.7): its board, a kanban on its side — Waiting on you,
/// Working, Up next, Done, each task moving down as it progresses, empty groups left out — the plan on
/// top while one waits for your approval, what it decided on its own, to overrule in its window, and
/// which footer it has. A value, decided apart from
/// `OperationOverviewSheet`, so each moment is tested without drawing it.
struct OperationOverview: Equatable {
    enum Mark: Equatable { case waiting, working, upNext, done }

    /// The key column: a ticket's key, `to-do` for a task without one, `question` for one the operator
    /// asks about the whole operation.
    enum Key: Equatable {
        case ticket(String), todo, question
        var text: String {
            switch self {
            case .ticket(let key): key
            case .todo: "to-do"
            case .question: "question"
            }
        }
    }

    enum Link: Equatable {
        case openTask(UUID), answerInWindow
        var title: String {
            switch self {
            case .openTask: "Open Task"
            case .answerInWindow: "Answer in Window"
            }
        }
    }

    struct Item: Equatable, Identifiable {
        var id: String
        var mark: Mark
        var key: Key
        var title: String
        var detail: String = ""
        var avatars: AvatarGroup? = nil
        var link: Link? = nil
    }

    struct Group: Equatable, Identifiable {
        var title: String
        /// Waiting on you's count chip.
        var attention: Int? = nil
        var items: [Item]
        var id: String { title }
    }

    struct PlanRow: Equatable, Identifiable {
        /// The task's id, told apart by its place when a task is listed twice.
        var id: String
        /// New in this revision, or changed since the one you approved (C's `PlanRevision`).
        var change: PlanChange.Kind
        var key: Key
        var title: String
        /// Its project, its agent, what it builds on or follows, and its end: `pluto-web · Claude · builds on PLUTO-231 · commit`.
        var detail: String
        /// `+` for a task the revision adds, `~` for one it changes.
        var sign: String { change == .added ? "+" : "~" }
    }

    struct Plan: Equatable {
        static let title = "The plan waits for you"
        /// The revision Approve Plan approves — exactly this one; a later one needs its own approval.
        var revision: Int
        var help: String
        var rows: [PlanRow]
    }

    /// A decision: what, and why.
    struct Note: Equatable, Identifiable {
        /// Unique among the notes drawn together; `key` is the run's own.
        var id: String
        var key: String
        var text: String
        var why: String

        init(id: String, key: String? = nil, text: String, why: String) {
            self.id = id; self.key = key ?? id; self.text = text; self.why = why
        }
    }

    enum Footer: Equatable { case planWaits, working, paused, done }

    var title: String
    var subtitle: String
    var plan: Plan?
    var groups: [Group]
    var decisionsTitle: String?
    var decisions: [Note]
    var footer: Footer

    static func make(run: OperatorRun, state: AppState, acting: Set<UUID> = []) -> OperationOverview {
        let tasks = state.tasks.filter { $0.operated?.runId == run.id && $0.operated?.state != .stopped }
        let byId = Dictionary(state.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let challenger = SidebarModel.agentName(run.profile.oracle.agent)
        let planWaits = SidebarModel.planWaitsForYou(run)
        // What Approve Plan would release, and whether each task is new or changed: C's to decide.
        let changes = planWaits ? Dictionary(PlanRevision.pending(in: state, run: run.id).map { ($0.task, $0.kind) },
                                             uniquingKeysWith: { first, _ in first }) : [:]
        let pending = tasks.filter { changes[$0.id] != nil }
        let pendingIds = Set(pending.map(\.id))
        let open = run.questions.filter { $0.resolution == nil }

        // Waiting on you is what the operation's row counts as its attention (`SidebarModel.operationRow`):
        // every open question, and each open task waiting on you or blocked that no question names. A
        // question about a task is that task's item; one about the whole operation, or about a task that
        // is no longer on the board, is answered in the operator's window.
        var waiting: [Item] = [], asking = Set<UUID>()
        for question in open {
            if let id = question.task, let task = tasks.first(where: { $0.id == id }), !pendingIds.contains(id) {
                let first = asking.insert(id).inserted
                waiting.append(Item(id: first ? id.uuidString : "\(id.uuidString)/\(question.id)", mark: .waiting,
                                    key: Self.key(of: task), title: question.text, link: .openTask(id)))
            } else {
                waiting.append(Item(id: question.id, mark: .waiting, key: .question, title: question.text, link: .answerInWindow))
            }
        }
        var working: [Item] = [], upNext: [Item] = [], done: [Item] = []
        for task in tasks where !pendingIds.contains(task.id) && !asking.contains(task.id) {
            guard let operated = task.operated else { continue }
            let key = Self.key(of: task), agent = SidebarModel.agentName(task.agent)
            if !operated.takenOver, !SidebarModel.isFinished(operated.state),
               operated.flags.contains(.waitingOnYou) || operated.state == .blocked {
                waiting.append(Item(id: task.id.uuidString, mark: .waiting, key: key,
                                    title: operated.blockedReason ?? "\(agent) needs you", link: .openTask(task.id)))
                continue
            }
            let presence = SidebarModel.operatorPresence(task: task, run: run, acting: acting.contains(task.id))
            // Taken over only while the task is going and has not failed, as its row's caption says.
            let takenOver = operated.takenOver && operated.state.isOpen && operated.state != .failed
            switch operated.state {
            case .working, .inReview, .failed, .blocked:
                let detail = takenOver ? "taken over"
                    : operated.state == .inReview ? "in review"
                    : operated.state == .failed ? "failed" + (operated.blockedReason.map { " · " + $0 } ?? "")
                    : presence == .acting ? "answering \(agent)"
                    : operated.flags.contains(.possiblyStalled) ? "possibly stalled" : ""
                working.append(Item(id: task.id.uuidString, mark: .working, key: key, title: task.title, detail: detail,
                                    avatars: AvatarGroup(marks: [task.agent.session], overflow: 0, operatorPresence: presence)))
            case .planned, .queued:
                upNext.append(Item(id: task.id.uuidString, mark: .upNext, key: key, title: task.title,
                                   detail: takenOver ? "taken over" : Self.dependency(of: operated, tasks: byId) ?? ""))
            case .accepted, .noChange, .published:
                done.append(Item(id: task.id.uuidString, mark: .done, key: key, title: task.title,
                                 detail: Self.ending(of: operated, tasks: byId)))
            case .stopped:
                break
            }
        }

        let finished = tasks.filter { $0.operated.map { SidebarModel.isFinished($0.state) } ?? false }.count
        let doneTitle = run.state == .complete ? "Done · \(finished) of \(tasks.count)" : "Done"
        let groups = [Group(title: "Waiting on you", attention: waiting.count, items: Self.unique(waiting, \.id)),
                      Group(title: "Working", items: Self.unique(working, \.id)), Group(title: "Up next", items: Self.unique(upNext, \.id)),
                      Group(title: doneTitle, items: Self.unique(done, \.id))].filter { !$0.items.isEmpty }

        let plan: Plan? = !planWaits ? nil : Plan(
            revision: run.planRevision,
            help: Self.planHelp(run, challenger: challenger),
            rows: Self.unique(pending.compactMap { task -> PlanRow? in
                guard let operated = task.operated else { return nil }
                let detail = [state.project(id: task.projectId)?.name, SidebarModel.agentName(task.agent),
                              Self.dependency(of: operated, tasks: byId), Self.endWord(operated.end)]
                return PlanRow(id: task.id.uuidString, change: changes[task.id] ?? .added, key: Self.key(of: task), title: task.title,
                               detail: detail.compactMap { $0 }.joined(separator: " · "))
            }, \.id))

        let decisions = Self.unique(run.decisions.map { decision in
            Note(id: decision.key, text: decision.text,
                 why: decision.challenge.map { "\(challenger) said: “\($0)” Overrule it in the window if not." }
                    ?? "Overrule it in the window if not.")
        }, \.id)
        let footer: Footer = planWaits ? .planWaits
            : run.state == .complete ? .done
            : run.state == .paused || run.state == .operatorOffline ? .paused
            : .working

        return OperationOverview(
            title: run.name,
            subtitle: "Operator · done when: \(run.done ?? "a commit per task")",
            plan: plan, groups: groups,
            decisionsTitle: decisions.isEmpty ? nil : "Decided on its own · \(decisions.count)", decisions: decisions,
            footer: footer)
    }

    /// `values` with each repeat of an id told apart by its place (`id#3`), so a `ForEach` over them never
    /// sees one twice: the first keeps its own id, and no new id is one another value already has.
    private static func unique<T>(_ values: [T], _ id: WritableKeyPath<T, String>) -> [T] {
        var taken = Set(values.map { $0[keyPath: id] }), first = Set<String>()
        var result = values
        for i in result.indices {
            let own = result[i][keyPath: id]
            if first.insert(own).inserted { continue }
            var candidate = "\(own)#\(i)"
            while taken.contains(candidate) { candidate += "’" }
            taken.insert(candidate)
            result[i][keyPath: id] = candidate
        }
        return result
    }

    private static func key(of task: TaskItem) -> Key { task.jira.map { .ticket($0.key) } ?? .todo }

    /// `builds on PLUTO-231` for a task stacked on another's result, `after PLUTO-231` for one that only waits for it.
    private static func dependency(of operated: OperatedTask, tasks: [UUID: TaskItem]) -> String? {
        if let parent = operated.stackedOn ?? operated.dependsOn.first(where: { $0.kind == .code })?.task {
            return "builds on " + SidebarModel.dependencyLabel(parent, tasks: tasks)
        }
        return operated.dependsOn.first.map { "after " + SidebarModel.dependencyLabel($0.task, tasks: tasks) }
    }

    /// What a finished task ended at: its commit — and the commit it builds on — no change, or its
    /// merge or draft MR.
    private static func ending(of operated: OperatedTask, tasks: [UUID: TaskItem]) -> String {
        let sha = String((operated.acceptance?.resultSHA ?? "").prefix(7))
        switch operated.state {
        case .noChange:
            return "no change"
        case .published:
            return ([.merge, .mergeLocal].contains(operated.end) ? "merged · " : operated.end == .draftMR ? "draft MR · " : "") + sha
        default:
            let parent = operated.stackedOn.flatMap { tasks[$0]?.operated?.acceptance?.resultSHA }.map { String($0.prefix(7)) }
            return sha + (parent.map { " · builds on " + $0 } ?? "")
        }
    }

    private static func endWord(_ end: TaskEnd) -> String {
        switch end {
        case .commit: "commit"
        case .draftMR: "draft MR"
        case .merge: "merge"
        case .mergeLocal: "local merge"
        }
    }

    /// The plan box's line: nothing starts before you approve, and what the second opinion changed.
    private static func planHelp(_ run: OperatorRun, challenger: String) -> String {
        let lead = "Nothing starts until you approve."
        guard run.profile.oracle.isOn else { return lead }
        let changes = run.decisions.filter { $0.challenge != nil && $0.task == nil }.count
        let outcome = changes == 0 ? "nothing changed." : changes == 1 ? "one change came of it." : "\(changes) changes came of it."
        return "\(lead) \(challenger) gave a second opinion; \(outcome)"
    }
}
