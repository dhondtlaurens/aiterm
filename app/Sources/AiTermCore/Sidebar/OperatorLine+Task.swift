import Foundation

public extension TaskRow {
    /// A driven task's row: the Operator's line and the status, mark and "needs you" that go with it. A paused row
    /// draws the pause sign and is idle; the row needs you only while it needs input (a question, blocked, or its
    /// worker asking), never for a turn its worker ended, which is the Operator's to read.
    func presentingOperator(task: TaskItem, state: AppState, act: String?) -> TaskRow {
        guard task.isUnderOperator else { return self }
        var row = self, paused = false
        row.presentLine(task: task, state: state, act: act, paused: &paused)
        row.mark = TaskRowMark(status: row.status, line: row.operatorLine, paused: paused)
        row.needsYou = row.status == .needsInput
        return row
    }

    private mutating func presentLine(task: TaskItem, state: AppState, act: String?, paused pauseSign: inout Bool) {
        guard let record = task.signalTask else { return }
        let busy = [.working, .background].contains(status)
        let paused = state.operatorSession?.paused == true || state.signal(id: record.current.signal)?.enabled == false
        let questions = state.currentOperatorQuestions.filter { $0.task == task.id }
        if status == .needsInput { return }
        if paused && !busy { operatorLine = .paused; pauseSign = true; status = .idle }
        else if let question = questions.first {
            operatorLine = OperatorLine("waiting on you", look: .needsYou, tooltip: question.text); status = .needsInput
        } else if let act {
            operatorLine = OperatorLine("Operator " + act, look: .acting); status = .working
        } else {
            switch record.phase {
            case .launching: operatorLine = OperatorLine("starting its worker", look: .acting); status = .working
            case .choosing:
                // The Operator's turn, never the person's: the acting look, counted as work.
                let projectOnly = (record.choosableRows?.count ?? 0) == 1 && (record.candidateProjects?.count ?? 0) > 1
                operatorLine = OperatorLine("Operator choosing " + (projectOnly ? "its project" : "its agent"), look: .acting)
                status = .working
            case .working:
                if task.windowId == nil && task.firstWorkerConversation != nil { operatorLine = .windowClosed; status = .idle }
                // Every worker ended its turn and the Operator does nothing yet: the turn is the Operator's to read,
                // so no done ring, and nothing runs, so no spinner either.
                else if !busy { operatorLine = .workerDone; status = .waiting }
            case .watching(let condition):
                operatorLine = .waiting(for: condition, facts: record.waitingOn, request: task.mr?.reference, ticket: task.jira?.key)
                if !busy {
                    if case .unknown = condition { status = .idle } else { status = .waiting }
                }
            case .blocked:
                operatorLine = OperatorLine("blocked", look: .needsYou, tooltip: record.blockedReason ?? "Open its window to inspect it.")
                status = .needsInput
            case .done, .archived:
                operatorLine = OperatorLine("done", look: .ended); if !busy { status = .idle }
            case .unknown: break
            }
        }
    }
}
