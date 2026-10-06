import Foundation

public enum HarnessHealth: String, Equatable, Sendable {
    case ready
    case warning
    case unavailable
}

public enum HarnessIntegrationState: Equatable, Sendable {
    case notChecked
    case missing
    case current
    case outdated
    case invalidOwned
    case foreign
    case unreadable
    case resourceUnavailable
}

/// What a card's check is about. Core and the app filter, replace and order checks by it, so it is
/// a type: a misspelt id does not compile, and each check's label is said once.
public enum HarnessCheckID: String, Sendable {
    case cli, integration, models, daemon, delivery, context, operation
    case selectedModel = "selected-model"

    /// The name the card gives the check. The UI calls every harness's integration a driver:
    /// hooks for Claude, Codex and Grok, an extension for PI — the same job, so one word.
    public var label: String {
        switch self {
        case .cli: return "CLI"
        case .integration: return "Driver"
        case .models: return "Models"
        case .daemon: return "Helper"
        case .delivery: return "Status delivery"
        case .context: return "Context"
        case .operation: return "Setup"
        case .selectedModel: return "Default model"
        }
    }
}

public struct HarnessCheck: Equatable, Sendable {
    public var id: HarnessCheckID
    public var passed: Bool
    public var explanation: String?
    /// Whether Install can put this check right when it fails. Grok's Context check cannot: a
    /// status line AiTerm must not touch stays as it is however many times Install runs.
    public var repairable: Bool

    public var label: String { id.label }

    public init(_ id: HarnessCheckID, passed: Bool, explanation: String?, repairable: Bool = true) {
        self.id = id
        self.passed = passed
        self.explanation = explanation
        self.repairable = repairable
    }
}

public struct HarnessSnapshot: Equatable, Sendable {
    public var agent: AgentKind
    public var health: HarnessHealth
    public var summary: String
    public var checks: [HarnessCheck]
    public var models: [AgentModel]
    public var modelsAreStale: Bool
    public var integrationState: HarnessIntegrationState

    public init(agent: AgentKind, health: HarnessHealth, summary: String, checks: [HarnessCheck],
                models: [AgentModel], modelsAreStale: Bool,
                integrationState: HarnessIntegrationState) {
        self.agent = agent
        self.health = health
        self.summary = summary
        self.checks = checks
        self.models = models
        self.modelsAreStale = modelsAreStale
        self.integrationState = integrationState
    }

    /// Install writes AiTerm's own driver whether it is absent, current or damaged, so a working
    /// installation can always be overwritten. A foreign or unreadable file is never ours to replace.
    /// A missing CLI can always be installed: the vendor's installer runs first, then the driver.
    public var canInstall: Bool {
        if health == .unavailable { return true }
        switch integrationState {
        case .missing, .current, .outdated, .invalidOwned: return true
        default: return false
        }
    }
}

public extension HarnessSnapshot {
    /// A current driver whose only failed checks are ones Install cannot fix: running it would
    /// write nothing and the card would come back as amber as before.
    var installChangesNothing: Bool {
        guard health != .unavailable, integrationState == .current else { return false }
        let failed = checks.filter { !$0.passed }
        return !failed.isEmpty && failed.allSatisfy { !$0.repairable }
    }

    static func reduce(agent: AgentKind, cliAvailable: Bool,
                       integrationState: HarnessIntegrationState,
                       models: [AgentModel], modelsAreStale: Bool = false,
                       checks: [HarnessCheck] = []) -> HarnessSnapshot {
        let failedExplanation = checks.first { !$0.passed && !($0.explanation ?? "").isEmpty }?.explanation
        let health: HarnessHealth
        if !cliAvailable {
            health = .unavailable
        } else if integrationState != .current || checks.contains(where: { !$0.passed })
                    || models.isEmpty || modelsAreStale {
            health = .warning
        } else {
            health = .ready
        }

        let summary = failedExplanation ?? defaultSummary(agent: agent, health: health,
                                                          integrationState: integrationState,
                                                          models: models,
                                                          modelsAreStale: modelsAreStale)
        return HarnessSnapshot(agent: agent, health: health, summary: summary, checks: checks,
                               models: models, modelsAreStale: modelsAreStale,
                               integrationState: integrationState)
    }

    private static func defaultSummary(agent: AgentKind, health: HarnessHealth,
                                       integrationState: HarnessIntegrationState,
                                       models: [AgentModel], modelsAreStale: Bool) -> String {
        if health == .unavailable { return "\(agent.displayName) CLI is unavailable." }
        if let explanation = DriverProbe(integrationState).explanation { return explanation }
        if modelsAreStale { return "The model catalogue couldn’t be refreshed." }
        if models.isEmpty { return agent.harness.noModelsExplanation }
        return "Ready."
    }
}

/// What the drivers install from the app bundle, and whether this copy of AiTerm may install them.
public struct HarnessResources: Equatable, Sendable {
    /// Each harness's bundled resource as its driver takes it (`Harness.bundledResource`): a
    /// shim's path, the PI extension's source. An agent missing here has no driver to install,
    /// unless its driver needs nothing from the bundle (Codex's).
    private var resources: [AgentKind: String]
    public var installationAllowed: Bool
    public var unavailableReason: String?

    public init(_ resources: [AgentKind: String], installationAllowed: Bool, unavailableReason: String?) {
        self.resources = resources
        self.installationAllowed = installationAllowed
        self.unavailableReason = unavailableReason
    }

    public subscript(agent: AgentKind) -> String? { resources[agent] }

    /// The resources of `agents` — every agent's, unless a caller needs only some: the PI
    /// extension's is a file read, where a script's is a look at its permissions.
    public static func bundled(resourceURL: URL? = Bundle.main.resourceURL,
                               for agents: [AgentKind] = AgentKind.allCases) -> HarnessResources {
        guard let resourceURL else {
            return HarnessResources([:], installationAllowed: false, unavailableReason: "AiTerm’s bundled drivers are unavailable.")
        }
        let hooks = resourceURL.appendingPathComponent("hooks")
        var resources: [AgentKind: String] = [:]
        for agent in agents { resources[agent] = agent.harness.bundledResource?.load(fromHooks: hooks) }
        let translocated = BundleLocation.isTranslocated(resourceURL.path)
        return HarnessResources(resources, installationAllowed: !translocated,
                                unavailableReason: translocated ? BundleLocation.translocationWarning : nil)
    }
}
