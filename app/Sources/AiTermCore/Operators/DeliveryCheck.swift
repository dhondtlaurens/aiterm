import Foundation
import Synchronization

/// The delivery check's file, `delivery-policy.json`, as `daemon/tools/delivery_check.py` writes it:
/// each CLI's verdict under its name, iTerm2's own under `iterm`. Read whole, so Settings can say what
/// failed (the scenarios) where the helper's `delivery.policy` says only the policy and its version.
public struct DeliveryCheckFile: Equatable, Sendable {
    /// One entry: the version it was checked against, its flags (`pasteSafe` and `submitSafe` for a CLI,
    /// `keystrokesPassThrough` and `backgroundWindow` for iTerm2) and each scenario run, by whether it
    /// passed. A flag or a scenario counts only as a JSON true, as `load_policy` reads one. `checkedAt`
    /// tells one run from the next that found the same. A run that failed names the scenario it
    /// stopped at (`failedAt`) and why, as its window said it (`failure`).
    public struct Entry: Equatable, Sendable {
        public var version: String?
        public var flags: Set<String>
        public var passed: Set<String>
        public var checkedAt: String?
        public var failedAt: String?
        public var failure: String?

        public init(version: String?, flags: Set<String>, passed: Set<String>, checkedAt: String? = nil,
                    failedAt: String? = nil, failure: String? = nil) {
            self.version = version
            self.flags = flags
            self.passed = passed
            self.checkedAt = checkedAt
            self.failedAt = failedAt
            self.failure = failure
        }
    }

    public var entries: [String: Entry]

    /// No file, or one that is not a JSON object: nothing passed.
    public static let missing = DeliveryCheckFile(entries: [:])

    public init(entries: [String: Entry]) { self.entries = entries }

    public init(data: Data?) {
        guard let data, let raw = try? JSONSerialization.jsonObject(with: data), let object = raw as? [String: Any] else {
            self = .missing
            return
        }
        var entries: [String: Entry] = [:]
        for (name, value) in object {
            guard let entry = value as? [String: Any] else { continue }
            let version = (entry["version"] as? String).nonEmpty
            let flags = Set(entry.compactMap { key, value in Self.isTrue(value) ? key : nil })
            let scenarios = entry["scenarios"] as? [String: Any] ?? [:]
            let passed = Set(scenarios.compactMap { key, value in Self.isTrue((value as? [String: Any])?["passed"]) ? key : nil })
            entries[name] = Entry(version: version, flags: flags, passed: passed, checkedAt: entry["checkedAt"] as? String,
                                  failedAt: entry["failedAt"] as? String, failure: entry["failure"] as? String)
        }
        self.entries = entries
    }

    /// A JSON true, and not a number 1 that `JSONSerialization` hands back as the same `NSNumber`.
    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
    }
}

/// What one piece a broadcast needs says about itself: ready, or why not, in one short sentence with no
/// full stop. Settings › Agents shows it on the agent's card; New Broadcast's footer the same words.
public enum DeliveryReadiness: Equatable, Sendable {
    case ready(String)
    case needsAttention(String)

    public var isReady: Bool { if case .ready = self { true } else { false } }
    public var sentence: String {
        switch self {
        case .ready(let sentence), .needsAttention(let sentence): sentence
        }
    }
}

/// The delivery check (`daemon/tools/delivery_check.py`) as the app reads its verdicts: AiTerm types
/// into a CLI only once the check has written a pass for its version, and Settings › Agents shows that
/// as each card's Messaging check, with Run check one click away.
public enum DeliveryCheck {
    /// The CLIs the check covers (its `AGENTS`).
    public static let agents: [AgentKind] = [.claude, .codex]
    /// What each verdict needs, in the check's own order (`PASTE_SAFE`, `SUBMIT_SAFE`, `ITERM_CHECKS`).
    public static let pasteSafeScenarios = ["permissionPaste", "startupPaste", "menuPaste", "updatePaste", "approvalRace"]
    public static let submitSafeScenarios = ["idleSubmit", "multiLine", "busyQueue", "takeover"]
    public static let itermScenarios = ["keystrokesPassThrough", "backgroundWindow"]
    /// iTerm2's entry in the file, beside the CLIs'.
    static let itermEntry = "iterm"

    /// Whether a pass written for `checked` covers the `installed` version, the daemon's own rule
    /// (`delivery.load_policy`): the same major and minor, whatever the patch. A version that is
    /// missing, or not three numbers, is covered by nothing.
    public static func covers(checked: String?, installed: String?) -> Bool {
        guard let checked = parts(checked), let installed = parts(installed) else { return false }
        return checked.major == installed.major && checked.minor == installed.minor
    }

