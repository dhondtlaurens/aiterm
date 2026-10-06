import Foundation
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
@Suite struct HarnessSettingsModelTests {
    @Test func loadIsReadOnlyAndInstallIsExplicit() async {
        let fake = FakeHarnessService()
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: isolatedDefaults())

        await model.load()

        #expect(await fake.installedAgents().isEmpty)
        #expect(model.snapshots[.pi]?.health == .warning)

        await model.install(.pi)

        #expect(await fake.installedAgents() == [.pi])
        #expect(model.snapshots[.pi]?.integrationState == .current)
        // No Test button follows an install, so the install tests the driver itself.
        #expect(await fake.testedAgents().filter { $0 == .pi } == [.pi])
    }

    /// A card with no CLI keeps its Install: it runs the vendor's installer, then the driver, and
    /// the sheets learn the agent exists without waiting for a relaunch.
    @Test func installingAMissingCLIAnnouncesIt() async {
        let fake = FakeHarnessService(snapshots: readySnapshots.merging([
            .codex: snapshot(.codex, health: .unavailable, summary: "Codex CLI is unavailable.",
                             integration: .notChecked, models: []),
        ]) { _, replacement in replacement })
        var announced: [AgentKind] = []
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: isolatedDefaults(),
                                         cliInstalled: { announced.append($0) })
        await model.load()
        #expect(model.snapshots[.codex]?.canInstall == true)

        await model.install(.codex)

        #expect(await fake.installedAgents() == [.codex])
        #expect(model.snapshots[.codex]?.health != .unavailable)
        #expect(announced == [.codex])
    }

    /// Reinstalling a driver over a present CLI is not news to the sheets.
    @Test func installingADriverAloneAnnouncesNoCLI() async {
        var announced: [AgentKind] = []
        let model = HarnessSettingsModel(service: FakeHarnessService(), rememberedModels: { [:] },
                                         defaults: isolatedDefaults(), cliInstalled: { announced.append($0) })
        await model.load()

        await model.install(.pi)

        #expect(announced.isEmpty)
    }

    /// The CLI can land on disk and the driver still fail. The card must then show the CLI it has,
    /// not the "unavailable" it had before the click, and the sheets must still hear about it.
    @Test func aDriverFailureAfterTheCLIInstalledShowsTheCLI() async {
        let fake = FakeHarnessService(
            snapshots: readySnapshots.merging([
                .claude: snapshot(.claude, health: .unavailable, summary: "Claude Code CLI is unavailable.",
                                  integration: .notChecked, models: []),
            ]) { _, replacement in replacement },
            installFailure: HarnessServiceError.resourceUnavailable("The bundled driver is unavailable."),
            afterFailure: snapshot(.claude, health: .warning, summary: "The bundled driver is unavailable.",
                                   integration: .resourceUnavailable, models: [claudeModel]))
        var announced: [AgentKind] = []
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: isolatedDefaults(),
                                         cliInstalled: { announced.append($0) })
        await model.load()

        await model.install(.claude)

        #expect(model.snapshots[.claude]?.health == .warning)
        #expect(model.snapshots[.claude]?.checks.first { $0.id == .cli }?.passed == true)
        #expect(model.snapshots[.claude]?.summary == "The bundled driver is unavailable.")
        #expect(announced == [.claude])
    }

    @Test func aFailedCLIInstallKeepsTheCardUnavailableWithTheInstallersReason() async {
        let unavailable = snapshot(.pi, health: .unavailable, summary: "PI CLI is unavailable.",
                                   integration: .notChecked, models: [])
        let reason = "No terminal detected; install Node.js 22.19.0 or newer and npm, then run this installer again."
        let fake = FakeHarnessService(
            snapshots: readySnapshots.merging([.pi: unavailable]) { _, replacement in replacement },
            installFailure: CLIInstallError.failed(.pi, reason))
        var announced: [AgentKind] = []
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: isolatedDefaults(),
                                         cliInstalled: { announced.append($0) })
        await model.load()

        await model.install(.pi)

        #expect(model.snapshots[.pi]?.health == .unavailable)
        #expect(model.snapshots[.pi]?.summary == reason)
        #expect(announced.isEmpty)
    }

    @Test func installOverwritesADriverThatIsAlreadyCurrent() async {
        let fake = FakeHarnessService(snapshots: readySnapshots)
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: isolatedDefaults())
        await model.load()

        await model.install(.claude)

        #expect(await fake.installedAgents() == [.claude])
        #expect(model.snapshots[.claude]?.health == .ready)
    }

    @Test func openingSettingsTestsEveryInstalledDriver() async {
        let passed = HarnessCheck(.delivery, passed: true, explanation: nil)
        let fake = FakeHarnessService(testChecks: [passed])
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: isolatedDefaults())

        await model.load()

        // PI's driver is missing in the default fixture: nothing to test until it is installed.
        #expect(Set(await fake.testedAgents()) == [.claude, .codex, .grok])
        #expect(model.snapshots[.claude]?.checks.contains(passed) == true)
        #expect(model.snapshots[.codex]?.checks.contains(passed) == true)
        #expect(model.snapshots[.grok]?.checks.contains(passed) == true)
        #expect(model.snapshots[.pi]?.checks.contains { $0.id == .delivery } == false)
        #expect(model.running.isEmpty)
    }

    @Test func failedTestBecomesWarningWithShortReason() async {
        let fake = FakeHarnessService(snapshots: readySnapshots, testResult: snapshot(
            .pi, health: .warning, summary: "AiTerm did not receive the test event.",
            integration: .current, models: [piModel]))
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: isolatedDefaults())

        await model.load()

        #expect(model.snapshots[.pi]?.health == .warning)
        #expect(model.snapshots[.pi]?.summary == "AiTerm did not receive the test event.")
    }

    @Test func failedTestIsNotMaskedByAMissingSavedDefault() async {
        let defaults = isolatedDefaults()
        ModelSettings.save(.init(model: "openai/removed", reasoning: "high"), for: .pi, defaults: defaults)
        let failed = snapshot(.pi, health: .warning, summary: "AiTerm did not receive the test event.",
                              integration: .current, models: [piModel])
        let fake = FakeHarnessService(snapshots: readySnapshots, testResult: failed)
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: defaults)

        await model.load()

        #expect(model.snapshots[.pi]?.summary == "AiTerm did not receive the test event.")
        #expect(model.snapshots[.pi]?.checks.last?.id == .selectedModel)
    }

    @Test func saveKeepsExistingDefaultsAndAddsPiKey() async {
        let defaults = isolatedDefaults()
        ModelSettings.save(.init(model: "opus", reasoning: "high"), for: .claude, defaults: defaults)
        let fake = FakeHarnessService(snapshots: readySnapshots)
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: defaults)
        await model.load()

        model.select(piModel, for: .pi)
        model.save()

        #expect(ModelSettings.load(for: .claude, defaults: defaults)?.model == "opus")
        #expect(ModelSettings.load(for: .pi, defaults: defaults)?.model == piModel.id)
    }

    /// Every card shows a default, most of them resolved rather than saved — the last model used,
    /// or the catalogue's first. Save writes only the ones the person picked, so an untouched agent
    /// keeps following that resolution instead of being pinned to what it happened to be.
    @Test func saveWritesOnlyTheAgentsWhoseDefaultWasPicked() async {
        let defaults = isolatedDefaults()
        let sonnet = AgentModel(id: "sonnet", label: "Sonnet", detail: nil, efforts: ["low", "high"], defaultEffort: "low")
        let claude = snapshot(.claude, health: .ready, summary: "Ready.", integration: .current, models: [claudeModel, sonnet])
        let fake = FakeHarnessService(snapshots: readySnapshots.merging([.claude: claude]) { _, replacement in replacement })
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [.codex: codexModel.id] }, defaults: defaults)
        await model.load()
        #expect(model.preferences[.codex]?.model == codexModel.id)
        #expect(model.preferences[.pi]?.model == piModel.id)

        model.select(sonnet, for: .claude)
        model.save()

        #expect(ModelSettings.load(for: .claude, defaults: defaults)?.model == "sonnet")
        #expect(ModelSettings.load(for: .codex, defaults: defaults) == nil)
        #expect(ModelSettings.load(for: .pi, defaults: defaults) == nil)
    }

    /// The model outlives a Settings presentation, and a task created meanwhile changes which model
    /// an agent was last used with; a reopened card resolves from that, not from launch.
    @Test func aReopenedCardResolvesFromTheModelsRememberedNow() async {
        let sonnet = AgentModel(id: "sonnet", label: "Sonnet", detail: nil, efforts: ["low", "high"], defaultEffort: "low")
        let claude = snapshot(.claude, health: .ready, summary: "Ready.", integration: .current, models: [claudeModel, sonnet])
        let fake = FakeHarnessService(snapshots: readySnapshots.merging([.claude: claude]) { _, replacement in replacement })
        let remembered = RememberedModels()
        let model = HarnessSettingsModel(service: fake, rememberedModels: { remembered.models }, defaults: isolatedDefaults())
        await model.load()
        #expect(model.preferences[.claude]?.model == claudeModel.id)

        remembered.models[.claude] = sonnet.id
        await model.load()

        #expect(model.preferences[.claude]?.model == sonnet.id)
    }

    @Test func missingSavedModelStaysWarningAndStaleCatalogCannotReplaceIt() async {
        let defaults = isolatedDefaults()
        ModelSettings.save(.init(model: "openai/model-x", reasoning: "high"), for: .pi, defaults: defaults)
        let stale = snapshot(.pi, health: .warning, summary: "The PI model catalogue couldn’t be refreshed.",
                             integration: .current,
                             models: [.init(id: "anthropic/model-x", label: "anthropic / model-x",
                                            detail: nil, efforts: ["high"], defaultEffort: "high")],
                             modelsAreStale: true)
        let fake = FakeHarnessService(snapshots: readySnapshots.merging([.pi: stale]) { _, replacement in replacement })
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: defaults)

        await model.load()

        #expect(model.snapshots[.pi]?.health == .warning)
        #expect(model.snapshots[.pi]?.summary == "The PI model catalogue couldn’t be refreshed.")
        #expect(model.preferences[.pi]?.model == "openai/model-x")
        model.select(stale.models[0], for: .pi)
        model.save()
        #expect(ModelSettings.load(for: .pi, defaults: defaults)?.model == "openai/model-x")
    }

    @Test func missingSavedModelNeverMasksAnUnavailableCLI() async {
        let defaults = isolatedDefaults()
        ModelSettings.save(.init(model: "openai/removed", reasoning: "high"), for: .pi, defaults: defaults)
        let unavailable = snapshot(.pi, health: .unavailable, summary: "PI CLI is unavailable.",
                                   integration: .notChecked, models: [])
        let fake = FakeHarnessService(snapshots: readySnapshots.merging([.pi: unavailable]) { _, replacement in replacement })
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: defaults)

        await model.load()

        #expect(model.snapshots[.pi]?.health == .unavailable)
        #expect(model.snapshots[.pi]?.summary == "PI CLI is unavailable.")
        #expect(model.snapshots[.pi]?.checks.contains { $0.id == .selectedModel } == false)
    }

    @Test func selectingAFreshModelClearsTheLocalMissingModelWarning() async {
        let defaults = isolatedDefaults()
        ModelSettings.save(.init(model: "removed/model", reasoning: "high"), for: .pi, defaults: defaults)
        let fake = FakeHarnessService(snapshots: readySnapshots)
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: defaults)
        await model.load()
        #expect(model.snapshots[.pi]?.summary == "The selected model is no longer available.")

        model.select(piModel, for: .pi)

        #expect(model.snapshots[.pi]?.health == .ready)
        model.save()
        #expect(ModelSettings.load(for: .pi, defaults: defaults)?.model == piModel.id)
    }

    @Test func reopeningSettingsDiscardsAnUnsavedModelChoice() async {
        let defaults = isolatedDefaults()
        ModelSettings.save(.init(model: piModel.id, reasoning: "medium"), for: .pi, defaults: defaults)
        let alternative = AgentModel(id: "anthropic/claude-sonnet", label: "anthropic / claude-sonnet",
                                     detail: nil, efforts: ["medium", "high"], defaultEffort: "medium")
        let pi = snapshot(.pi, health: .ready, summary: "Ready.", integration: .current,
                          models: [piModel, alternative])
        let fake = FakeHarnessService(snapshots: readySnapshots.merging([.pi: pi]) { _, replacement in replacement })
        let model = HarnessSettingsModel(service: fake, rememberedModels: { [:] }, defaults: defaults)
        await model.load()
        model.select(alternative, for: .pi)
        #expect(model.preferences[.pi]?.model == alternative.id)

        await model.load()

        #expect(model.preferences[.pi]?.model == piModel.id)
    }

    @Test func missingResourcesNeverInvokeInstall() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiterm-missing-harness-resources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" }, run: { _, _, _, _ in
            ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false)
        })

        for resources in [
            HarnessResources([:], installationAllowed: true, unavailableReason: nil),
            HarnessResources([.claude: "/missing/shim", .pi: "owned"], installationAllowed: false,
                             unavailableReason: BundleLocation.translocationWarning),
        ] {
            let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                         resources: resources,
                                         testTransport: HarnessTestTransport { _, _, _ in throw URLError(.cannotConnectToHost) })
            let model = HarnessSettingsModel(service: service, rememberedModels: { [:] },
                                             defaults: isolatedDefaults())
            await model.install(.claude)
            await model.install(.pi)
            #expect(model.snapshots[.claude]?.health == .warning)
            #expect(model.snapshots[.pi]?.health == .warning)
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".pi").path))
        }
    }
}

