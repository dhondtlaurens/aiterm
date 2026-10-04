import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
@Suite(.serialized) struct BackpackSettingsPaneTests {
    private let ready = BackpackSetup(sleepRule: true, location: true, network: "Phone")

    @Test func theStatusLineFollowsSetupAndState() {
        #expect(BackpackPresentation.status(state: .off, setup: BackpackSetup(sleepRule: false, location: true, network: "Phone"))
                == SettingsStatus(.attention, "Needs setup"))
        #expect(BackpackPresentation.status(state: .off, setup: BackpackSetup(sleepRule: true, location: true, network: nil))
                == SettingsStatus(.idle, "Off · choose a Wi-Fi network below"))
        #expect(BackpackPresentation.status(state: .off, setup: ready)
                == SettingsStatus(.idle, "Off · ⌘B turns it on when Phone is in range"))
        let battery = BackpackStatus(network: "Phone", joined: true, power: PowerReading(level: 64, onBattery: true), cutoff: 10)
        #expect(BackpackPresentation.status(state: .on(battery), setup: ready) == SettingsStatus(.ready, "On · joined Phone · battery 64 %"))
        let mains = BackpackStatus(network: "Phone", joined: true, power: .mains, cutoff: 10)
        #expect(BackpackPresentation.status(state: .on(mains), setup: ready) == SettingsStatus(.ready, "On · joined Phone"))
        let away = BackpackStatus(network: "Phone", joined: false, power: .mains, cutoff: 10)
        #expect(BackpackPresentation.status(state: .on(away), setup: ready)
                == SettingsStatus(.attention, "On · not joined to Phone, rejoining when it’s in range"))
        let low = BackpackStatus(network: "Phone", joined: true, power: PowerReading(level: 13, onBattery: true), cutoff: 10)
        #expect(BackpackPresentation.status(state: .on(low), setup: ready) == SettingsStatus(.attention, "On · battery 13 %, turns off at 10 %"))
    }

    @Test func theStepsAreTheMissingOnesInOrder() {
        #expect(BackpackPresentation.steps(setup: BackpackSetup(sleepRule: false, location: false, network: nil)) == [
            "Allow AiTerm to keep the Mac awake with the lid closed. Asks for your password once.",
            "Allow Location access, so AiTerm can see which Wi-Fi networks are in range.",
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

    /// Settings opens on the saved fields, and Save writes what they hold back.
    @Test func saveWritesBothFields() {
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
        #expect(settings._backpackPassword.wrappedValue == "hunter2")
        backpack.network = nil
        backpack.cutoff = 10
        backpack.password = nil
        settings.saveBackpack()
        #expect(backpack.network == "Phone")
        #expect(backpack.cutoff == 20)
        #expect(backpack.password == "hunter2")
    }
}
