import AppKit
import SwiftUI
import Testing
import AiTermCore
import AiTermUI
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
@Suite struct HarnessSettingsLayoutTests {
    @Test func settingsTabsAndCardsStayInHarnessOrder() {
        #expect(SettingsTab.allCases == [.agents, .integrations, .interface])
        #expect(SettingsTab.agents.rawValue == "Agents")
        #expect(SettingsTab.interface.rawValue == "Interface")
        #expect(HarnessCardPresentation.agents == [.claude, .codex, .grok, .pi])
    }

    /// Integrations when something there is broken, Agents otherwise.
    @Test func settingsOpensWhereSomethingIsBroken() {
        #expect(SettingsTab.opening(iterm: .connected(version: "3.7.2"), serviceTestFailed: false) == .agents)
        #expect(SettingsTab.opening(iterm: .connected(version: nil), serviceTestFailed: true) == .integrations)
        for broken: ItermConnection in [.starting, .waitingForIterm, .itermReconnecting, .pythonMissing,
                                        .helperMissing, .helperUnreachable, .refused("no")] {
            #expect(SettingsTab.opening(iterm: broken, serviceTestFailed: false) == .integrations)
        }
    }

    /// Decided as the sheet opens, from the record and the connection as they stand then.
    @Test func theOpeningTabIsReadWhenSettingsOpens() {
        let record = ServiceTestRecord()
        func open(_ iterm: ItermConnection) -> SettingsTab {
            SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: HarnessSettingsModel.preview(),
                         itermConnection: { iterm }, checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                         preferences: .scratch(), setMatchItermBackground: { _ in }, setInterfaceSize: { _ in },
                         testRecord: record)._tab.wrappedValue
        }
        #expect(open(.connected(version: "3.7.2")) == .agents)
        #expect(open(.waitingForIterm) == .integrations)
        record.gitLabFailed = true
        #expect(open(.connected(version: "3.7.2")) == .integrations)
    }

    @Test func commandDigitsPickTheTabsInOrder() {
        #expect(SettingsTab.allCases.map(\.key) == ["1", "2", "3"])
    }

    @Test func aCardDrawsItsMarkAndActionsAtTheControlHeight() {
        // The Install button was `.small`; every button in a sheet is a 28 pt control.
        #expect(SettingsCard<EmptyView, EmptyView, EmptyView, EmptyView>.markSize == Size.control)
        #expect(SettingsCard<EmptyView, EmptyView, EmptyView, EmptyView>.actionControlSize == .large)
    }

    @Test func chipsShowOnlyTheCLIAndTheDriver() {
        // Models is not a chip: the picker below already carries an empty catalogue, and a test's
        // daemon and delivery checks surface through the status sentence instead.
        let snapshot = HarnessSnapshot.reduce(agent: .claude, cliAvailable: true, integrationState: .current,
                                              models: [], checks: [
            HarnessCheck(id: "cli", label: "CLI", passed: true, explanation: nil),
            HarnessCheck(id: "integration", label: "Driver", passed: true, explanation: nil),
            HarnessCheck(id: "models", label: "Models", passed: false, explanation: "No models are available."),
            HarnessCheck(id: "delivery", label: "Status delivery", passed: true, explanation: nil),
        ])
        #expect(HarnessCardPresentation.chips(for: snapshot).map(\.label) == ["CLI", "Driver"])
    }

    @Test func harnessStatusSpeaksTheSharedThreeStates() {
        let ready = HarnessSnapshot.reduce(agent: .claude, cliAvailable: true, integrationState: .current,
                                           models: [readyModel], checks: [])
        let tested = HarnessSnapshot.reduce(agent: .claude, cliAvailable: true, integrationState: .current,
                                            models: [readyModel], checks: [
            HarnessCheck(id: "delivery", label: "Status delivery", passed: true, explanation: nil),
        ])
        let missing = HarnessSnapshot.reduce(agent: .pi, cliAvailable: true, integrationState: .missing,
                                             models: [readyModel])
        let absent = HarnessSnapshot.reduce(agent: .pi, cliAvailable: false, integrationState: .notChecked,
                                            models: [])

        #expect(HarnessCardPresentation.status(for: ready) == SettingsStatus(.ready, "Ready"))
        #expect(HarnessCardPresentation.status(for: tested) == SettingsStatus(.ready, "Ready"))
        #expect(HarnessCardPresentation.status(for: missing) == SettingsStatus(.attention, "Driver is not installed"))
        #expect(HarnessCardPresentation.status(for: absent) == SettingsStatus(.idle, "PI CLI is unavailable"))
        let failedInstall = HarnessSnapshot.reduce(
            agent: .pi, cliAvailable: false, integrationState: .notChecked, models: [],
            checks: [HarnessCheck(id: "operation", label: "Setup", passed: false,
                                  explanation: "curl: (6) Could not resolve host: pi.dev")])
        #expect(HarnessCardPresentation.status(for: failedInstall)
                == SettingsStatus(.attention, "curl: (6) Could not resolve host: pi.dev"))
    }

    /// A status line carries no full stop, not even the one an error's own sentence ends with.
    @Test func aStatusLineEndsWithoutAFullStop() {
        #expect(SettingsStatus(.attention, "Driver is not installed.").text == "Driver is not installed")
        #expect(SettingsStatus(.idle, "Testing…").text == "Testing…")
        #expect(IntegrationCardPresentation.status(configured: true, test: .failed("Couldn’t connect to Jira. Offline.")).text
                == "Couldn’t connect to Jira. Offline")
    }

    @Test func integrationStatusSpeaksTheSameThreeStates() {
        #expect(IntegrationCardPresentation.status(configured: false, test: nil) == SettingsStatus(.idle, "Not set up"))
        #expect(IntegrationCardPresentation.status(configured: true, test: nil) == SettingsStatus(.idle, "Not tested yet"))
        #expect(IntegrationCardPresentation.status(configured: true, test: .running) == SettingsStatus(.idle, "Testing…"))
        #expect(IntegrationCardPresentation.status(configured: true, test: .connected("Sam"))
                == SettingsStatus(.ready, "Connected as Sam"))
        #expect(IntegrationCardPresentation.status(configured: true, test: .failed("401 Unauthorized"))
                == SettingsStatus(.attention, "401 Unauthorized"))
    }

    /// Every card keeps Install: over a missing CLI it runs the vendor's installer first.
    @Test func installStaysOnEveryCard() {
        let unavailable = cardSnapshot(.pi, health: .unavailable, integration: .notChecked)
        let missing = cardSnapshot(.pi, health: .warning, integration: .missing)
        let current = cardSnapshot(.pi, health: .ready, integration: .current)
        let outdated = cardSnapshot(.pi, health: .warning, integration: .outdated)
        let invalid = cardSnapshot(.pi, health: .warning, integration: .invalidOwned)
        let foreign = cardSnapshot(.pi, health: .warning, integration: .foreign)

        for snapshot in [unavailable, missing, current, outdated, invalid] {
            #expect(snapshot.canInstall)
        }
        // Disabled: a foreign file is never AiTerm's to overwrite.
        #expect(!foreign.canInstall)
    }

    /// One code path, three names: what the button will do on this card.
    @Test func theActionIsNamedForTheCardsState() {
        #expect(HarnessCardPresentation.action(for: cardSnapshot(.pi, health: .unavailable, integration: .notChecked)) == "Install")
        #expect(HarnessCardPresentation.action(for: cardSnapshot(.pi, health: .warning, integration: .missing)) == "Install")
        #expect(HarnessCardPresentation.action(for: cardSnapshot(.pi, health: .warning, integration: .outdated)) == "Repair")
        #expect(HarnessCardPresentation.action(for: cardSnapshot(.pi, health: .warning, integration: .current)) == "Repair")
        #expect(HarnessCardPresentation.action(for: cardSnapshot(.pi, health: .ready, integration: .current)) == "Reinstall")
    }

    /// Grok's built-in status line leaves the card amber with nothing for Install to write, so the
    /// card names no action; a card with anything Install can change keeps its Repair.
    @Test func aCardWhoseOnlyWarningIsOneInstallCannotFixOffersNoAction() {
        func card(_ checks: [HarnessCheck]) -> HarnessSnapshot {
            HarnessSnapshot.reduce(agent: .grok, cliAvailable: true, integrationState: .current,
                                   models: [AgentModel(id: "m", label: "M", detail: nil, efforts: [], defaultEffort: nil)],
                                   checks: checks)
        }
        let cli = HarnessCheck(id: "cli", label: "CLI", passed: true, explanation: nil)
        let context = HarnessCheck(id: "context", label: "Context", passed: false, explanation: "built-in", repairable: false)
        let delivery = HarnessCheck(id: "delivery", label: "Delivery", passed: false, explanation: "no event arrived")

        #expect(HarnessCardPresentation.action(for: card([cli, context])) == nil)
        #expect(HarnessCardPresentation.action(for: card([cli, context, delivery])) == "Repair")
        #expect(HarnessCardPresentation.action(for: card([cli])) == "Reinstall")
    }

    @Test func missingDefaultIsAnExplicitPickerOptionInsteadOfTheFirstCurrentModel() {
        let current = AgentModel(id: "anthropic/current", label: "anthropic / current",
                                 detail: nil, efforts: ["high"], defaultEffort: "high")
        let preference = ModelPreference(model: "openai/removed", reasoning: "high")
        let options = HarnessCardPresentation.modelOptions([current], preference: preference)

        #expect(options.map(\.id) == ["", current.id])
        #expect(options.first?.label.contains("openai/removed") == true)
    }

    @Test func allHarnessCardsAreReachableInsideTheSettingsSheet() async throws {
        let model = HarnessSettingsModel.preview()
        let settings = SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: model,
                                    itermConnection: { .connected(version: "3.7.2") },
                                    checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                                    preferences: .scratch(), setMatchItermBackground: { _ in }, setInterfaceSize: { _ in }, initialTab: .agents)
        let host = NSHostingView(rootView: settings)
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.settingsHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        // Laid out once the settings have scrolled content: taller than what shows of it.
        settle(host) { firstScrollView(in: host).map { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height } ?? false }

        #expect(host.fittingSize.width <= Sheet.width)
        let scroll = try #require(firstScrollView(in: host))
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentView.bounds.height)
        let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.documentVisibleRect.maxY >= document.frame.maxY - 1)

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(firstScrollView).first
    }
}

private let readyModel = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: [], defaultEffort: nil)

private func cardSnapshot(_ agent: AgentKind, health: HarnessHealth,
                          integration: HarnessIntegrationState) -> HarnessSnapshot {
    HarnessSnapshot(agent: agent, health: health,
                    summary: health == .unavailable ? "PI CLI is unavailable." : "Driver is not installed.",
                    checks: [], models: [], modelsAreStale: false, integrationState: integration)
}
