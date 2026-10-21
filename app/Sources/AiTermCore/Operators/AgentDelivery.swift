import Foundation
import Synchronization

/// Whether the Operator can message an agent's workers (`message_task`), as `run_status` says it before
/// anything is planned on that agent: the delivery check's verdict (`DeliveryVerdict`) held against the
/// version installed. The daemon types into a session only while its CLI runs a version the check's pass
/// covers, the same major and minor (`DeliveryCheck.covers`), so an agent that moved to a new minor since
/// gets nothing, and the Operator would otherwise find out only when its first steer is refused, with the
/// task already started.
public struct AgentDelivery: Encodable, Equatable, Sendable {
    /// `auto` delivers, `pasteOnly` pastes and leaves the Enter to the person, `off` types nothing.
    public var messaging: DeliveryPolicy
    /// What the agent's `--version` says here; nil when it couldn't be read.
    public var installedVersion: String?
    /// The version the delivery check vouches for; nil when it passed none.
    public var checkedVersion: String?
    /// Why, when it isn't plain `auto`.
    public var note: String?

    public init(messaging: DeliveryPolicy, installedVersion: String?, checkedVersion: String?, note: String?) {
        self.messaging = messaging; self.installedVersion = installedVersion; self.checkedVersion = checkedVersion; self.note = note
    }

    /// `agent`'s delivery, from the daemon's `verdict` (nil: it named none) and the `installed` version.
    public static func of(_ agent: AgentKind, verdict: DeliveryVerdict?, installed: String?) -> AgentDelivery {
        let name = agent.harness.displayName, named = installed.map { "\(name) \($0)" } ?? name
        guard let verdict, let checked = verdict.version else {
            return AgentDelivery(messaging: .off, installedVersion: installed, checkedVersion: nil,
                                 note: "AiTerm's delivery check hasn't passed \(named).")
        }
        func delivery(_ messaging: DeliveryPolicy, _ note: String?) -> AgentDelivery {
            AgentDelivery(messaging: messaging, installedVersion: installed, checkedVersion: checked, note: note)
        }
        if verdict.policy == .off { return delivery(.off, "AiTerm's delivery check didn't pass \(name) \(checked).") }
        let line = DeliveryCheck.versionLine(checked).map { "\($0).x" } ?? checked
        guard let installed else {
            return delivery(verdict.policy, "AiTerm couldn't read which \(name) version is installed: its workers can be messaged only while it is \(line).")
        }
        if !DeliveryCheck.covers(checked: checked, installed: installed) {
            return delivery(.off, "\(name) \(installed) is installed, but AiTerm's delivery check covers \(line) only.")
        }
        return delivery(verdict.policy, verdict.policy == .pasteOnly
                        ? "Messages to its workers are pasted without Enter: the person presses Enter to send each one." : nil)
    }
}

/// The version each agent CLI installed on this Mac reports: its `--version`, asked in the login shell,
/// which has the `PATH` a Node-run CLI needs, the way the delivery check reads it
/// (`daemon/tools/delivery_check.py`). One shell asks every agent at once, and is asked again only once
/// an agent's executable has changed, as an update changes it: `run_status` reads it often.
public final class AgentVersions: Sendable {
    /// The app's, over the locator Settings and the New Task sheet go by.
    public static let shared = AgentVersions()

    private let executables: @Sendable () -> [String: String]?
    private let shell: @Sendable (String) -> String?
    private struct Known { var stamps: FileStamps?; var versions: [AgentKind: String] = [:] }
    private let known = Mutex(Known())

    /// `executables` is each CLI's path by its executable's name (`LoginShellLocator.Answers.executables`),
    /// nil when the login shell couldn't say; `shell` runs a command in the login shell (`LoginShell.run`).
    public init(executables: @escaping @Sendable () -> [String: String]? = { LoginShellLocator.shared.current()?.executables },
                shell: @escaping @Sendable (String) -> String? = { LoginShell.run($0) }) {
        self.executables = executables
        self.shell = shell
    }

    /// Each of `agents` whose version was read. Blocking: call it off the main actor.
    public func current(_ agents: [AgentKind]) -> [AgentKind: String] {
        guard let executables = executables() else { return [:] }
        let paths = agents.compactMap { agent in executables[agent.harness.executable].map { (agent, $0) } }
        guard !paths.isEmpty else { return [:] }
        // An update relinks or rewrites the file a path resolves to.
        let stamps = FileStamps(paths.map { URL(fileURLWithPath: $0.1).resolvingSymlinksInPath().path })
        if let kept = known.withLock({ $0.stamps == stamps ? $0.versions : nil }) { return kept }
        let query = paths.map { agent, path in
            "printf '%s\\t' \(agent.rawValue); \(AgentCommand.shellQuote(path)) --version 2>/dev/null | head -n 1; echo"
        }.joined(separator: "; ") + "; true"
        // A shell that failed is kept as none read too: run_status asks often, and a login shell costs a second.
        let versions = shell(query).map(Self.versions(in:)) ?? [:]
        known.withLock { $0 = Known(stamps: stamps, versions: versions) }
        return versions
    }

    /// The `agent<TAB>output` lines of `output`, each read for the version it names: `2.1.301 (Claude Code)`,
    /// `codex-cli 0.160.0`. An rc file's banner, or an agent that printed none, is left out.
    static func versions(in output: String) -> [AgentKind: String] {
        var found: [AgentKind: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, let agent = AgentKind(rawValue: String(fields[0])), found[agent] == nil,
                  let version = fields[1].firstMatch(of: /\d+\.\d+\.\d+/) else { continue }
            found[agent] = String(version.output)
        }
        return found
    }
}
