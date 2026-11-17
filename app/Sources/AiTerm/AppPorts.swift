import Foundation
import AiTermCore

/// Everything an `AppController` reaches outside the process: the state file, the person's home and Claude's folder,
/// the app's bundle, the agent CLIs and Python found on this machine, the connections Settings saved, the modal alerts,
/// the Dock badge, iTerm2 started and handed focus, Backpack Mode's ports and secrets, the Mac's load, git, the checkout
/// monitor's reading of the disk, and the operators' ports. Nothing
/// has a default: the app builds them with `AppController.live`, the snapshots with `live` and a few of their own, and a
/// test with the scratch ones in its target, which touch none of them.
///
/// `backpackPorts` are everything Backpack Mode touches — `sudo pmset`, Wi-Fi, the battery, Location, the lid — and
/// `backpackSecrets` where it keeps the hotspot's password; `openLocationSettings` is where its Allow… sends the person
/// once macOS will not ask. `machineSensor` reads the Mac's load for the footer; the battery is `backpackPorts.power`.
/// `launchIterm` starts iTerm2 when AiTerm starts while `itermRunning` says it is not, and when a row is chosen while it is away.
/// `operatorPorts` are what the Operator reaches: its folder, the agents' home, notifications;
/// nil is the app's own (`OperatorPorts.live`), from
/// `harnessHome`, `git`, `jiraSettings` and Settings › Agents.
struct AppPorts {
    var store: StateStore
    var harnessHome: URL
    var claudeConfig: ClaudeConfig
    var bundledResourcesURL: URL?
    var locateAgents: @Sendable () -> Set<AgentKind>?
    var findPython: @Sendable () -> URL?
    var jiraSettings: @Sendable () -> JiraConfig?
    var gitLabSettings: @Sendable () -> GitLabConfig?
    var gitHubSettings: @Sendable () -> GitHubConfig?
    var prompter: Prompter
    var setBadge: @MainActor (String?) -> Void
    var activateIterm: @MainActor () -> Void
    var launchIterm: @MainActor () -> Void
    var itermRunning: @MainActor () -> Bool
    var backpackPorts: BackpackPorts
    var backpackSecrets: any SecretStore
    var openLocationSettings: @MainActor () -> Void
    var machineSensor: any MachineSensor
    var git: any GitRunning
    var scan: CheckoutMonitor.Scanner
    var operatorPorts: OperatorPorts?
}

/// How long the controller's owners wait: `peekDelay` is `RowFocus`'s (a test passes none, and
/// awaits the peek instead); `checkoutPollInterval` the pause between the checkout monitor's passes; `toastLifetime` how
/// long a completion toast stays up.
struct AppTimings {
    var peekDelay: Duration
    var checkoutPollInterval: Duration
    var toastLifetime: Duration
    var connectionGrace: Duration

    /// The app's own.
    static let live = AppTimings(peekDelay: .milliseconds(120), checkoutPollInterval: .seconds(2), toastLifetime: .seconds(10),
                                 connectionGrace: .seconds(10))
}
