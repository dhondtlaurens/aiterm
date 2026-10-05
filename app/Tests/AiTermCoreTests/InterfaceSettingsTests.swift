import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct InterfaceSettingsTests {
    @Test func matchItermBackgroundDefaultsOffAndRoundTrips() {
        let defaults = ScratchDefaults.make()
        #expect(!InterfaceSettings.matchItermBackground(defaults: defaults))
        InterfaceSettings.saveMatchItermBackground(true, defaults: defaults)
        #expect(InterfaceSettings.matchItermBackground(defaults: defaults))
        InterfaceSettings.saveMatchItermBackground(false, defaults: defaults)
        #expect(!InterfaceSettings.matchItermBackground(defaults: defaults))
    }

    @Test func everyBadgeDetailDefaultsOnAndRoundTripsOnItsOwn() {
        let defaults = ScratchDefaults.make()
        #expect(InterfaceSettings.badgeDetails(defaults: defaults) == BadgeDetails())
        #expect(BadgeDetails() == BadgeDetails(jiraProject: true, jiraTicket: true, mergeRequest: true, diff: true))

        let trimmed = BadgeDetails(jiraProject: false, jiraTicket: true, mergeRequest: false, diff: true)
        InterfaceSettings.saveBadgeDetails(trimmed, defaults: defaults)
        #expect(InterfaceSettings.badgeDetails(defaults: defaults) == trimmed)

        let flipped = BadgeDetails(jiraProject: true, jiraTicket: false, mergeRequest: true, diff: false)
        InterfaceSettings.saveBadgeDetails(flipped, defaults: defaults)
        #expect(InterfaceSettings.badgeDetails(defaults: defaults) == flipped)
    }

    @Test func interfaceSizeDefaultsToStandardAndRoundTrips() {
        let defaults = ScratchDefaults.make()
        #expect(InterfaceSettings.interfaceSize(defaults: defaults) == .standard)
        for size in InterfaceSize.allCases {
            InterfaceSettings.saveInterfaceSize(size, defaults: defaults)
            #expect(InterfaceSettings.interfaceSize(defaults: defaults) == size)
        }
    }

    /// A value from a later version, or a hand-edited plist, reads as Default rather than failing.
    @Test func anUnknownInterfaceSizeReadsAsStandard() {
        let defaults = ScratchDefaults.make()
        defaults.set("gigantic", forKey: "interfaceSize")
        #expect(InterfaceSettings.interfaceSize(defaults: defaults) == .standard)
    }

    @Test func interfaceSizesStepInOrderAndStopAtTheEnds() {
        #expect(InterfaceSize.allCases == [.standard, .large, .extraLarge])
        #expect(InterfaceSize.standard.bigger == .large)
        #expect(InterfaceSize.large.bigger == .extraLarge)
        #expect(InterfaceSize.extraLarge.bigger == nil)
        #expect(InterfaceSize.extraLarge.smaller == .large)
        #expect(InterfaceSize.standard.smaller == nil)
        #expect(InterfaceSize.allCases.map(\.title) == ["Actual Size", "Large", "Extra Large"])
    }
}
