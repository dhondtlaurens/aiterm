// app/Tests/AiTermCoreTests/BackpackSettingsTests.swift
import Testing
import Foundation
@testable import AiTermCore

@Suite struct BackpackSettingsTests {
    @Test func defaultsToNoNetworkTenPercentAndNotEngaged() {
        let settings = BackpackSettings(defaults: ScratchDefaults.make())
        #expect(settings.network == nil)
        #expect(settings.cutoff == 10)
        #expect(!settings.engaged)
    }

    @Test func roundTripsThroughTheSameDefaults() {
        let defaults = ScratchDefaults.make()
        let settings = BackpackSettings(defaults: defaults)
        settings.network = "Laurens D’Hondt - iPhone"
        settings.cutoff = 20
        settings.engaged = true
        let again = BackpackSettings(defaults: defaults)
        #expect(again.network == "Laurens D’Hondt - iPhone")
        #expect(again.cutoff == 20)
        #expect(again.engaged)
    }

    /// A hand-edited or older value outside the menu reads as the default, and an empty name as none.
    @Test func anUnknownCutoffOrEmptyNetworkReadsAsTheDefault() {
        let defaults = ScratchDefaults.make()
        defaults.set(7, forKey: "backpack.batteryCutoff")
        defaults.set("", forKey: "backpack.network")
        let settings = BackpackSettings(defaults: defaults)
        #expect(settings.cutoff == 10)
        #expect(settings.network == nil)
    }

    /// Without defaults the values live in memory: what Settings previews and tests get.
    @Test func withoutDefaultsTheValuesStayInMemory() {
        let settings = BackpackSettings(defaults: nil)
        settings.network = "Phone"
        settings.cutoff = 5
        #expect(settings.network == "Phone")
        #expect(settings.cutoff == 5)
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

    @Test func theCutoffChoicesAreTheSpecs() {
        #expect(BackpackSettings.cutoffChoices == [5, 10, 15, 20, 25, 30])
    }
}
