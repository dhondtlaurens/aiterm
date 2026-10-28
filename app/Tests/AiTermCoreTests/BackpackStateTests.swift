import Testing
@testable import AiTermCore

@Suite struct BackpackStateTests {
    @Test func refusalsSayWhyInTheSpecsWords() {
        #expect(BackpackRefusal.needsSetup.message == "Unplugged needs setup: Settings › Integrations › Mac")
        #expect(BackpackRefusal.batteryLow(level: 8).message == "Battery at 8 %: Unplugged stays off")
        #expect(BackpackRefusal.notInRange(network: "Laurens D’Hondt - iPhone").message
                == "Laurens D’Hondt - iPhone isn’t showing its hotspot: open Personal Hotspot on the iPhone")
        #expect(BackpackRefusal.joinFailed(network: "Phone").message == "Couldn’t join Phone: check its password")
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
