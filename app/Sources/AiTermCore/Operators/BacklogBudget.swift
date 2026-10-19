import Foundation

/// How many tasks the Operator may add after its first plan (spec §4.1). The first plan is the
/// brief; each later addition past a quarter of it is an invention, so the Oracle checks it.
public enum BacklogBudget {
    public enum Verdict: Equatable, Sendable { case free, needsOracle, refused }

    /// Additions after the first plan: up to max(1, ceil(first / 4)) go free; past that the Oracle
    /// decides, and with it off they are refused.
    public static func verdict(firstPlanSize: Int, additionsSoFar: Int, oracleIsOn: Bool) -> Verdict {
        let quarter = (max(firstPlanSize, 0) + 3) / 4
        if additionsSoFar < max(1, quarter) { return .free }
        return oracleIsOn ? .needsOracle : .refused
    }
}
