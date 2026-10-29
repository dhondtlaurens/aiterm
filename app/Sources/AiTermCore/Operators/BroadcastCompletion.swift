import Foundation

/// The broadcast's completion policy. Adapters collect evidence and wake the Operator; these rules
/// decide whether to check the goal, plan another round, or finish.
public enum BroadcastCompletion {
    public static func goalCheckIsDue(_ run: OperatorRun, in state: AppState) -> Bool {
        guard run.goal != nil, run.goalOutcome == nil,
              run.revisionAtLastCheck.map({ run.planRevision > $0 }) ?? true else { return false }
        return RunScheduler.isComplete(run, in: state)
    }

    /// A failed check can be checked again without consuming another round while no new plan was submitted.
    public static func goalToCheck(_ run: OperatorRun) -> BroadcastGoal? {
        guard let goal = run.goal else { return nil }
        let recheck = run.goalOutcome == nil && run.goalChecks.last?.met == false && run.revisionAtLastCheck == run.planRevision
        return run.goalCheckDue || recheck ? goal : nil
    }

    public static func record(_ check: GoalCheck, in run: inout OperatorRun) {
        let planMore = !check.met && run.goalCheckDue && run.roundsUsed < (run.goal?.extraRounds ?? 0)
        run.goalChecks.append(check)
        run.goalCheckDue = false
        run.revisionAtLastCheck = run.planRevision
        if planMore {
            run.roundsUsed += 1
        } else {
            run.goalOutcome = check.oracleAgreed == nil ? .unchecked : check.met ? .met : .notMet
            for line in check.missing where !run.leftForYou.contains(line) { run.leftForYou.append(line) }
        }
    }

    public static func isComplete(_ run: OperatorRun, in state: AppState) -> Bool {
        RunScheduler.isComplete(run, in: state) && (run.goal == nil || run.goalOutcome != nil)
    }
}
