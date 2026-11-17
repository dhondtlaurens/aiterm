import Foundation

public extension TaskRow {
    func presentingOperator(task: TaskItem, state: AppState, act: String?) -> TaskRow {
        guard let record = task.signalTask else { return self }
        var row = self
        let busy = [.working, .background].contains(row.status)
        let paused = state.operatorSession?.paused == true || state.signal(id: record.current.signal)?.enabled == false
        let questions = state.currentOperatorQuestions.filter { $0.task == task.id }
        if row.status == .needsInput { return row }
        if paused && !busy { row.operatorLine = .paused; row.paused = true; row.status = .idle }
        else if let question = questions.first {
            row.operatorLine = OperatorLine("waiting on you", look: .needsYou, tooltip: question.text); row.status = .needsInput
        } else if let act {
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
                // so no done ring, and nothing runs, so no spinner either.
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
            case .unknown: break
            }
        }
        return row
    }
}
