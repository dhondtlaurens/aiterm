import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

extension WorkspaceStore {
    /// A workspace that is never saved — never loaded, so nothing writes its file — holding `state`,
    /// for an owner a test builds without a controller.
    static func holding(_ state: AppState) -> WorkspaceStore {
        let workspace = WorkspaceStore(file: StateStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("aiterm-test-unsaved-\(UUID().uuidString).json")))
        workspace.mutate { $0 = state }
        return workspace
    }
}

extension AppController {
    /// What the workspace file holds once the changes made so far are saved: the save they are
    /// waiting on is made now, as quitting makes it, rather than a moment later.
    func savedWorkspace() throws -> AppState {
        #expect(workspace.flush(), "the workspace saves")
        return try workspace.file.load()
    }

    /// Locks the workspace as a failed save does: a directory stands where the backup goes, so
    /// the next save fails, and a change is saved into it — the sidebar's frame, which no test of
    /// a locked workspace reads.
    func breakSaving() throws {
        let backup = workspace.file.backupURL
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        workspace.mutate { $0.sidebarFrame = CGRect(x: 0, y: 0, width: 1, height: 1) }
        #expect(!workspace.flush(), "saving fails")
        #expect(!canChangeWorkspace)
    }

    /// The controller a test builds: the bare home, no bundle — so there is no helper to find
    /// Python for — no login shell to find the agent CLIs, a workspace file nothing else uses, and
    /// no Keychain read for Settings, and Backpack Mode over the inert ports with its password in
    /// memory — no `sudo`, no Wi-Fi scan, no System Settings. A test that needs a different one of
    /// them names it. A peek waits no time: a test awaits the one it starts.
    ///
    /// Questions go to a ``ScriptedPrompter`` that answers none, so one a test did not expect fails
    /// it ("Unexpected prompt") rather than opening a modal `NSAlert` that blocks the run. A test
    /// that expects one passes its own. The lookups come last, after `scan` and `confirmsRemoval`,
    /// which is also what tells this initializer from the designated one.
    convenience init(store: StateStore? = nil, preferences: InterfacePreferences,
                     harnessHome: URL = ScratchHome.bare, bundledResourcesURL: URL? = nil,
                     prompter: Prompter = ScriptedPrompter(),
                     setBadge: @escaping @MainActor (String?) -> Void = { _ in },
                     activateIterm: @escaping @MainActor () -> Void = {}, backpackPorts: BackpackPorts = .inert,
                     backpackSecrets: any SecretStore = MemorySecretStore(),
                     openLocationSettings: @escaping @MainActor () -> Void = {}, peekDelay: Duration = .zero,
                     checkoutPollInterval: Duration = .seconds(2), toastLifetime: Duration = .seconds(10), git: any GitRunning = GitRunner.hermetic(),
                     scan: @escaping CheckoutMonitor.Scanner = {
                         WorkspaceScan.run(cwds: $0, projects: $1, tasks: $2, branches: $3, remotes: $4, diffs: $5, defaultBranches: $6)
                     },
                     confirmsRemoval: @escaping TaskRemover.ConfirmsRemoval = TaskRemover.diskConfirmsRemoval,
                     locateAgents: @escaping @Sendable () -> Set<AgentKind>? = { nil },
                     findPython: @escaping @Sendable () -> URL? = { nil },
                     jiraSettings: @escaping @Sendable () -> JiraConfig? = { nil },
                     gitLabSettings: @escaping @Sendable () -> GitLabConfig? = { nil },
                     gitHubSettings: @escaping @Sendable () -> GitHubConfig? = { nil }) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-test-state-\(UUID().uuidString).json")
        self.init(store: store ?? StateStore(url: scratch), preferences: preferences, harnessHome: harnessHome,
                  bundledResourcesURL: bundledResourcesURL, locateAgents: locateAgents, findPython: findPython,
                  jiraSettings: jiraSettings, gitLabSettings: gitLabSettings, gitHubSettings: gitHubSettings,
                  prompter: prompter, setBadge: setBadge, activateIterm: activateIterm, backpackPorts: backpackPorts,
                  backpackSecrets: backpackSecrets, openLocationSettings: openLocationSettings, peekDelay: peekDelay,
                  checkoutPollInterval: checkoutPollInterval, toastLifetime: toastLifetime, git: git, scan: scan,
                  confirmsRemoval: confirmsRemoval)
    }
}
