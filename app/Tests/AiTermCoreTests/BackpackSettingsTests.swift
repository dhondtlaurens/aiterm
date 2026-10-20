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

    /// Notifies is remembered from trip to trip, unlike Turns off: it starts on Needs input.
    @Test func pushesDefaultToNeedsInputAndRoundTrip() {
        let defaults = ScratchDefaults.make()
        let settings = BackpackSettings(defaults: defaults)
        #expect(settings.pushes == .needsInput)
        settings.pushes = .never
        #expect(BackpackSettings(defaults: defaults).pushes == .never)
        #expect(defaults.string(forKey: "backpack.pushes") == "never")
    }

    /// A value only another build knows reads as the default rather than as Never.
    @Test func anUnknownPushesValueReadsAsTheDefault() {
        let defaults = ScratchDefaults.make()
        defaults.set("sometimes", forKey: "backpack.pushes")
        #expect(BackpackSettings(defaults: defaults).pushes == .needsInput)
    }

    @Test func theCutoffIsNoLongerAPreference() {
        #expect(BackpackSettings.cutoff == 10)
    }
}