private let piModel = AgentModel(id: "openai-codex/gpt-5.6-sol", label: "openai-codex / gpt-5.6-sol",
                                 detail: "128k context", efforts: ["off", "medium", "high"],
                                 defaultEffort: "medium")
private let claudeModel = AgentModel(id: "opus", label: "Opus", detail: nil,
                                     efforts: ["low", "high"], defaultEffort: "high")
private let codexModel = AgentModel(id: "gpt-5.6", label: "gpt-5.6", detail: nil,
                                    efforts: ["medium", "high"], defaultEffort: "medium")
private let grokModel = AgentModel(id: "grok-4.7", label: "Grok 4.7", detail: nil,
                                   efforts: ["medium", "high"], defaultEffort: "high")

private let readySnapshots: [AgentKind: HarnessSnapshot] = [
    .claude: snapshot(.claude, health: .ready, summary: "Ready.", integration: .current, models: [claudeModel]),
    .codex: snapshot(.codex, health: .ready, summary: "Ready.", integration: .current, models: [codexModel]),
    .grok: snapshot(.grok, health: .ready, summary: "Ready.", integration: .current, models: [grokModel]),
    .pi: snapshot(.pi, health: .ready, summary: "Ready.", integration: .current, models: [piModel]),
]

private func snapshot(_ agent: AgentKind, health: HarnessHealth, summary: String,
                      integration: HarnessIntegrationState, models: [AgentModel],
                      modelsAreStale: Bool = false) -> HarnessSnapshot {
    var checks = [HarnessCheck(.cli, passed: health != .unavailable,
                               explanation: health == .unavailable ? summary : nil),
                  HarnessCheck(.integration, passed: integration == .current,
                               explanation: integration == .current ? nil : summary)]
    if health == .warning, integration == .current, !modelsAreStale {
        checks.append(HarnessCheck(.delivery, passed: false,
                                   explanation: summary))
    }
    if modelsAreStale {
        checks.append(HarnessCheck(.models, passed: false,
                                   explanation: summary))
    }
    return HarnessSnapshot(agent: agent, health: health, summary: summary,
                           checks: checks, models: models, modelsAreStale: modelsAreStale,
                           integrationState: integration)
}

