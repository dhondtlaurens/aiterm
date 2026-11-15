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
        let held = state.tasks.filter { $0.signalTask.map { !$0.takenOver && $0.phase != .stopped } == true }
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
            let owned = held.filter { $0.projectId == section.project.id }
            section.tasks.removeAll { ids.contains($0.id) }
            section.operatorTasks += owned.count; section.operatorWorktrees += owned.filter(\.hasCheckout).count
            return .project(section)
        }
    }
    private static func present(_ original: TaskRow, task: TaskItem, state: AppState) -> TaskRow {
        guard let record = task.signalTask else { return original }
        var row = original
        let busy = [.working, .background].contains(row.status)
        let paused = state.operatorSession?.paused == true || state.signal(id: record.signal)?.enabled == false
        let questions = state.operatorSession?.questions.filter { $0.task == task.id && $0.resolvedAt == nil } ?? []
        if row.status == .needsInput { return row }
        if paused && !busy { row.operatorLine = .paused; row.paused = true; row.status = .idle }
        else if let question = questions.first {
            row.operatorLine = OperatorLine("waiting on you", look: .needsYou, tooltip: question.text); row.status = .needsInput
        } else if let act = record.currentAct {
            row.operatorLine = OperatorLine("Operator " + act, look: .acting); row.status = .working
        } else {
            switch record.phase {
            case .launching: row.operatorLine = OperatorLine("starting its worker", look: .acting); row.status = .working
            case .working:
                if task.windowId == nil && task.firstWorkerConversation != nil { row.operatorLine = .windowClosed; row.status = .idle }
                else if !busy { row.status = .working }
            case .watching(let condition):
                row.operatorLine = OperatorLine(waiting(for: condition)); if !busy { row.status = .idle }
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
    private static func waiting(for condition: DoneWhen) -> String {
        switch condition {
        case .operatorJudges: "waiting for the Operator"
        case .hasReviewer: "waiting on a reviewer"
        case .approved: "waiting on approval"
        case .threadsResolved: "waiting on review threads"
        case .merged: "waiting for the merge"
        case .ticketStatus(let status): "waiting for " + status
        case .myReviewPosted: "waiting for the posted review"
        case .mergedOrClosed: "waiting for the request to close"
        case .unknown: "unsupported done condition"
        }
    }

}

/// Only the Operator row's drawn facts: a tool ledger or journal write changes none of them.
struct SignalOperatorRowValue: Equatable, Identifiable {
    var id: UUID { OperatorRow.id(of: OperatorSession.rowID) }
    var line: OperatorLine
    var status: TaskStatus
    var paused: Bool
    /// Whether the sidebar draws the row: while there is a signal or a task the Operator still
    /// drives, or the Operator is busy or needs you. With no signal configured it has nothing to
    /// watch, and the OPERATOR heading's + is all there is.
    var shown = true
    static let empty = Self(line: OperatorLine("watching 0 tasks in 0 signals"), status: .idle, paused: false, shown: false)
    static func make(state: AppState, sessions: [SessionInfo], issue: String? = nil) -> Self {
        let session = state.operatorSession
        let tasks = state.tasks.filter { $0.signalTask.map { !$0.takenOver && $0.phase != .stopped } == true }.count
        let signals = Set(state.signals.map(\.id) + state.tasks.compactMap { $0.signalTask.flatMap { !$0.takenOver && $0.phase != .stopped ? $0.signal : nil } }).count
        let line: OperatorLine
        if session?.paused == true { line = .paused }
        else if let session, sessions.contains(where: { $0.taskUUID == session.id && $0.agent == .claude && $0.state == .needsInput }) {
            line = OperatorLine("needs you", look: .needsYou)
        }
        else if let issue { line = OperatorLine("needs you", look: .needsYou, tooltip: issue) }
        else if session?.startingFresh == true {
            let count = state.allSignalTasks.filter { $0.signalTask?.takenOver == false }.count
            line = OperatorLine("starting fresh · \(count) \(count == 1 ? "task" : "tasks") carried over", look: .acting)
        }
        else if let count = session?.waitingOnYou, count > 0 { line = OperatorLine("waiting on you · \(count)", look: .needsYou) }
        else if let task = state.tasks.first(where: { $0.signalTask?.currentAct != nil && $0.signalTask?.takenOver == false }),
                let act = task.signalTask?.currentAct {
            let name = task.jira?.key ?? task.mr.map { "request \($0.iid)" } ?? task.title
            let text = act.contains("its worker") ? act.replacingOccurrences(of: "its worker", with: name + "’s worker") : act + " · " + name
            line = OperatorLine(text, look: .acting)
        }
        else if let session, sessions.contains(where: { $0.taskUUID == session.id && $0.agent == .claude && $0.state == .working }) { line = .working }
        else { line = OperatorLine("watching \(tasks) \(tasks == 1 ? "task" : "tasks") in \(signals) \(signals == 1 ? "signal" : "signals")") }
        let status: TaskStatus = line.look == .needsYou ? .needsInput : line.look == .acting ? .working : .idle
        return Self(line: line, status: status, paused: session?.paused == true, shown: tasks > 0 || signals > 0 || status != .idle)
    }
}
