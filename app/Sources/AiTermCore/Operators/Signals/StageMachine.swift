import Foundation

public enum SignalTransitions {
    public static func apply(_ action: SignalAction, to task: SignalTask, at: Date, workerIsWorking: Bool = false) throws -> SignalTask {
        var next = task
        if case .unknown = task.phase { throw SignalTransitionError.invalidEdge }
        func continueStage(_ stage: SignalStage) {
            next.previousStage = EarlierStage(of: next)
            next.earlier = (next.earlier ?? []) + [SignalStep(signal: next.current.signal, name: next.current.configuration.name,
                                                              at: next.startedAt)]
            next.current = stage; next.stage += 1; next.ownership += 1; next.startedAt = at; next.thenApplied = nil
            next.phase = .launching; next.launch = nil; next.blockedReason = nil
            next.choice = nil; next.choosableRows = nil; next.waitingOn = nil; next.doneMatched = nil; next.merge = nil
        }
        func startPending() {
            guard !next.pendingStages.isEmpty else { return }
            continueStage(next.pendingStages.removeFirst())
        }
        switch action {
        case .workerStarted:
            guard task.phase == .launching else { throw SignalTransitionError.invalidEdge }
            next.phase = .working; next.previousStage = nil
        case .workRequested:
            guard task.phase == .working || task.phase == .done || task.phase == .watching else {
                throw SignalTransitionError.invalidEdge
            }
            next.phase = .working; next.thenApplied = nil; next.blockedReason = nil
        case .matched(let stage):
            if task.phase.canContinue && !workerIsWorking {
                if next.pendingStages.isEmpty { continueStage(stage) }
                else {
                    if !next.pendingStages.contains(where: { $0.signal == stage.signal }) { next.pendingStages.append(stage) }
                    startPending()
                }
            } else if !next.pendingStages.contains(where: { $0.signal == stage.signal }) { next.pendingStages.append(stage) }
        case .watch:
            guard task.phase == .working, !workerIsWorking else { throw SignalTransitionError.workerIsWorking }
            next.phase = .watching; startPending()
        case .finish:
            guard task.phase == .working || task.phase.canContinue else { throw SignalTransitionError.invalidEdge }
            guard !workerIsWorking else { throw SignalTransitionError.workerIsWorking }
            next.phase = .done; startPending()
        case .advancePending:
            guard !workerIsWorking else { throw SignalTransitionError.workerIsWorking }
            guard task.phase.canContinue else { throw SignalTransitionError.invalidEdge }
            startPending()
        case .dropped:
            // Only a stage that came after another and never launched: the task goes back to the stage before it as it
            // was left, still watching its Done trigger or done, and the next pending stage follows.
            guard task.phase == .launching || task.phase == .choosing, task.launch == nil, let previous = task.previousStage else {
                throw SignalTransitionError.invalidEdge
            }
            next.current = previous.stage; next.previousStage = nil; next.blockedReason = nil
            // The task is that stage's again: its step leaves the chain, and it started when the step says.
            if let step = next.earlier?.popLast() { next.startedAt = step.at }
            if next.earlier?.isEmpty == true { next.earlier = nil }
            next.phase = previous.phase == .watching ? .watching : .done
            next.doneMatched = previous.doneMatched; next.waitingOn = previous.waitingOn; next.merge = previous.merge
            next.launch = previous.launch; next.choice = previous.choice
            next.choosableRows = nil; next.candidateProjects = nil
            startPending()
        case .block(let reason):
            guard task.phase.isActive else { throw SignalTransitionError.invalidEdge }
            next.phase = .blocked; next.blockedReason = reason
        case .launchFailed(let reason):
            guard task.phase == .launching else { throw SignalTransitionError.invalidEdge }
            next.phase = .blocked; next.blockedReason = reason
        case .adopted:
            let lostReply = task.phase == .blocked && task.launch?.workerPending == true && task.launch?.openedAt == nil
            guard task.phase == .launching || lostReply else { throw SignalTransitionError.invalidEdge }
            next.phase = .working; next.blockedReason = nil; next.previousStage = nil
            next.launch?.openedAt = at; next.launch?.workerPending = false
        case .needChoice:
            guard task.phase == .launching else { throw SignalTransitionError.invalidEdge }
            next.phase = .choosing
        case .chosen:
            guard task.phase == .choosing else { throw SignalTransitionError.invalidEdge }
            next.phase = .launching; next.ownership += 1; next.choosableRows = nil; next.candidateProjects = nil
        case .resume:
            guard task.phase == .blocked else { throw SignalTransitionError.invalidEdge }
            next.phase = .launching; next.ownership += 1; next.blockedReason = nil; next.pendingReplies = nil
        case .archive:
            guard task.canRunThen else { throw SignalTransitionError.invalidEdge }
            next.phase = .archived
        }
        return next
    }
}

public enum SignalAction: Equatable, Sendable {
    case workerStarted, workRequested, matched(SignalStage), watch, finish, advancePending
    /// A launching or choosing stage whose signal no longer matches its item, dropped before its worker launched.
    case dropped
    case block(String), resume, archive
    /// A launching stage whose worker could not start blocks with the reason.
    case launchFailed(String)
    /// A worker found running after its launch reply was lost: the stage works on in it.
    case adopted
    /// A launching stage waits for the Operator's agent-row or project choice; `chosen` launches it.
    case needChoice, chosen
}

/// A stage change refused, in the words the Operator reads.
public enum SignalTransitionError: Error, Equatable, LocalizedError {
    case invalidEdge, workerIsWorking

    public var errorDescription: String? {
        switch self {
        case .invalidEdge: "The task’s stage can’t make that change from where it is now."
        case .workerIsWorking: "The task is busy: its worker is at work or another step holds it. Try again once that ends."
        }
    }
}
