import Foundation
import AiTermCore

struct SignalSection: Equatable, Identifiable {
    var signal: Signal
    var tasks: [TaskRow]
    var skipped: [String] = []
    var failure: String?
    var removed = false
    var id: UUID { signal.id }
    var removedFolded = false
    /// Whether Move Up and Move Down have a live neighbour; always false on a removed signal's heading.
    var canMoveUp = false, canMoveDown = false
    var collapsed: Bool { (removed ? removedFolded : signal.collapsed) || tasks.isEmpty }
}

/// Reuses the project's exact task rows. Moving ownership changes only which heading holds them.
/// `acts` are the acts the Operator runs on tasks now (`OperatorActivityTracker.actsByTask`); `skipped` each
/// signal's skipped-item sentences (`skipped(in:)`).
struct SignalSidebar {
    var signals: [SignalSection]
    var projects: [SidebarEntry]
    init(state: AppState, entries: [SidebarEntry], acts: [UUID: String] = [:], skipped: [UUID: [String]] = [:],
         foldedRemovedSignals: Set<UUID> = []) {
        let held = state.tasks.filter { $0.isUnderOperator }
        let ids = Set(held.map(\.id))
        let rows = Dictionary(entries.flatMap { entry -> [TaskRow] in
            if case .project(let section) = entry { return section.tasks }; return []
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var definitions = state.signals
        for task in held {
            if let record = task.signalTask, !definitions.contains(where: { $0.id == record.current.signal }) {
                definitions.append(record.current.configuration)
            }
        }
        signals = definitions.map { signal in
            var section = SignalSection(signal: signal, tasks: held.filter { $0.signalTask?.current.signal == signal.id }.compactMap { task in
                rows[task.id].map { $0.presentingOperator(task: task, state: state, act: acts[task.id]) }
            })
            section.skipped = skipped[signal.id] ?? []
            section.failure = state.operatorSession?.sourceFailures?[signal.id.uuidString]
            section.removed = state.signal(id: signal.id) == nil
            section.removedFolded = foldedRemovedSignals.contains(signal.id)
            section.canMoveUp = state.canMove(signalId: signal.id, .up)
            section.canMoveDown = state.canMove(signalId: signal.id, .down)
            return section
        }
        projects = entries.map { entry in
            guard case .project(var section) = entry else { return entry }
            section.tasks.removeAll { ids.contains($0.id) }
            return .project(section)
        }
    }
    /// Each signal's skipped items as its heading's tooltip lists them, sorted: "PAY-1: No project".
    static func skipped(in state: AppState) -> [UUID: [String]] {
        Dictionary(grouping: state.signalSeen.filter { $0.disposition == .skipped && $0.isMatching }, by: \.signal)
            .mapValues { $0.map { ($0.item.identity ?? "Item") + ": " + ($0.reason ?? "No project") }.sorted() }
    }
}

/// Only drawn facts: repeated activity events redraw this row without changing task rows.
struct SignalOperatorRowValue: Equatable, Identifiable {
    var id: UUID { OperatorSession.rowID }
    /// What the Operator holds: "3 tasks · 2 signals", or "No tasks". Its heading already says "Operator".
    var title = Self.title(tasks: 0, signals: 0)
    var line: OperatorLine
    var status: TaskStatus
    var paused: Bool
    var shown = true
    var event: UUID?
    var completedActivity: OperatorLine?
    /// Its trailing mark, by the task row's rule: the pause sign during your pause.
    var mark: TaskRowMark { TaskRowMark(status: status, line: line, paused: paused) }
    /// It waits on you only while it needs input: a question for you, or its chat asking.
    var needsYou: Bool { status == .needsInput }
    static let empty = Self(line: OperatorLine("watching"), status: .idle, paused: false, shown: false)
    /// Every workload task has a signal task, so a task always counts at least one signal.
    static func title(tasks: Int, signals: Int) -> String {
        guard tasks > 0 else { return "No tasks" }
        return "\(tasks) \(tasks == 1 ? "task" : "tasks") · \(signals) \(signals == 1 ? "signal" : "signals")"
    }
    /// `latestAct` is the most recent act the Operator runs on a task (`OperatorActivityTracker.latestAct`).
    static func make(state: AppState, sessions: [SessionInfo], issue: String? = nil, activity: OperatorActivity? = nil,
                     latestAct: OperatorAct? = nil) -> Self {
        let session = state.operatorSession
        let workload = state.operatorWorkTasks
        let questions = state.currentOperatorQuestions
        let tasks = workload.count
        let signals = Set(workload.compactMap { $0.signalTask?.current.signal }).count
        // A closed generation's last snapshot must not resurrect its row or permission prompt.
        let own = session.flatMap { session in
            session.window.flatMap { window in sessions.first { $0.taskUUID == session.id && $0.agent == .claude && $0.windowId == window } }
        }
        let line: OperatorLine
        if session?.paused == true && tasks > 0 { line = .paused }
        else if own?.state == .needsInput { line = OperatorLine("needs you", look: .needsYou, tooltip: issue ?? "The Operator needs input in its chat.") }
        else if let issue { line = OperatorLine("needs you", look: .needsYou, tooltip: issue) }
        else if session?.lifecycle.isRetiring == true { line = OperatorLine("finishing its session", look: .acting) }
        else if session?.lifecycle.isChanging == true {
            line = OperatorLine("starting fresh", look: .acting)
        }
        else if !questions.isEmpty {
            line = OperatorLine("waiting on you · \(questions.count)", look: .needsYou)
        }
        else if let current = activity?.line { line = current }
        else if let latestAct, let task = workload.first(where: { $0.id == latestAct.task }) {
            let act = latestAct.words, name = OperatorActivityTracker.name(task)
            let text = act.contains("its worker") ? act.replacingOccurrences(of: "its worker", with: name + "’s worker") : act + " · " + name
            line = OperatorLine(text, look: .acting)
        }
        else if own?.state == .working { line = .working }
        else { line = OperatorLine("watching") }
        let status: TaskStatus = line.look == .needsYou ? .needsInput : line.look == .acting ? .working : .idle
        let shown = tasks > 0 || !questions.isEmpty || own?.state == .needsInput || own?.state == .working || issue != nil
            || session?.lifecycle.isRetiring == true || (session?.window != nil && activity?.line != nil)
        return Self(title: Self.title(tasks: tasks, signals: signals), line: shown ? line : Self.empty.line, status: shown ? status : .idle, paused: session?.paused == true,
                    shown: shown, event: shown ? activity?.id : nil,
                    completedActivity: shown && line.look != .needsYou && session?.paused != true
                        && session?.lifecycle.isChanging != true ? activity?.completed : nil)
    }
}
