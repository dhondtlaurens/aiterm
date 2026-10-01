import Foundation

public enum HarnessServiceError: Error, Equatable, LocalizedError {
    case operationNotAllowed(AgentKind, HarnessIntegrationState)
    case resourceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .operationNotAllowed(let agent, _):
            return "The \(agent.displayName) driver cannot be changed in its current state."
        case .resourceUnavailable(let explanation):
            return explanation
        }
    }
}

/// Probes, installs and tests the agent harnesses for Settings. Every process it starts — finding
/// a CLI is a login shell, PI's catalogue a launch of PI, an install up to ten minutes of a vendor
/// script — runs through `BackgroundWork`, never on the actor: a blocked cooperative thread would
/// queue every other card's probe behind it. So the actor is reentrant across those launches.
public actor HarnessService {
    private let home: URL
    private let runner: HarnessCommandRunner
    private let resources: HarnessResources
    private let testClient: HarnessTestClient
    /// Each agent's driver, when this copy of AiTerm can install it: none from a translocated
    /// bundle, or without the bundled resource it writes.
    private let drivers: [AgentKind: any HarnessDriver]
    /// The catalogue each agent's last successful probe found, and that probe's number: probes of
    /// one agent can overlap, and an older one finishing last must not replace a newer answer.
    private var lastSuccessfulCatalogues: [AgentKind: (probe: Int, models: [AgentModel])] = [:]
    private var probesStarted = 0

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                daemonPort: Int, runner: HarnessCommandRunner = .live,
                resources: HarnessResources = .bundled(),
                testTransport: HarnessTestTransport = .live) {
        self.home = home
        self.runner = runner
        self.resources = resources
        self.testClient = HarnessTestClient(runner: runner, transport: testTransport,
                                            daemonPort: daemonPort)
        var drivers: [AgentKind: any HarnessDriver] = [:]
        if resources.installationAllowed {
            drivers[.claude] = resources.claudeShimPath.map { ClaudeDriver(home: home, daemonPort: daemonPort, shimPath: $0) }
            drivers[.codex] = CodexDriver(home: home, daemonPort: daemonPort)
            drivers[.grok] = resources.grokShimPath.map { GrokDriver(home: home, daemonPort: daemonPort, shimPath: $0) }
            drivers[.pi] = resources.piExtensionSource.map { PiDriver(home: home, source: $0) }
        }
        self.drivers = drivers
    }

    public func probe(_ agent: AgentKind) async -> HarnessSnapshot { await probe(agent, reusingCatalogueOf: nil) }

    /// `earlier`, a probe that found the CLI, lends its catalogue — its models and their check —
    /// instead of reading it again: writing a driver changes nothing about which models there are,
    /// and for PI reading them is a launch.
    private func probe(_ agent: AgentKind, reusingCatalogueOf earlier: HarnessSnapshot?) async -> HarnessSnapshot {
        probesStarted += 1
        let probe = probesStarted, runner = self.runner
        guard let executable = try? await BackgroundWork.run({ runner.locate(agent.rawValue) }),
              LoginShell.isExecutableFile(executable) else {
            return .reduce(agent: agent, cliAvailable: false, integrationState: .notChecked,
                                    models: [], checks: [HarnessCheck(id: "cli", label: "CLI", passed: false,
                                                                     explanation: "\(agent.displayName) CLI is unavailable.")])
        }

        var checks = [HarnessCheck(id: "cli", label: "CLI", passed: true, explanation: nil)]
        let driver = drivers[agent]?.probe()
            ?? DriverProbe(state: .resourceUnavailable, explanation: resources.unavailableReason ?? "The bundled driver is unavailable.")
        let integration = driver.state
        // The UI calls every harness's integration a driver: hooks for Claude, Codex and Grok, an
        // extension for PI — the same job, so one word.
        checks.append(HarnessCheck(id: "integration", label: "Driver",
                                   passed: integration == .current, explanation: driver.explanation))
        checks += driver.checks

        let catalogue: Catalogue
        if let earlier, earlier.health != .unavailable {
            catalogue = Catalogue(models: earlier.models, stale: earlier.modelsAreStale,
                                  check: earlier.checks.first { $0.id == "models" })
        } else {
            catalogue = await readCatalogue(agent, executable: executable, probe: probe)
        }
        let models = catalogue.models, stale = catalogue.stale
        checks.append(catalogue.check ?? HarnessCheck(
            id: "models", label: "Models", passed: !models.isEmpty,
            explanation: models.isEmpty ? agent.noModelsExplanation : nil))
        return .reduce(agent: agent, cliAvailable: true, integrationState: integration,
                                models: models, modelsAreStale: stale, checks: checks)
    }

    /// An agent's models, and the Models check when it is already known: a failed read's, or the
    /// earlier probe's. Otherwise the check follows from whether there are any.
    private struct Catalogue { var models: [AgentModel], stale: Bool, check: HarnessCheck? }

    private func readCatalogue(_ agent: AgentKind, executable: String, probe: Int) async -> Catalogue {
        switch agent {
        case .claude, .codex, .grok:
            let models = ModelCatalog.models(for: agent, home: home)
            remember(models, for: agent, from: probe)
            return Catalogue(models: models, stale: false, check: nil)
        case .pi:
            let runner = self.runner
            do {
                let models = try await BackgroundWork.run { try PiModelCatalog.discover(executable: executable, runner: runner) }
                remember(models, for: agent, from: probe)
                return Catalogue(models: models, stale: false, check: nil)
            } catch {
                // The CLI was already located and executable, so a failed launch is a models
                // warning, never an unavailable card that would hide every action.
                let models = lastSuccessfulCatalogues[agent]?.models ?? []
                let stale = !models.isEmpty
                let explanation: String
                if case PiModelCatalogError.unavailable = error {
                    explanation = "PI couldn’t be launched."
                } else {
                    explanation = stale
                        ? "The PI model catalogue couldn’t be refreshed."
                        : "The PI model catalogue is unavailable."
                }
                return Catalogue(models: models, stale: stale,
                                 check: HarnessCheck(id: "models", label: "Models", passed: false, explanation: explanation))
            }
        }
    }

    /// A missing CLI is installed first, with its vendor's installer, and then its driver — one
    /// Install either way. A CLI already present is never reinstalled; it updates itself.
    ///
    /// Two installs of one agent at once would run its vendor's installer twice; the Settings
    /// model never starts a second while the first runs.
    public func install(_ agent: AgentKind) async throws -> HarnessSnapshot {
        var before = await probe(agent)
        if before.health == .unavailable {
            let runner = self.runner
            try await BackgroundWork.run { try CLIInstaller.install(agent, runner: runner) }
            before = await probe(agent)
            guard before.health != .unavailable else { throw CLIInstallError.notOnPath(agent) }
        }
        if before.integrationState == .resourceUnavailable {
            throw HarnessServiceError.resourceUnavailable(before.summary)
        }
        guard before.canInstall else {
            throw HarnessServiceError.operationNotAllowed(agent, before.integrationState)
        }
        guard let driver = drivers[agent] else {
            throw HarnessServiceError.resourceUnavailable(
                resources.unavailableReason ?? "The bundled \(agent.displayName) driver is unavailable.")
        }
        try driver.install()
        return await probe(agent, reusingCatalogueOf: before)
    }

    /// Tests the driver `before` — the caller's latest probe or install — reports as current, and
    /// adds what the Test found to it, rather than probing all over again.
    public func test(_ before: HarnessSnapshot) async -> HarnessSnapshot {
        guard before.health != .unavailable, before.integrationState == .current,
              let driver = drivers[before.agent] else { return before }
        let result = await driver.test(with: testClient)
        let checks = before.checks.filter { $0.id != "daemon" && $0.id != "delivery" } + result.checks
        return .reduce(agent: before.agent, cliAvailable: true,
                                integrationState: before.integrationState,
                                models: before.models, modelsAreStale: before.modelsAreStale,
                                checks: checks)
    }

    private func remember(_ models: [AgentModel], for agent: AgentKind, from probe: Int) {
        guard probe > lastSuccessfulCatalogues[agent]?.probe ?? 0 else { return }
        lastSuccessfulCatalogues[agent] = (probe, models)
    }
}
