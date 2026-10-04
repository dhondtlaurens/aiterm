import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
@Suite(.serialized) struct BackpackSettingsPaneTests {
    private let ready = BackpackSetup(sleepRule: true, location: true, network: "Phone")

    @Test func thePermissionsCardSaysWhatIsMissing() {
        #expect(BackpackPresentation.permissions(setup: BackpackSetup(sleepRule: false, location: false, network: nil))
                == SettingsStatus(.attention, "Not set up"))
        #expect(BackpackPresentation.permissions(setup: BackpackSetup(sleepRule: false, location: true, network: nil))
                == SettingsStatus(.attention, "Needs lid-sleep access"))
        #expect(BackpackPresentation.permissions(setup: BackpackSetup(sleepRule: true, location: false, network: nil))
                == SettingsStatus(.attention, "Needs Location access"))
        #expect(BackpackPresentation.permissions(setup: ready) == SettingsStatus(.ready, "Ready"))
    }

    @Test func theHotspotCardCarriesTheModesLiveStatus() {
        #expect(BackpackPresentation.hotspot(state: .off, setup: BackpackSetup(sleepRule: true, location: true, network: nil))
                == SettingsStatus(.idle, "Choose a network"))
        #expect(BackpackPresentation.hotspot(state: .off, setup: ready) == SettingsStatus(.idle, "Ready · ⌘B turns Backpack Mode on"))
        let joined = BackpackStatus(network: "Phone", joined: true, power: .mains, cutoff: 10)
        #expect(BackpackPresentation.hotspot(state: .on(joined), setup: ready) == SettingsStatus(.ready, "On · joined Phone"))
        let away = BackpackStatus(network: "Phone", joined: false, power: .mains, cutoff: 10)
        #expect(BackpackPresentation.hotspot(state: .on(away), setup: ready)
                == SettingsStatus(.attention, "On · not joined to Phone, rejoining"))
    }

    @Test func theBatteryCardSaysTheLevelAndTheSource() {
        #expect(BackpackPresentation.battery(power: PowerReading(level: 64, onBattery: true), state: .off, cutoff: 10)
                == SettingsStatus(.idle, "64 % · on battery"))
        #expect(BackpackPresentation.battery(power: PowerReading(level: 64, onBattery: false), state: .off, cutoff: 10)
                == SettingsStatus(.idle, "64 % · on the charger"))
        #expect(BackpackPresentation.battery(power: .mains, state: .off, cutoff: 10) == SettingsStatus(.idle, "No battery"))
        let low = BackpackStatus(network: "Phone", joined: true, power: PowerReading(level: 13, onBattery: true), cutoff: 10)
        #expect(BackpackPresentation.battery(power: low.power, state: .on(low), cutoff: 10)
                == SettingsStatus(.attention, "13 % · turns off at 10 %"))
    }

    @Test func theStepsAreTheMissingOnesInOrder() {
        #expect(BackpackPresentation.steps(setup: BackpackSetup(sleepRule: false, location: false, network: nil)) == [
            "Allow AiTerm to keep the Mac awake with the lid closed. Asks for your Mac’s password once.",
            "Allow AiTerm to see nearby Wi-Fi networks. macOS hides their names from apps without Location access; AiTerm never reads where you are.",
        ])
        #expect(BackpackPresentation.steps(setup: ready).isEmpty)
    }

    @Test func theSummaryIsTheGlyphsTooltip() {
        #expect(BackpackPresentation.summary(BackpackStatus(network: "Phone", joined: true, power: PowerReading(level: 64, onBattery: true), cutoff: 10))
                == "Backpack Mode is on · Phone · battery 64 %, turns off at 10 %")
        #expect(BackpackPresentation.summary(BackpackStatus(network: "Phone", joined: true, power: .mains, cutoff: 10))
                == "Backpack Mode is on · Phone")
        #expect(BackpackPresentation.summary(BackpackStatus(network: "Phone", joined: false, power: .mains, cutoff: 10))
                == "Backpack Mode is on · not joined to Phone")
    }

    /// A chosen network the Mac no longer lists stays pickable, and "none" leads the menu.
    @Test func theNetworkChoicesKeepTheCurrentOne() {
        #expect(BackpackPresentation.choices(known: ["Home", "Phone"], current: nil) == [nil, "Home", "Phone"])
        #expect(BackpackPresentation.choices(known: ["Home"], current: "Phone") == [nil, "Phone", "Home"])
    }

    @Test func backpackIsTheFourthTabOnCommandFour() {
        #expect(SettingsTab.allCases == [.agents, .integrations, .interface, .backpack])
        #expect(SettingsTab.backpack.key == "4")
    }

    /// Settings opens on the saved network and cutoff; the password field opens empty, so opening
    /// Settings reads nothing from the Keychain on the main actor.
    @Test func settingsOpensOnTheSavedFieldsButNotThePassword() {
        let backpack = BackpackController.inert()
        backpack.network = "Phone"
        backpack.cutoff = 20
        backpack.password = "hunter2"
        let settings = SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: HarnessSettingsModel.preview(),
                                    itermConnection: { .connected(version: "3.7.2") },
                                    checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                                    preferences: .scratch(), setMatchItermBackground: { _ in }, setInterfaceSize: { _ in },
                                    initialTab: .backpack, backpack: backpack)
        #expect(settings._backpackNetwork.wrappedValue == "Phone")
        #expect(settings._backpackCutoff.wrappedValue == 20)
        #expect(settings._backpackPassword.wrappedValue == "")
    }

    /// An empty field keeps the saved password: Save on any tab must not delete it.
    @Test func anEmptyPasswordFieldKeepsTheSavedOne() {
        let backpack = BackpackController.inert()
        backpack.password = "hunter2"
        #expect(SettingsView.storeBackpack(network: "Phone", cutoff: 15, password: "", in: backpack) == nil)
        #expect(backpack.password == "hunter2")
        #expect(backpack.network == "Phone" && backpack.cutoff == 15)
        #expect(SettingsView.storeBackpack(network: "Phone", cutoff: 15, password: "new", in: backpack) == nil)
        #expect(backpack.password == "new")
    }

    @Test func aPasswordTheKeychainRefusesIsReported() {
        let backpack = BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil, secrets: RefusingSecretStore()),
                                          toast: { _ in })
        #expect(SettingsView.storeBackpack(network: "Phone", cutoff: 10, password: "new", in: backpack)
                == "Couldn’t save the hotspot password in Keychain.")
    }
}

/// A Keychain that refuses every write.
private final class RefusingSecretStore: SecretStore {
    func get(_ key: String) -> String? { nil }
    func set(_ key: String, _ value: String?) -> Bool { false }
}
