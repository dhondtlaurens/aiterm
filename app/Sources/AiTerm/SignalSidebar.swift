import Foundation
import AiTermCore

/// The Operator's section and the projects', from one derivation of the projects' entries (`SidebarModel.entries`).
/// Reuses the project's exact task rows: moving ownership changes only which section holds them.
/// `acts` are the acts the Operator runs on tasks now (`OperatorActivityTracker.actsByTask`).
struct SignalSidebar {
    /// What the Operator's section draws under its row, in the projects' order: each project with a task the Operator
    /// runs, holding only those tasks (`presentingOperator`), no terminals and no moves, folded by
    /// `AppState.operatorFolded`; a divider only while a project of it follows before the next divider.
    var operatorEntries: [SidebarEntry]
    /// The projects' entries without the tasks the Operator runs, which are drawn in its section.
    var projects: [SidebarEntry]
    /// The projects among `operatorEntries`.
    var operatorSections: [ProjectSection] {
        operatorEntries.compactMap { if case .project(let section) = $0 { return section }; return nil }
    }
    init(state: AppState, entries: [SidebarEntry], acts: [UUID: String] = [:]) {
        let held = Dictionary(state.tasks.filter(\.isUnderOperator).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let level = entries.compactMap { entry -> SidebarEntry? in
            switch entry {
            case .divider(var divider):
                divider.canMoveUp = false; divider.canMoveDown = false
                return .divider(divider)
            case .project(var section):
                section.tasks = section.tasks.compactMap { row in
                    held[row.id].map { row.presentingOperator(task: $0, state: state, act: acts[$0.id]) }
                }
                guard !section.tasks.isEmpty else { return nil }
                section.terminals = []; section.canMoveUp = false; section.canMoveDown = false
                section.project.collapsed = state.operatorFolded.contains(section.project.id)
                return .project(section)
            }
        }
        operatorEntries = level.indices.compactMap { index in
            guard case .divider = level[index] else { return level[index] }
            guard index + 1 < level.count, case .project = level[index + 1] else { return nil }
            return level[index]
        }
        projects = entries.map { entry in
            guard case .project(var section) = entry else { return entry }
            section.tasks.removeAll { held[$0.id] != nil }
            return .project(section)
        }
    }
    /// Each signal's skipped items as the signals sheet lists them and a section's amber icon says the first, sorted: "PAY-1: No project",
    /// "!12: …" for a merge request ("#12" for a GitHub pull request).
    /// A schedule's last skipped run reads by its time: "Run of 30 Nov 2026 09:00: The last run is still unfinished."
    static func skipped(in state: AppState, calendar: Calendar = .autoupdatingCurrent) -> [UUID: [String]] {
        Dictionary(grouping: state.signalSeen.filter { $0.disposition == .skipped && $0.isMatching }, by: \.signal)
            .mapValues { $0.map { seen in
                let name: String
                switch seen.item {
                case .run(let run): name = "Run of " + ScheduleDecision.runTime(run.at, calendar: calendar)
                case .mergeRequest(let request):
                    name = (state.signal(id: seen.signal)?.start.source == .gitHub ? "#" : "!") + String(request.number)
                default: name = OperatorDigest.itemName(seen.item)
                }
                return name + ": " + (seen.reason ?? "No project")
            }.sorted() }
    }
    /// Each runnable schedule's next run after `now`.
    static func nextRuns(in state: AppState, now: Date, calendar: Calendar = .autoupdatingCurrent) -> [UUID: Date] {
        state.signals.filter { $0.isScheduled && $0.isRunnable }.reduce(into: [:]) { runs, signal in
            runs[signal.id] = ScheduleDecision.nextRun(of: signal, cursor: state.scheduleCursors[signal.id], now: now, calendar: calendar)
        }
    }
}

/// Only drawn facts: repeated activity events redraw this row without changing task rows.
struct SignalOperatorRowValue: Equatable, Identifiable {
    var id: UUID { OperatorSession.rowID }
    /// What the Operator runs: "Running 3 tasks", or "No tasks". Its heading already says "Operator".
    var title = Self.title(tasks: 0)
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
    /// "Running 1 task", "Running 3 tasks", or "No tasks".
    static func title(tasks: Int) -> String {
        guard tasks > 0 else { return "No tasks" }
        return "Running \(tasks) \(tasks == 1 ? "task" : "tasks")"
    }
    /// `latestAct` is the most recent act the Operator runs on a task (`OperatorActivityTracker.latestAct`).
    static func make(state: AppState, sessions: [SessionInfo], issue: String? = nil, activity: OperatorActivity? = nil,
                     latestAct: OperatorAct? = nil) -> Self {
        let session = state.operatorSession
        let workload = state.operatorWorkTasks
        let questions = state.currentOperatorQuestions
        let tasks = workload.count
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
            // A chat held for your pause stays opening for as long as you type: the row says why.
            let waiting = session?.lifecycle == .opening && activity?.chatWaitsForPause == true
            line = waiting ? OperatorLine(OperatorSessionKeeper.pauseWords, look: .acting) : OperatorLine("starting fresh", look: .acting)
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
        return Self(title: Self.title(tasks: tasks), line: shown ? line : Self.empty.line, status: shown ? status : .idle, paused: session?.paused == true,
                    shown: shown, event: shown ? activity?.id : nil,
                    completedActivity: shown && line.look != .needsYou && session?.paused != true
                        && session?.lifecycle.isChanging != true ? activity?.completed : nil)
    }
}