private func isolatedDefaults() -> UserDefaults { ScratchDefaults.make() }

private actor FakeHarnessService: HarnessServicing {
    private var snapshots: [AgentKind: HarnessSnapshot]
    private var installed: [AgentKind] = []
    private var tested: [AgentKind] = []
    private let testResult: HarnessSnapshot?
    private let testChecks: [HarnessCheck]
    /// Thrown by `install`, after the card has become `afterFailure` — a CLI the installer put on
    /// disk before the driver failed.
    private let installFailure: (any Error)?
    private let afterFailure: HarnessSnapshot?

    init(snapshots: [AgentKind: HarnessSnapshot] = readySnapshots.merging([
        .pi: snapshot(.pi, health: .warning, summary: "Driver is not installed.",
                      integration: .missing, models: [piModel]),
    ]) { _, replacement in replacement }, testResult: HarnessSnapshot? = nil,
         testChecks: [HarnessCheck] = [], installFailure: (any Error)? = nil,
         afterFailure: HarnessSnapshot? = nil) {
        self.snapshots = snapshots
        self.testResult = testResult
        self.testChecks = testChecks
        self.installFailure = installFailure
        self.afterFailure = afterFailure
    }

    func probe(_ agent: AgentKind) async -> HarnessSnapshot { snapshots[agent]! }

    func install(_ agent: AgentKind) async throws -> HarnessSnapshot {
        installed.append(agent)
        if let installFailure {
            if let afterFailure { snapshots[agent] = afterFailure }
            throw installFailure
        }
        let current = snapshots[agent]!
        let next = snapshot(agent, health: .ready, summary: "Ready.", integration: .current,
                            models: current.models)
        snapshots[agent] = next
        return next
    }

    func test(_ snapshot: HarnessSnapshot) async -> HarnessSnapshot {
        let agent = snapshot.agent
        tested.append(agent)
        if let testResult { return testResult }
        var result = snapshots[agent]!
        result.checks += testChecks
        return result
    }

    func installedAgents() -> [AgentKind] { installed }

    func testedAgents() -> [AgentKind] { tested }
}

/// What the app remembers of each agent's last model, changed by a test between two loads. A
/// class, because `rememberedModels` is a main-actor closure and so cannot capture a `var`.
@MainActor private final class RememberedModels { var models: [AgentKind: String] = [:] }