    /// The major and minor a pass covers, as the card names it: `2.1` for 2.1.301.
    public static func versionLine(_ version: String?) -> String? {
        parts(version).map { "\($0.major).\($0.minor)" }
    }

    private static func parts(_ version: String?) -> (major: Int, minor: Int, patch: Int)? {
        guard let version, let match = version.wholeMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3) else { return nil }
        return (major, minor, patch)
    }

    /// Whether `agent`'s workers can be messaged at the `installed` version: a pass covering it, with
    /// paste-safe and submit-safe both true. Nil for an agent the check does not cover.
    public static func messaging(_ agent: AgentKind, file: DeliveryCheckFile, installed: String?) -> DeliveryReadiness? {
        guard agents.contains(agent) else { return nil }
        guard let line = versionLine(installed) else { return .needsAttention("Messaging not checked: version unknown") }
        guard let entry = file.entries[agent.rawValue], covers(checked: entry.version, installed: installed) else {
            return .needsAttention("Messaging not checked for \(line)")
        }
        if entry.flags.isSuperset(of: ["pasteSafe", "submitSafe"]) { return .ready("Messaging ready for \(line)") }
        // The run stopped there: the scenarios after it were never reached.
        if let failedAt = entry.failedAt { return .needsAttention("Messaging failed: \(failedAt)") }
        let failed = (pasteSafeScenarios + submitSafeScenarios).filter { !entry.passed.contains($0) }
        return .needsAttention(failed.isEmpty ? "Messaging failed for \(line)" : "Messaging failed: \(named(failed))")
    }

    /// Why `agent`'s last run failed, as its window said it, while that run is the verdict the card
    /// shows: nil once it passed, for a version it does not cover, and for a file written before
    /// runs kept a reason.
    public static func failure(_ agent: AgentKind, file: DeliveryCheckFile, installed: String?) -> String? {
        guard messaging(agent, file: file, installed: installed)?.isReady == false,
              let entry = file.entries[agent.rawValue], covers(checked: entry.version, installed: installed) else { return nil }
        return entry.failure
    }

    /// iTerm2's own checks, run once whatever the agent: the keystroke monitor and a window behind.
    public static func iterm(_ file: DeliveryCheckFile) -> DeliveryReadiness {
        guard let entry = file.entries[itermEntry] else { return .needsAttention("iTerm2 checks not run") }
        if entry.flags.isSuperset(of: itermScenarios) { return .ready("iTerm2 checks passed") }
        let failed = itermScenarios.filter { !entry.passed.contains($0) || !entry.flags.contains($0) }
        return .needsAttention("iTerm2 checks failed: \(named(failed))")
    }

    /// The first failure, and how many more: the sentence stays short, and the check's window has the rest.
    private static func named(_ failed: [String]) -> String {
        failed.count > 1 ? "\(failed[0]) and \(failed.count - 1) more" : failed[0]
    }

    /// What Run check types into its window, opened in `daemonDir`: the check for `agent` alone, its
    /// verdict written into the policy file, with the helper's own Python and package as the helper
    /// itself is started (`DaemonSupervisor.daemonEnvironment`). iTerm2's own checks run with it until
    /// the file holds a pass for them. The window closes once the check has written its verdict, which
    /// the card then shows; one that crashed stays open on its traceback.
    public static func command(agent: AgentKind, file: DeliveryCheckFile, python: URL, daemonDir: URL) -> String {
        var command = "env PYTHONPATH=\(AgentCommand.shellQuote(daemonDir.path)) PYTHONDONTWRITEBYTECODE=1 "
            + "\(AgentCommand.shellQuote(python.path)) -m tools.delivery_check --agents \(agent.rawValue) --write"
        if iterm(file).isReady { command += " --skip-iterm" }
        return command + " && exit"
    }
}

/// The policy file, looked at again and again: whether it changed since the last look, by its stamp
/// (inode, modification time, size), so a check run by hand reaches Settings without a read per look.
public final class DeliveryCheckWatch: Sendable {
    private let url: URL
    private struct Seen { var looked = false; var stamp: FileStamps.Stamp? }
    private let seen = Mutex(Seen())

    public init(url: URL) { self.url = url }

    /// The file as it is now, when it changed since the last call — the first call always answers —
    /// and nil when it did not. Blocking: call it off the main actor.
    public func changed() -> DeliveryCheckFile? {
        let stamp = FileStamps.stamp(url.path)
        let fresh = seen.withLock { seen in
            defer { seen = Seen(looked: true, stamp: stamp) }
            return !seen.looked || seen.stamp != stamp
        }
        return fresh ? DeliveryCheckFile(data: try? Data(contentsOf: url)) : nil
    }

    /// Forgets the last look, so the next answers whatever the stamp: a window closing may follow a
    /// write within the stamp's resolution.
    public func forget() { seen.withLock { $0 = Seen() } }
}
