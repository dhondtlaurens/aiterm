import Testing
import Foundation
@testable import AiTermCore

@Suite struct BacklogBudgetTests {
    /// Additions after the first plan go free up to max(1, ceil(first / 4)); past that the Oracle decides.
    @Test(arguments: [
        (4, 0, true, BacklogBudget.Verdict.free),
        (4, 1, true, BacklogBudget.Verdict.needsOracle),
        (8, 1, false, BacklogBudget.Verdict.free),
        (8, 2, false, BacklogBudget.Verdict.refused),
        (1, 0, false, BacklogBudget.Verdict.free),
    ])
    func theThresholdFollowsTheFirstPlan(_ first: Int, _ additions: Int, _ oracleIsOn: Bool, _ verdict: BacklogBudget.Verdict) {
        #expect(BacklogBudget.verdict(firstPlanSize: first, additionsSoFar: additions, oracleIsOn: oracleIsOn) == verdict)
    }
}
