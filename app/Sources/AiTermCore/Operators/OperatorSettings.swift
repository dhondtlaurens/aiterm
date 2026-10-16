import Foundation

/// Settings › Agents' "Agents at once": how many workers every operation together may have at work
/// at the same time. AiTerm's limit, not the operator's (spec §4.0): an operator decides how to split
/// the work into tasks, AiTerm decides how much of it runs at once. Read at every scheduling pass, so
/// a change takes effect at the next start.
public enum OperatorSettings {
    public static let agentsAtOnceRange = 1...5
    public static let defaultAgentsAtOnce = 2
    private static let agentsAtOnceKey = "operators.agentsAtOnce"

    /// The saved count, brought into `agentsAtOnceRange`; the default when none is saved or what is
    /// saved is not a number.
    public static func agentsAtOnce(defaults: UserDefaults = .standard) -> Int {
        guard let saved = defaults.object(forKey: agentsAtOnceKey) as? Int else { return defaultAgentsAtOnce }
        return clamped(saved)
    }

    public static func saveAgentsAtOnce(_ value: Int, defaults: UserDefaults = .standard) {
        defaults.set(clamped(value), forKey: agentsAtOnceKey)
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, agentsAtOnceRange.lowerBound), agentsAtOnceRange.upperBound)
    }
}
