import Testing
@testable import AiTermCore

@Suite struct BackpackStateTests {
    @Test func refusalsSayWhyInTheSpecsWords() {
        #expect(BackpackRefusal.needsSetup.message == "Backpack Mode needs setup: Settings › Backpack")
        #expect(BackpackRefusal.batteryLow(level: 8).message == "Battery at 8 %: Backpack Mode stays off")
        #expect(BackpackRefusal.notInRange(network: "Laurens D’Hondt - iPhone").message
                == "Laurens D’Hondt - iPhone isn’t in range: Backpack Mode stays off")
        #expect(BackpackRefusal.joinFailed(network: "Phone").message == "Couldn’t join Phone: check its password in Settings › Backpack")
        #expect(BackpackCopy.turnedOn(network: "Phone") == "Backpack Mode on · joined Phone")
        #expect(BackpackCopy.cutOff(level: 10) == "Battery at 10 %: Backpack Mode turned off")
    }

    @Test func degradedWhenNotJoinedOrWithinFivePointsOfTheCutoffOnBattery() {
        let fine = BackpackStatus(network: "P", joined: true, power: PowerReading(level: 16, onBattery: true), cutoff: 10)
        #expect(!fine.degraded)
        #expect(BackpackStatus(network: "P", joined: true, power: PowerReading(level: 15, onBattery: true), cutoff: 10).nearCutoff)
        #expect(BackpackStatus(network: "P", joined: false, power: .mains, cutoff: 10).degraded)
        // On AC the battery level never degrades it.
        #expect(!BackpackStatus(network: "P", joined: true, power: PowerReading(level: 11, onBattery: false), cutoff: 10).degraded)
    }

    @Test func setupIsCompleteOnlyWithTheRuleLocationAndANetwork() {
        #expect(BackpackSetup(sleepRule: true, location: true, network: "P").isComplete)
        #expect(!BackpackSetup(sleepRule: false, location: true, network: "P").isComplete)
        #expect(!BackpackSetup(sleepRule: true, location: false, network: "P").isComplete)
        #expect(!BackpackSetup(sleepRule: true, location: true, network: nil).isComplete)
        #expect(BackpackSetup(sleepRule: true, location: false, network: nil).missingSteps == [.location])
    }

    @Test func theInertPortsAreSetUpForNothing() {
        let ports = BackpackPorts.inert
        #expect(!ports.lidSleep.isAllowed())
        #expect(!ports.location.isAuthorized())
        #expect(ports.wifi.knownNetworks().isEmpty)
        #expect(ports.power.reading() == .mains)
    }
}
