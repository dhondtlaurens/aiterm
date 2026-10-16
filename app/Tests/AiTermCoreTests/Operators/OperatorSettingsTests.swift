import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// Settings › Agents' "Agents at once", as UserDefaults keeps it.
@Suite struct OperatorSettingsTests {
    @Test func twoUntilSomethingIsSaved() {
        let defaults = ScratchDefaults.make()
        #expect(OperatorSettings.agentsAtOnce(defaults: defaults) == 2)
        #expect(OperatorSettings.defaultAgentsAtOnce == 2)
        #expect(OperatorSettings.agentsAtOnceRange == 1...5)
    }

    @Test func aSavedCountIsReadBack() {
        let defaults = ScratchDefaults.make()
        OperatorSettings.saveAgentsAtOnce(4, defaults: defaults)
        #expect(OperatorSettings.agentsAtOnce(defaults: defaults) == 4)
        OperatorSettings.saveAgentsAtOnce(1, defaults: defaults)
        #expect(OperatorSettings.agentsAtOnce(defaults: defaults) == 1)
    }

    /// A count outside 1–5 — saved by hand with `defaults write`, or by a later build with a wider
    /// range — reads as the nearest end; anything that is not a number reads as the default.
    @Test func aCountOutsideTheRangeReadsAsItsNearestEnd() {
        let defaults = ScratchDefaults.make()
        defaults.set(0, forKey: "operators.agentsAtOnce")
        #expect(OperatorSettings.agentsAtOnce(defaults: defaults) == 1)
        defaults.set(9, forKey: "operators.agentsAtOnce")
        #expect(OperatorSettings.agentsAtOnce(defaults: defaults) == 5)
        defaults.set("three", forKey: "operators.agentsAtOnce")
        #expect(OperatorSettings.agentsAtOnce(defaults: defaults) == 2)
        OperatorSettings.saveAgentsAtOnce(12, defaults: defaults)
        #expect(defaults.integer(forKey: "operators.agentsAtOnce") == 5, "saved clamped")
    }
}
