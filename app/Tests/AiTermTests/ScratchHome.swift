import Foundation
import Synchronization
@testable import AiTermCore
@testable import AiTerm

/// A home with nothing in it, for whatever a test builds that reads one. The developer's own
/// `~/.claude`, `~/.claude.json` and `~/.codex` say nothing about a test: reading them made a
/// sheet's models and completions whatever this machine has installed. Made once per process, and
/// removed when it exits.
enum ScratchHome {
    static let bare: URL = {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-test-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        created.withLock { $0 = home }
        atexit { ScratchHome.remove() }
        return home
    }()

    /// What an agent with no configuration offers, for a creation model a test builds: Claude's
    /// aliases, and Codex's defaults. PI's is a launch of its CLI, so a test gets none; Grok's reads
    /// the bare home's missing `models_cache.json` and gets none either.
    static let catalogue: @Sendable (AgentKind) -> [AgentModel] = { agent in
        agent == .pi ? [] : ModelCatalog.models(for: agent, home: ScratchHome.bare)
    }

    private static let created = Mutex<URL?>(nil)

    private static func remove() {
        guard let home = created.withLock({ $0 }) else { return }
        try? FileManager.default.removeItem(at: home)
    }
}

extension AppController {
    /// The controller a test builds: the bare home, no bundle — so there is no helper to find
    /// Python for — no login shell to find the agent CLIs, a workspace file nothing else uses, and
    /// no Keychain read for Settings. A test that needs one of them passes it to the designated
    /// initializer. A peek waits no time: a test awaits the one it starts.
    convenience init(store: StateStore? = nil, preferences: InterfacePreferences, prompter: Prompter = ModalPrompter(),
                     setBadge: @escaping @MainActor (String?) -> Void = { _ in },
                     activateIterm: @escaping @MainActor () -> Void = {}, peekDelay: Duration = .zero,
                     checkoutPollInterval: Duration = .seconds(2), git: GitRunner = GitRunner(),
                     scan: @escaping CheckoutMonitor.Scanner = {
                         WorkspaceScan.run(cwds: $0, projects: $1, tasks: $2, branches: $3, remotes: $4, diffs: $5, defaultBranches: $6)
                     }) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-test-state-\(UUID().uuidString).json")
        self.init(store: store ?? StateStore(url: scratch), preferences: preferences, harnessHome: ScratchHome.bare,
                  bundledResourcesURL: nil, locateAgents: { nil }, jiraSettings: { nil }, gitLabSettings: { nil }, gitHubSettings: { nil },
                  prompter: prompter, setBadge: setBadge, activateIterm: activateIterm, peekDelay: peekDelay,
                  checkoutPollInterval: checkoutPollInterval, git: git, scan: scan)
    }
}
