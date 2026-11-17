import Foundation
import AiTermCore

struct OperatorClock: Sendable {
    var now: @Sendable () -> Date = { Date() }
}

struct OperatorPorts {
    var home: URL
    /// Where under `home` Claude keeps its conversations and skills: the app's `ClaudeConfig`, from the login shell.
    var claudeConfig = ClaudeConfig()
    var git: any GitRunning
    var workerGuardExecutable: URL = Bundle.main.executableURL!
    var notifications: any OperatorNotifications
    /// The Oracle's runner.
    var oracle: OracleRunner = .unavailable
    var clock = OperatorClock()
    var now: @Sendable () -> Date { clock.now }
    /// What every owner starts its work through, so that a test waits for all of it at once (`OperatorWork.settled`).
    let work = OperatorWork()
    /// How often the session reconciler looks at the real tabs.
    var reconcileInterval: Duration = .seconds(OperatorTiming.reconcileInterval)
    /// The agents the login shell found, which a task may run: the app's `AgentIntegrations.availableAgents`.
    var installedAgents: @MainActor () -> Set<AgentKind> = { Set(AgentKind.allCases) }
    /// An agent's model list in Settings › Agents (`ModelCatalogue.models(for:)`). Blocking: read through `BackgroundWork`.
    var agentModels: @Sendable (AgentKind) -> [AgentModel] = { _ in [] }
    /// The version each agent CLI installed here reports (`AgentVersions`). Blocking: read through `BackgroundWork`.
    var installedVersions: @Sendable ([AgentKind]) -> [AgentKind: String] = { _ in [:] }
    /// Settings › Operator's current profile (`OperatorProfileStore.load`). Blocking: read
    /// through `BackgroundWork`.
    var profile: @Sendable () -> OperatorProfile = { OperatorProfileStore.load(claudeDefault: OperatorProfileStore.claudeDefault(models: [])) }
    /// The preferences Settings keeps: where each start saves its Agents rows as the last signal's
    /// (`OperatorProfileStore.lastAgents`), where New Signal reads them and Settings › Agents' defaults, and where the
    /// Oracle's settings are read again during a signal.
    var preferences: UserDefaults = .standard

    /// The app's ports: its home, git and Jira, and what Settings › Agents (`agents`) and the app's `preferences` keep.
    @MainActor static func live(home: URL, git: any GitRunning, jiraSettings: @escaping @Sendable () -> JiraConfig?,
                                claudeConfig: ClaudeConfig = ClaudeConfig(), agents: AgentIntegrations,
                                preferences: UserDefaults) -> OperatorPorts {
        var ports = OperatorPorts(home: home, claudeConfig: claudeConfig, git: git, notifications: LiveOperatorNotifications(),
                                  oracle: .live)
        ports.installedVersions = { AgentVersions.shared.current($0) }
        ports.installedAgents = { [weak agents] in agents?.availableAgents ?? [] }
        let catalogue = agents.catalogue
        ports.agentModels = { (try? catalogue.models(for: $0)) ?? [] }
        // Read the Operator's current model, Oracle and standing instructions from its preferences.
        ports.profile = agents.operatorProfile
        ports.preferences = preferences
        return ports
    }
}
