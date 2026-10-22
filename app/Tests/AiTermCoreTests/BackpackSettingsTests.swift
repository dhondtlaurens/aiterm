import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct BackpackSettingsTests {
    @Test func defaultsToNoNetworkAndNotEngaged() {
        let settings = BackpackSettings(defaults: ScratchDefaults.make())
        #expect(settings.network == nil)
        #expect(!settings.engaged)
    }

    @Test func roundTripsThroughTheSameDefaults() {
        let defaults = ScratchDefaults.make()
        let settings = BackpackSettings(defaults: defaults)
        settings.network = "Laurens D’Hondt - iPhone"
        settings.engaged = true
        let again = BackpackSettings(defaults: defaults)
        #expect(again.network == "Laurens D’Hondt - iPhone")
        #expect(again.engaged)
    }

    /// An empty name reads as none.
    @Test func anEmptyNetworkReadsAsNone() {
        let defaults = ScratchDefaults.make()
        defaults.set("", forKey: "backpack.network")
        let settings = BackpackSettings(defaults: defaults)
        #expect(settings.network == nil)
    }

    /// Without defaults the values live in memory: what Settings previews and tests get.
    @Test func withoutDefaultsTheValuesStayInMemory() {
        let settings = BackpackSettings(defaults: nil)
        settings.network = "Phone"
        #expect(settings.network == "Phone")
    }

    /// The password lives in the secret store, never in defaults; an empty one clears it.
    @Test func thePasswordRoundTripsThroughTheSecretStoreOnly() {
        let defaults = ScratchDefaults.make(), secrets = MemorySecretStore()
        let settings = BackpackSettings(defaults: defaults, secrets: secrets)
        #expect(settings.password == nil)
        settings.password = "hunter2"
        #expect(BackpackSettings(defaults: defaults, secrets: secrets).password == "hunter2")
        #expect(secrets.get("backpack.password") == "hunter2")
        #expect(defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.allSatisfy { $0 != "hunter2" })
        settings.password = ""
        #expect(settings.password == nil)
        #expect(secrets.get("backpack.password") == nil)
    }

    /// A build that pushed to the iPhone saved Notifies' choice beside the hotspot: the rest reads as
    /// before, and the next save leaves the choice out.
    @Test func anOldNotifiesChoiceIsReadPastAndDroppedOnTheNextSave() {
        let defaults = ScratchDefaults.make()
        defaults.set("Phone", forKey: "backpack.network")
        defaults.set("needsInputOrDone", forKey: "backpack.pushes")
        defaults.set(true, forKey: "backpack.engaged")
        let settings = BackpackSettings(defaults: defaults)
        #expect(settings.network == "Phone")
        #expect(settings.engaged)
        settings.network = "Other phone"
        #expect(defaults.object(forKey: "backpack.pushes") == nil)
        #expect(defaults.dictionaryRepresentation()["backpack.pushes"] == nil)
        let again = BackpackSettings(defaults: defaults)
        #expect(again.network == "Other phone")
        #expect(again.engaged)
    }
}
