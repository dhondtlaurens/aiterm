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
    private let runner: HarnessCommandRunner
    private let resources: HarnessResources
    private let testClient: HarnessTestClient
    /// Each agent's driver, when this copy of AiTerm can install it: none from a translocated
    /// bundle, or without the bundled resource it writes.
    private let drivers: [AgentKind: any HarnessDriver]
    /// The model lists, shared with the creation sheets in the app; it keeps the last list each
    /// agent's probe read, for a probe whose read fails.
    private let catalogue: ModelCatalogue

    /// `catalogue` is the app's, shared with the sheets; without one, the service reads `home`'s
    /// through `runner` on its own.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                daemonPort: Int, runner: HarnessCommandRunner = .live,
                catalogue: ModelCatalogue? = nil,
                resources: HarnessResources = .bundled(),
                testTransport: HarnessTestTransport = .live) {
        self.runner = runner
        self.catalogue = catalogue ?? ModelCatalogue(home: home, runner: runner)
        self.resources = resources
        self.testClient = HarnessTestClient(runner: runner, transport: testTransport,
                                            daemonPort: daemonPort)
        var drivers: [AgentKind: any HarnessDriver] = [:]
        if resources.installationAllowed {
            for agent in AgentKind.allCases {
                drivers[agent] = agent.harness.makeDriver(home, daemonPort, resources[agent])
            }
        }
        self.drivers = drivers
    }

    public func probe(_ agent: AgentKind) async -> HarnessSnapshot { await probe(agent, reusingCatalogueOf: nil) }

    /// `earlier`, a probe that found the CLI, lends its catalogue — its models and their check —
    /// instead of reading it again: writing a driver changes nothing about which models there are,
    /// and for PI reading them is a launch.
    private func probe(_ agent: AgentKind, reusingCatalogueOf earlier: HarnessSnapshot?) async -> HarnessSnapshot {
        let runner = self.runner
        let name = agent.harness.executable
        guard let executable = try? await BackgroundWork.run({ runner.locate(name) }),
              LoginShell.isExecutableFile(executable) else {
            return .reduce(agent: agent, cliAvailable: false, integrationState: .notChecked,
                                    models: [], checks: [HarnessCheck(.cli, passed: false,
                                                                      explanation: "\(agent.displayName) CLI is unavailable.")])
        }

        var checks = [HarnessCheck(.cli, passed: true, explanation: nil)]
        let driver = drivers[agent]?.probe()
            ?? DriverProbe(state: .resourceUnavailable, explanation: resources.unavailableReason ?? "The bundled driver is unavailable.")
        let integration = driver.state
        checks.append(HarnessCheck(.integration, passed: integration == .current, explanation: driver.explanation))
        checks += driver.checks

        let catalogue: Catalogue
        if let earlier, earlier.health != .unavailable {
            catalogue = Catalogue(models: earlier.models, stale: earlier.modelsAreStale,
                                  check: earlier.checks.first { $0.id == .models })
        } else {
            catalogue = await readCatalogue(agent, executable: executable)
        }
        let models = catalogue.models, stale = catalogue.stale
        checks.append(catalogue.check ?? HarnessCheck(
            .models, passed: !models.isEmpty, explanation: models.isEmpty ? agent.harness.noModelsExplanation : nil))
        return .reduce(agent: agent, cliAvailable: true, integrationState: integration,
                                models: models, modelsAreStale: stale, checks: checks)
    }

    /// An agent's models, and the Models check when it is already known: a failed read's, or the
    /// earlier probe's. Otherwise the check follows from whether there are any.
    private struct Catalogue { var models: [AgentModel], stale: Bool, check: HarnessCheck? }

    /// A probe reads afresh: Settings is where a person checks that PI still launches. The CLI was
    /// already located and executable, so a failed launch is a models warning, never an
    /// unavailable card that would hide every action — over the last list read, if there is one.
    private func readCatalogue(_ agent: AgentKind, executable: String) async -> Catalogue {
        let catalogue = self.catalogue
        let reading = (try? await BackgroundWork.run { catalogue.read(agent, executable: executable, refreshing: true) })
            ?? ModelCatalogue.Reading(models: [], failure: .unavailable)
        return Catalogue(models: reading.models, stale: reading.stale,
                         check: reading.explanation.map { HarnessCheck(.models, passed: false, explanation: $0) })
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
        let checks = before.checks.filter { $0.id != .daemon && $0.id != .delivery } + result.checks
        return .reduce(agent: before.agent, cliAvailable: true,
                                integrationState: before.integrationState,
                                models: before.models, modelsAreStale: before.modelsAreStale,
                                checks: checks)
    }
}
