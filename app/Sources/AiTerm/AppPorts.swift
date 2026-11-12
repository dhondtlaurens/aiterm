import Foundation
import AiTermCore

/// Everything an `AppController` reaches outside the process: the state file, the person's home and Claude's folder,
/// the app's bundle, the agent CLIs and Python found on this machine, the connections Settings saved, the modal alerts,
/// the Dock badge, iTerm2 started and handed focus, Backpack Mode's ports and secrets, the Mac's load, git, the checkout
/// monitor's reading of the disk and its last look at a checkout gone, the operators' ports and the banner's Fix. Nothing
/// has a default: the app builds them with `AppController.live`, the snapshots with `live` and a few of their own, and a
/// test with the scratch ones in its target, which touch none of them.
///
/// `backpackPorts` are everything Backpack Mode touches — `sudo pmset`, Wi-Fi, the battery, Location, the lid — and
/// `backpackSecrets` where it keeps the hotspot's password; `openLocationSettings` is where its Allow… sends the person
/// once macOS will not ask. `machineSensor` reads the Mac's load for the footer; the battery is `backpackPorts.power`.
/// `bringForward` brings AiTerm forward for Remove's question about a window the person closed; `launchIterm` starts
/// iTerm2 when AiTerm starts while `itermRunning` says it is not, and when a row is chosen while it is away.
/// `confirmsRemoval` is the last look at a checkout the monitor found gone (`TaskRemover`). `operatorPorts` are what the
/// operators reach: run folders, the agents' home, notifications; nil is the app's own (`OperatorPorts.live`), from
/// `harnessHome`, `git`, `jiraSettings` and Settings › Agents. `fixPipeline` is what the banner's and New Review's Fix
/// run for a project; nil is the live pipeline — a clone, the agent, AiTerm's landing.
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
    var bringForward: @MainActor () -> Void
    var backpackPorts: BackpackPorts
    var backpackSecrets: any SecretStore
    var openLocationSettings: @MainActor () -> Void
    var machineSensor: any MachineSensor
    var git: any GitRunning
    var scan: CheckoutMonitor.Scanner
    var confirmsRemoval: TaskRemover.ConfirmsRemoval
    var operatorPorts: OperatorPorts?
    var fixPipeline: (@MainActor (Project) -> FixPipeline)?
}

/// How long the controller's owners wait, and against what clock: `peekDelay` is `RowFocus`'s (a test passes none, and
/// awaits the peek instead); `checkoutPollInterval` the pause between the checkout monitor's passes; `toastLifetime` how
/// long a completion toast stays up; `closedWindowHold` and `now` how long, and against what clock, a closed task
/// window is held before Remove's question (`ClosedWindowTriage`).
struct AppTimings {
    var peekDelay: Duration
    var checkoutPollInterval: Duration
    var toastLifetime: Duration
    var closedWindowHold: Duration
    var now: @MainActor () -> ContinuousClock.Instant

    /// The app's own.
    static let live = AppTimings(peekDelay: .milliseconds(120), checkoutPollInterval: .seconds(2), toastLifetime: .seconds(10),
                                 closedWindowHold: ClosedWindowTriage.hold, now: { .now })
}
