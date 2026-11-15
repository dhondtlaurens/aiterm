import Foundation
import AiTermCore

struct OperatorClock: Sendable {
    enum Wait: Sendable, Equatable { case wake, summary, prompt, merge }

    var now: @Sendable () -> Date = { Date() }
    var sleep: @MainActor @Sendable (Wait, Duration) async throws -> Void = { _, duration in
        try await Task.sleep(for: duration)
    }
}

struct OperatorPorts {
    var home: URL
    /// Where under `home` Claude keeps its conversations and skills: the app's `ClaudeConfig`, from the login shell.
    var claudeConfig = ClaudeConfig()
    var git: any GitRunning
    var workerGuardExecutable: URL = Bundle.main.executableURL!
    var notifications: any OperatorNotifications
    /// The Jira client `jira_search` runs through, while Settings has one.
    /// How long `jira_search` waits for Jira before it answers that Jira didn't (`OperatorTiming.jiraSearchBudget`).
    var jiraSearchBudget: Duration = .seconds(OperatorTiming.jiraSearchBudget)
    /// The Oracle's runner.
    var secondOpinion: SecondOpinionRunner = .unavailable
    /// How long a challenged call waits for its critique before answering that it is still coming: well
    /// inside the daemon's `operatorRequestTimeout`, which the challenge's own limit is not.
    var challengeReplyBudget: Duration = .seconds(20)
    /// How long after a `finish_task` reached the app it answers, its publication done or not (`OperatorTiming.finishReplyBudget`).
    var finishReplyBudget: Duration = .seconds(OperatorTiming.finishReplyBudget)
    var clock = OperatorClock()
    var now: @Sendable () -> Date { clock.now }
    /// What every owner starts its work through, so that a test waits for all of it at once (`OperatorWork.settled`).
    let work = OperatorWork()
    /// The version of AiTerm that is running, for the snags the Operator reports: "dev" for a build with none.
    var appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    /// How long a burst of changes is gathered into one wake line.
    var wakeCoalesce: Duration = .seconds(OperatorTiming.wakeCoalesce)
    /// How often the run reconciler looks at the real tabs.
    var reconcileInterval: Duration = .seconds(OperatorTiming.reconcileInterval)
    /// The code host a project's requests are published on, with the connections Settings saved (G10):
    /// `remote` is origin's, the repository the push goes to. The tokens stay in the clients.
    var publisher: @Sendable (RemoteInfo) throws -> any MergeRequestPublishing = { remote in
        try MergeRequestPublisher.publisher(for: remote, gitLab: GitLabSettings.load(), gitHub: GitHubSettings.load())
    }
    /// How long the host's view of a task's request is waited for (`OperatorTiming.hostReadTimeout`) and kept (`hostReadCache`):
    /// what `run_status` and `read_task` show of each request.
    var hostTimeout: Duration = .seconds(OperatorTiming.hostReadTimeout)
    var hostCache: TimeInterval = OperatorTiming.hostReadCache
    /// The agents the login shell found, which a task may run (spec §15): the app's `AgentIntegrations.availableAgents`.
    var installedAgents: @MainActor () -> Set<AgentKind> = { Set(AgentKind.allCases) }
    /// An agent's model list in Settings › Agents (`ModelCatalogue.models(for:)`). Blocking: read through `BackgroundWork`.
    var agentModels: @Sendable (AgentKind) -> [AgentModel] = { _ in [] }
    /// The version each agent CLI installed here reports (`AgentVersions`). Blocking: read through `BackgroundWork`.
    var installedVersions: @Sendable ([AgentKind]) -> [AgentKind: String] = { _ in [:] }
    /// Settings › Operator's profile, as a new broadcast freezes it (`OperatorProfileStore.load`). Blocking: read
    /// through `BackgroundWork`.
    var profile: @Sendable () -> OperatorProfile = { OperatorProfileStore.load(claudeDefault: OperatorProfileStore.claudeDefault(models: [])) }
    /// The preferences Settings keeps: where each start saves its Agents rows as the last broadcast's
    /// (`OperatorProfileStore.lastAgents`), where New Broadcast reads them and Settings › Agents' defaults, and where the
    /// Oracle's settings are read again during a broadcast.
    var preferences: UserDefaults = .standard

    /// The app's ports: its home, git and Jira, and what Settings › Agents (`agents`) and the app's `preferences` keep.
    @MainActor static func live(home: URL, git: any GitRunning, jiraSettings: @escaping @Sendable () -> JiraConfig?,
                                claudeConfig: ClaudeConfig = ClaudeConfig(), agents: AgentIntegrations,
                                preferences: UserDefaults) -> OperatorPorts {
        var ports = OperatorPorts(home: home, claudeConfig: claudeConfig, git: git, notifications: LiveOperatorNotifications(),
                                  secondOpinion: .live)
        ports.installedVersions = { AgentVersions.shared.current($0) }
        ports.installedAgents = { [weak agents] in agents?.availableAgents ?? [] }
        let catalogue = agents.catalogue
        ports.agentModels = { (try? catalogue.models(for: $0)) ?? [] }
        // A broadcast freezes Settings › Operator's profile as these preferences keep it.
        ports.profile = agents.operatorProfile
        ports.preferences = preferences
        return ports
    }
}
