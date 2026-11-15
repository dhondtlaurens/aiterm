import Foundation
import AiTermCore

struct SignalSection: Equatable, Identifiable {
    var signal: Signal
    var tasks: [TaskRow]
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
            SignalSection(signal: signal, tasks: held.filter { $0.signalTask?.signal == signal.id }.compactMap { rows[$0.id] })
        }
        projects = entries.map { entry in
            guard case .project(var section) = entry else { return entry }
            let owned = held.filter { $0.projectId == section.project.id }
            section.tasks.removeAll { ids.contains($0.id) }
            section.operatorTasks += owned.count; section.operatorWorktrees += owned.filter(\.hasCheckout).count
            return .project(section)
        }
    }
}

/// Only the permanent row's drawn facts: a tool ledger or journal write changes none of them.
struct SignalOperatorRowValue: Equatable, Identifiable {
    var id: UUID { OperatorRow.id(of: OperatorSession.rowID) }
    var line: OperatorLine
    var status: TaskStatus
    var paused: Bool
    static let empty = Self(line: OperatorLine("watching 0 tasks in 0 signals"), status: .idle, paused: false)
    static func make(state: AppState, sessions: [SessionInfo]) -> Self {
        let session = state.operatorSession
        let line: OperatorLine
        if session?.paused == true { line = .paused }
        else if session?.startingFresh == true { line = OperatorLine("starting fresh", look: .acting) }
        else if let count = session?.waitingOnYou, count > 0 { line = OperatorLine("waiting on you · \(count)", look: .needsYou) }
        else if sessions.contains(where: { $0.taskUUID == session?.id && $0.agent == .claude && $0.state == .working }) { line = .working }
        else {
            let tasks = state.tasks.filter { $0.signalTask.map { !$0.takenOver && $0.phase != .stopped } == true }.count
            line = OperatorLine("watching \(tasks) \(tasks == 1 ? "task" : "tasks") in \(state.signals.count) \(state.signals.count == 1 ? "signal" : "signals")")
        }
        return Self(line: line, status: line.look == .needsYou ? .needsInput : line.look == .acting ? .working : .idle,
                    paused: session?.paused == true)
    }
}
