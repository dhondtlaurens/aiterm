import Foundation
import Synchronization
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

extension AppController {
    /// The controller a test builds: the bare home, no bundle — so there is no helper to find
    /// Python for — no login shell to find the agent CLIs, a workspace file nothing else uses, and
    /// no Keychain read for Settings. A test that needs a different one of them names it. A peek
    /// waits no time: a test awaits the one it starts.
    ///
    /// Questions go to a ``ScriptedPrompter`` that answers none, so one a test did not expect fails
    /// it ("Unexpected prompt") rather than opening a modal `NSAlert` that blocks the run. A test
    /// that expects one passes its own. The lookups come last, after `scan`, which is also what
    /// tells this initializer from the designated one.
    convenience init(store: StateStore? = nil, preferences: InterfacePreferences,
                     harnessHome: URL = ScratchHome.bare, bundledResourcesURL: URL? = nil,
                     prompter: Prompter = ScriptedPrompter(),
                     setBadge: @escaping @MainActor (String?) -> Void = { _ in },
                     activateIterm: @escaping @MainActor () -> Void = {}, peekDelay: Duration = .zero,
                     checkoutPollInterval: Duration = .seconds(2), git: any GitRunning = GitRunner.hermetic(),
                     scan: @escaping CheckoutMonitor.Scanner = {
                         WorkspaceScan.run(cwds: $0, projects: $1, tasks: $2, branches: $3, remotes: $4, diffs: $5, defaultBranches: $6)
                     },
                     locateAgents: @escaping @Sendable () -> Set<AgentKind>? = { nil },
                     findPython: @escaping @Sendable () -> URL? = { nil },
                     jiraSettings: @escaping @Sendable () -> JiraConfig? = { nil },
                     gitLabSettings: @escaping @Sendable () -> GitLabConfig? = { nil },
                     gitHubSettings: @escaping @Sendable () -> GitHubConfig? = { nil }) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-test-state-\(UUID().uuidString).json")
        self.init(store: store ?? StateStore(url: scratch), preferences: preferences, harnessHome: harnessHome,
                  bundledResourcesURL: bundledResourcesURL, locateAgents: locateAgents, findPython: findPython,
                  jiraSettings: jiraSettings, gitLabSettings: gitLabSettings, gitHubSettings: gitHubSettings,
                  prompter: prompter, setBadge: setBadge, activateIterm: activateIterm, peekDelay: peekDelay,
                  checkoutPollInterval: checkoutPollInterval, git: git, scan: scan)
    }
}
