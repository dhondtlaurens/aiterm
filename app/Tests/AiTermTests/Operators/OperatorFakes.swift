import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

enum OperatorServiceFixtures {
    /// The test Operator profile: Claude on Opus, with the Oracle off unless requested.
    static func profile(oracle: Bool = false, oracleAgent: AgentKind = .codex) -> OperatorProfile {
        OperatorProfile(model: "claude-opus-5-5", reasoning: "high",
                        oracle: OracleSetting(isOn: oracle, agent: oracleAgent, model: oracleAgent == .codex ? "gpt-6-astra" : "claude-opus-5-5",
                                              reasoning: "medium"),
                        instructions: "You are careful.")
    }

    static func project(path: String = "/tmp/aiterm-operators-none", name: String = "Shop", jira: [JiraProjectRef] = []) -> Project {
        .make(name: name, path: path, jiraProjects: jira)
    }



    /// Agents rows on the scratch ports' model lists: Claude's first model, then Codex's.
    static let agents = Build.agents





    /// A tab tagged with `tag`: a task's id, or the session's id for the Operator's own tab.
    static func session(_ id: String, window: String = "w1", tag: UUID, agent: SessionAgent = .claude, state: SessionState = .idle,
                        conversation: String? = nil, cwd: String = "/") -> SessionInfo {
        .make(id, window: window, task: tag, agent: agent, state: state, cwd: cwd, conversation: conversation)
    }

    /// Each agent's model list in Settings › Agents, as the scratch ports give it.
    static let models: [AgentKind: [AgentModel]] = [
        .claude: [AgentModel(id: "claude-opus-5-5", label: "Opus", detail: nil, efforts: ["high"], defaultEffort: "high"),
                  AgentModel(id: "claude-named", label: "Named", detail: nil, efforts: [], defaultEffort: nil),
                  AgentModel(id: "claude-other", label: "Other", detail: nil, efforts: [], defaultEffort: nil)],
        .codex: [AgentModel(id: "gpt-6-astra", label: "Astra", detail: nil, efforts: ["medium"], defaultEffort: "medium"),
                 AgentModel(id: "gpt-6-mini", label: "Mini", detail: nil, efforts: [], defaultEffort: nil)],
    ]


}

/// Notifications posted, in order, instead of macOS's: a test host has no notification centre.
@MainActor
final class RecordingNotifications: OperatorNotifications {
    private(set) var posted: [OperatorNote] = []
    /// The ids taken back, in order.
    private(set) var withdrawn: [String] = []
    private(set) var authorizationRequests = 0
    /// What an earlier run of AiTerm left showing, as the launch's reading of the centre finds it.
    var delivered: [String] = []
    func readDelivered() async -> [String] { delivered }
    var onOpen: (@MainActor (OperatorNote.Target) -> Void)?
    func requestAuthorization() { authorizationRequests += 1 }
    func post(_ note: OperatorNote) { posted.append(note) }
    func withdraw(ids: [String]) { withdrawn += ids }
}

extension TestClock {
    /// The shared Operator wall clock, a test moves by hand.
    static func operators() -> TestClock { TestClock(Date(timeIntervalSince1970: 1_000_000)) }
}

extension ItemRouter {
    @discardableResult func apply(signals ids: [UUID], read: SignalRead) -> [UUID] {
        apply(observations: [SignalObservation(signals: ids, read: read)])
    }
}

extension OperatorWork {
    /// Returns once no more than `count` of the tasks started here are running — none, by default: everything the Operator's
    /// owners started has ended, the work that work started included. `count` leaves the ones a test holds on purpose (a
    /// delivery held by the daemon) running. Work still running at `TestDeadline` is an issue, never a hang.
    func settled(leaving count: Int = 0, sourceLocation: SourceLocation = #_sourceLocation) async {
        await eventually(describing: "the Operator's work to end, \(running) still running", every: .milliseconds(1),
                         sourceLocation: sourceLocation) { running <= count }
    }
}

extension OperatorPorts {
    /// Ports that reach nothing real: a fresh temporary home for the agents' conversations,
    /// recorded notifications and hermetic git.
    @MainActor static func scratch(notifications: RecordingNotifications = RecordingNotifications(),
                                   git: any GitRunning = GitRunner.hermetic()) -> OperatorPorts {
        let home = ScratchFolder.path("aiterm-operators-")
        var ports = OperatorPorts(home: home, git: git, notifications: notifications)
        // Both agents installed, each with a short model list of its own, so no test reads this Mac's.
        ports.installedAgents = { [.claude, .codex] }
        ports.agentModels = { OperatorServiceFixtures.models[$0] ?? [] }
        // The versions the recording daemon's delivery check vouches for, never this Mac's `--version`.
        ports.installedVersions = { agents in [AgentKind: String](uniqueKeysWithValues: agents.compactMap { agent in
            ([.claude: "2.1.301", .codex: "0.160.0"] as [AgentKind: String])[agent].map { (agent, $0) } }) }
        // Settings › Operator's profile, never this Mac's, and preferences of the test's own.
        ports.profile = { OperatorServiceFixtures.profile() }
        let defaults = ScratchDefaults.make()
        for (agent, models) in OperatorServiceFixtures.models {
            if let first = models.first {
                ModelSettings.save(ModelPreference(model: first.id, reasoning: first.defaultEffort), for: agent, defaults: defaults)
            }
        }
        ports.preferences = defaults
        return ports
    }
}

extension WorkspaceStore {
    /// A loaded workspace holding `state`, saved to a file nothing else uses. The Operator's launch waits for its save.
    static func saving(_ state: AppState) throws -> WorkspaceStore {
        let store = WorkspaceStore(file: StateStore(url: ScratchFolder.path("aiterm-operators-state-", suffix: ".json")))
        try store.load()
        store.mutate { $0 = state }
        return store
    }
}


final class HeldGit: GitRunning, @unchecked Sendable {
    let reads = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        reads.continuation.yield(())
        release.wait()
        return "new-sha"
    }
}

func guardedWorkerCommand(_ line: String?) throws -> String? {
    guard let line, line.hasPrefix("/bin/sh '") && line.hasSuffix("'") else { return line }
    let path = String(line.dropFirst(9).dropLast()).replacingOccurrences(of: "'\"'\"'", with: "'")
    return try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "export GIT_CONFIG_COUNT PATH\n").last?.trimmingCharacters(in: .newlines)
}
