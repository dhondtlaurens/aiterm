import Foundation

public enum SignalTransitions {
    public static func apply(_ action: SignalAction, to task: SignalTask, at: Date, workerIsWorking: Bool = false) throws -> SignalTask {
        var next = task
        guard !task.takenOver || action == .takeOver else { throw SignalTransitionError.takenOver }
        if case .unknown = task.phase { throw SignalTransitionError.invalidEdge }
        func continueStage(_ stage: SignalStage) {
            next.signal = stage.signal; next.item = stage.item; next.stage += 1; next.ownership += 1; next.startedAt = at
            next.configuration = stage.configuration; next.prompt = stage.prompt; next.thenApplied = nil
            next.phase = .launching; next.launch = nil; next.currentAct = nil; next.blockedReason = nil; next.operatorJudged = nil
        }
        func startPending() {
            guard !next.pendingStages.isEmpty else { return }
            continueStage(next.pendingStages.removeFirst())
        }
        switch action {
        case .workerStarted:
            guard task.phase == .launching else { throw SignalTransitionError.invalidEdge }
            next.phase = .working
        case .workRequested:
            guard task.phase == .working || task.phase == .done || { if case .watching = task.phase { true } else { false } }() else {
                throw SignalTransitionError.invalidEdge
            }
            next.phase = .working; next.operatorJudged = nil; next.thenApplied = nil; next.blockedReason = nil
        case .matched(let stage):
            if task.phase.canContinue && !workerIsWorking { continueStage(stage) }
            else if !next.pendingStages.contains(where: { $0.signal == stage.signal }) { next.pendingStages.append(stage) }
        case .watch(let condition):
            guard task.phase == .working, !workerIsWorking else { throw SignalTransitionError.workerIsWorking }
            next.phase = .watching(condition); startPending()
        case .finish:
            guard task.phase == .working || task.phase.canContinue else { throw SignalTransitionError.invalidEdge }
            guard !workerIsWorking else { throw SignalTransitionError.workerIsWorking }
            next.phase = .done; startPending()
        case .advancePending:
            guard !workerIsWorking else { throw SignalTransitionError.workerIsWorking }
            guard task.phase.canContinue else { throw SignalTransitionError.invalidEdge }
            startPending()
        case .block(let reason):
            guard task.phase.isActive else { throw SignalTransitionError.invalidEdge }
            next.phase = .blocked; next.blockedReason = reason
        case .resume:
            guard task.phase == .blocked else { throw SignalTransitionError.invalidEdge }
            next.phase = .launching; next.ownership += 1; next.blockedReason = nil; next.currentAct = nil; next.pendingReplies = nil
        case .archive:
            guard task.canRunThen else { throw SignalTransitionError.invalidEdge }
            next.phase = .archived
        case .stop: next.phase = .stopped; next.currentAct = nil
        case .takeOver: next.takenOver = true; next.ownership += 1; next.currentAct = nil
        }
        if next.phase != task.phase || next.stage != task.stage {
            next.edges.append(SignalEdge(from: task.phase, to: next.phase, stage: next.stage, at: at))
        }
        next.edges = Array(next.edges.suffix(SignalTask.edgeLimit))
        return next
    }
}
