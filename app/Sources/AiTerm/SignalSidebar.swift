import Foundation
import AiTermCore

struct SignalSection: Equatable, Identifiable {
    var signal: Signal
    var tasks: [TaskRow]
    var skipped: [String] = []
    var failure: String?
    var removed = false
    var id: UUID { signal.id }
    var collapsed: Bool { signal.collapsed || tasks.isEmpty }
}

/// Reuses the project's exact task rows. Moving ownership changes only which heading holds them.
struct SignalSidebar {
    var signals: [SignalSection]
    var projects: [SidebarEntry]
    init(state: AppState, entries: [SidebarEntry]) {
        let held = state.tasks.filter { $0.signalTask.map { $0.phase != .stopped } == true }
        let ids = Set(held.map(\.id))
        let rows = Dictionary(entries.flatMap { entry -> [TaskRow] in
            if case .project(let section) = entry { return section.tasks }; return []
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var definitions = state.signals
        for task in held {
            if let record = task.signalTask, !definitions.contains(where: { $0.id == record.signal }), let saved = record.configuration {
                var removed = saved; removed.enabled = false; definitions.append(removed)
            }
        }
        signals = definitions.map { signal in
            var section = SignalSection(signal: signal, tasks: held.filter { $0.signalTask?.signal == signal.id }.compactMap { task in rows[task.id].map { Self.present($0, task: task, state: state) } })
            section.skipped = state.signalSeen.filter { $0.signal == signal.id && $0.disposition == .skipped && $0.isMatching }
                .map { ($0.item.identity ?? "Item") + ": " + ($0.reason ?? "No project") }.sorted()
            section.failure = state.operatorSession?.sourceFailures?[signal.id.uuidString]
            section.removed = state.signal(id: signal.id) == nil
            return section
        }
        projects = entries.map { entry in
            guard case .project(var section) = entry else { return entry }
            section.tasks.removeAll { ids.contains($0.id) }
            return .project(section)
        }
    }
    private static func present(_ original: TaskRow, task: TaskItem, state: AppState) -> TaskRow {
        guard let record = task.signalTask else { return original }
        var row = original
        let busy = [.working, .background].contains(row.status)
        let paused = state.operatorSession?.paused == true || state.signal(id: record.signal)?.enabled == false
        let questions = state.currentOperatorQuestions.filter { $0.task == task.id }
        if row.status == .needsInput { return row }
        if paused && !busy { row.operatorLine = .paused; row.paused = true; row.status = .idle }
        else if let question = questions.first {
            row.operatorLine = OperatorLine("waiting on you", look: .needsYou, tooltip: question.text); row.status = .needsInput
        } else if let act = record.currentAct {
            row.operatorLine = OperatorLine("Operator " + act, look: .acting); row.status = .working
        } else {
            switch record.phase {
            case .launching: row.operatorLine = OperatorLine("starting its worker", look: .acting); row.status = .working
            case .choosing:
                // The Operator's turn, never the person's: the acting look, counted as work.
                let projectOnly = (record.choosableRows?.count ?? 0) == 1 && (record.candidateProjects?.count ?? 0) > 1
                row.operatorLine = OperatorLine("Operator choosing " + (projectOnly ? "its project" : "its agent"), look: .acting)
                row.status = .working
            case .working:
                if task.windowId == nil && task.firstWorkerConversation != nil { row.operatorLine = .windowClosed; row.status = .idle }
                // Every worker ended its turn and the Operator does nothing yet: the turn is the Operator's to read,
                // so no done ring (P3 1A), and nothing runs, so no spinner either.
                else if !busy { row.operatorLine = .workerDone; row.status = .waiting }
            case .watching(let condition):
                row.operatorLine = .waiting(for: condition, facts: record.waitingOn, request: task.mr?.reference, ticket: task.jira?.key)
                if !busy {
                    if case .unknown = condition { row.status = .idle } else { row.status = .waiting }
                }
            case .blocked:
                row.operatorLine = OperatorLine("blocked", look: .needsYou, tooltip: record.blockedReason ?? "Open its window to inspect it.")
                row.status = .needsInput
            case .done, .archived:
                row.operatorLine = OperatorLine("done", look: .ended); if !busy { row.status = .idle }
            case .stopped, .unknown: break
            }
        }
        return row
    }
}

/// Only drawn facts: repeated activity events redraw this row without changing task rows.
struct SignalOperatorRowValue: Equatable, Identifiable {
    var id: UUID { OperatorSession.rowID }
    var line: OperatorLine
    var status: TaskStatus
    var paused: Bool
    var shown = true
    var event: UUID?
    var completedActivity: OperatorLine?
    static let empty = Self(line: OperatorLine("watching 0 tasks in 0 signals"), status: .idle, paused: false, shown: false)
    static func make(state: AppState, sessions: [SessionInfo], issue: String? = nil, activity: OperatorActivity? = nil) -> Self {
        let session = state.operatorSession
        let workload = state.operatorWorkTasks
        let questions = state.currentOperatorQuestions
        let tasks = workload.count
        let signals = Set(workload.compactMap { $0.signalTask?.signal }).count
        // A closed generation's last snapshot must not resurrect its row or permission prompt.
        let own = session.flatMap { session in
            session.window.flatMap { window in sessions.first { $0.taskUUID == session.id && $0.agent == .claude && $0.windowId == window } }
        }
        let line: OperatorLine
        if session?.paused == true && tasks > 0 { line = .paused }
        else if own?.state == .needsInput { line = OperatorLine("needs you", look: .needsYou, tooltip: issue ?? "The Operator needs input in its chat.") }
        else if let issue { line = OperatorLine("needs you", look: .needsYou, tooltip: issue) }
        else if session?.finishing == true { line = OperatorLine("finishing its session", look: .acting) }
        else if session?.startingFresh == true {
            line = OperatorLine("starting fresh · \(tasks) \(tasks == 1 ? "task" : "tasks") carried over", look: .acting)
        }
        else if !questions.isEmpty {
            line = OperatorLine("waiting on you · \(questions.count)", look: .needsYou)
        }
        else if let current = activity?.line { line = current }
        else if let task = workload.first(where: { $0.signalTask?.currentAct != nil }), let act = task.signalTask?.currentAct {
            let name = OperatorActivityTracker.name(task)
            let text = act.contains("its worker") ? act.replacingOccurrences(of: "its worker", with: name + "’s worker") : act + " · " + name
            line = OperatorLine(text, look: .acting)
        }
        else if own?.state == .working { line = .working }
        else { line = OperatorLine("watching \(tasks) \(tasks == 1 ? "task" : "tasks") in \(signals) \(signals == 1 ? "signal" : "signals")") }
        let status: TaskStatus = line.look == .needsYou ? .needsInput : line.look == .acting ? .working : .idle
        let shown = tasks > 0 || !questions.isEmpty || own?.state == .needsInput || own?.state == .working || issue != nil
            || session?.finishing == true || (session?.window != nil && activity?.line != nil)
        return Self(line: shown ? line : Self.empty.line, status: shown ? status : .idle, paused: session?.paused == true,
                    shown: shown, event: shown ? activity?.id : nil,
                    completedActivity: shown && line.look != .needsYou && session?.paused != true
                        && session?.startingFresh != true ? activity?.completed : nil)
    }
}
