import Foundation

/// What AiTerm merges into Antigravity's global `~/.gemini/config/hooks.json`: one named hook,
/// `aiterm`, beside whatever else is there. Antigravity runs every named hook of an event in turn,
/// so the person's own hooks and a plugin's stay as they are, and the whole `aiterm` entry is ours.
///
/// It registers `SessionStart`, `PreInvocation` and `Stop` only. A `PreToolUse` hook would be
/// read as a permission decision, and one that answers `{}` denies the tool
/// (docs/research/2026-11-26-antigravity-cli.md). Each handler posts the hook's stdin to the daemon
/// with the tab's `ITERM_SESSION_ID`, waiting at most a second, and answers `{}`. The post is not
/// sent in the background: Antigravity may stop a hook's process group once it answers, and the
/// daemon is local, so the wait costs milliseconds.
enum AgyHooks {
    static let path = ".gemini/config/hooks.json"
    /// The named hook AiTerm owns.
    static let name = "aiterm"
    static let events = ["SessionStart", "PreInvocation", "Stop"]

    static func command(hookURL: String) -> String {
        "curl -s -m 1 -o /dev/null -X POST -H 'Content-Type: application/json' -H 'X-AiTerm-Hook: 1' "
            + "-H \"X-AiTerm-iTerm-Session: $ITERM_SESSION_ID\" -H 'Expect:' --data-binary @- \(hookURL); echo '{}'"
    }

    /// The `aiterm` entry an install writes: each event a flat list of one command handler.
    static func entry(hookURL: String) -> [String: Any] {
        let handler: [String: Any] = ["type": "command", "command": command(hookURL: hookURL), "timeout": 5]
        return Dictionary(uniqueKeysWithValues: events.map { ($0, [handler]) })
    }

    struct Unmergeable: Error, Equatable { let reason: String }

    /// The file as an object: no bytes, or none at all, is "no hooks yet"; anything else that is
    /// not a JSON object is refused, never merged as if empty.
    static func mergeable(_ json: Data?) throws(Unmergeable) -> [String: Any] {
        guard let json, !json.isEmpty else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw Unmergeable(reason: "is not a JSON object")
        }
        return object
    }

    static func state(_ hooks: [String: Any], hookURL: String) -> HarnessIntegrationState {
        guard let owned = hooks[name] else { return .missing }
        return (owned as? NSDictionary) == (entry(hookURL: hookURL) as NSDictionary) ? .current : .outdated
    }

    static func merge(_ json: Data?, hookURL: String) throws -> Data {
        var hooks = try mergeable(json)
        hooks[name] = entry(hookURL: hookURL)
        return try JSONSerialization.data(withJSONObject: hooks, options: ClaudeSettings.jsonOptions)
    }
}

/// What AiTerm sets in Antigravity's `~/.gemini/antigravity-cli/settings.json`: its `statusLine`,
/// which runs AiTerm's shim (`hooks/agy-statusline-shim.sh`). The shim posts each payload and runs the
/// person's own status line, which the install sets aside (`StatusLineOriginal`, Antigravity's own
/// record). Only `type` and `command` are AiTerm's; `padding` and the rest ride along. With no status
/// line of the person's, `stack_with_default` keeps Antigravity's own line drawn above the shim's
/// empty one, unless the person has said otherwise.
enum AgyStatusLine {
    static let path = ".gemini/antigravity-cli/settings.json"

    /// Our shim, by its file name as well as its path: a moved app bundle leaves the old path behind.
    static func isOurShim(_ command: String, shimPath: String) -> Bool {
        ClaudeSettings.isOurShim(command, shimPath: shimPath)
    }

    private static func line(_ settings: [String: Any]) -> [String: Any]? { settings["statusLine"] as? [String: Any] }

    /// The settings as an object, or why they cannot be merged into: not an object, or a `statusLine`
    /// that is set and is not one.
    static func mergeable(_ json: Data?) throws(AgyHooks.Unmergeable) -> [String: Any] {
        let settings = try AgyHooks.mergeable(json)
        if let value = settings["statusLine"], !(value is NSNull), value as? [String: Any] == nil {
            throw AgyHooks.Unmergeable(reason: "sets statusLine in a form AiTerm cannot merge")
        }
        return settings
    }

    /// Whether the status line runs this shim, or another copy of it that still runs.
    static func isInstalled(_ settings: [String: Any], shimPath: String,
                            isRunnable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        guard let line = line(settings), let command = line["command"] as? String,
              line["type"] as? String == "command", line["enabled"] as? Bool != false else { return false }
        return command == shimPath || (isOurShim(command, shimPath: shimPath) && isRunnable(command))
    }

    static func isOwned(_ settings: [String: Any], shimPath: String) -> Bool {
        (line(settings)?["command"] as? String).map { isOurShim($0, shimPath: shimPath) } ?? false
    }

    /// The merged settings, and what the status line was before (`StatusLineOriginal.Before`).
    static func merge(_ json: Data?, shimPath: String) throws -> (Data, StatusLineOriginal.Before) {
        var settings = try mergeable(json)
        let current = line(settings)
        let command = (current?["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let before: StatusLineOriginal.Before
        if let command, isOurShim(command, shimPath: shimPath) {
            before = .ours
        } else if let command, current?["enabled"] as? Bool != false {
            before = .foreign(command)
        } else {
            before = .missing
        }
        var line = current ?? [:]
        line["type"] = "command"
        line["command"] = shimPath
        // A status line the person turned off is turned on again for the shim; theirs is not run.
        line["enabled"] = nil
        if before == .missing, line["stack_with_default"] == nil { line["stack_with_default"] = true }
        settings["statusLine"] = line
        return (try JSONSerialization.data(withJSONObject: settings, options: ClaudeSettings.jsonOptions), before)
    }
}

/// Antigravity's driver: the `aiterm` named hook in `~/.gemini/config/hooks.json` (`AgyHooks`), and
/// the status-line shim in its `settings.json` (`AgyStatusLine`), which posts to the port it reads from
/// the support folder's `hook-port`.
struct AgyDriver: HarnessDriver {
    let home: URL, daemonPort: Int, shimPath: String

    var hooks: UserConfigFile { UserConfigFile(home: home, AgyHooks.path) }
    var settings: UserConfigFile { UserConfigFile(home: home, AgyStatusLine.path) }
    private var hookURL: String { Harness.agy.hookURL(port: daemonPort) }

    func probe() -> DriverProbe {
        let hooksFile = hooks, settingsFile = settings
        var hooksState = HarnessIntegrationState.missing
        let hooksProbe = hooksFile.read().probe(hooksFile) { data in
            do throws(AgyHooks.Unmergeable) {
                hooksState = AgyHooks.state(try AgyHooks.mergeable(data), hookURL: hookURL)
                return DriverProbe(hooksState)
            } catch {
                return .refused(hooksFile, error.reason)
            }
        }
        if hooksProbe.state == .unreadable { return hooksProbe }
        let settingsData: Data?
        switch settingsFile.read() {
        case .refused(let reason): return .refused(settingsFile, reason)
        case .missing: settingsData = nil
        case .present(let data): settingsData = data
        }
        let line: [String: Any]
        do throws(AgyHooks.Unmergeable) { line = try AgyStatusLine.mergeable(settingsData) } catch { return .refused(settingsFile, error.reason) }
        let lineInstalled = AgyStatusLine.isInstalled(line, shimPath: shimPath)
        if hooksState == .current, lineInstalled, ShimPort.isRecorded(daemonPort, home: home) { return DriverProbe(.current) }
        let anything = hooksState != .missing || AgyStatusLine.isOwned(line, shimPath: shimPath)
        return DriverProbe(anything ? .outdated : .missing)
    }

    func install() throws {
        let hooksFile = hooks, settingsFile = settings
        let hooksData = try hooksFile.read().requiringReadable(hooksFile)
        let settingsData = try settingsFile.read().requiringReadable(settingsFile)
        let mergedHooks: Data, mergedSettings: Data, before: StatusLineOriginal.Before
        do {
            mergedHooks = try AgyHooks.merge(hooksData, hookURL: hookURL)
        } catch let refusal as AgyHooks.Unmergeable {
            throw hooksFile.refusal(refusal.reason)
        }
        do {
            (mergedSettings, before) = try AgyStatusLine.merge(settingsData, shimPath: shimPath)
        } catch let refusal as AgyHooks.Unmergeable {
            throw settingsFile.refusal(refusal.reason)
        }
        // The shim's port and the person's own status line are on disk before the settings point
        // Antigravity at the shim, as Claude's driver does it.
        try ShimPort.record(daemonPort, home: home)
        try StatusLineOriginal.record(before, home: home, agent: .agy)
        if !ClaudeSettings.same(hooksData, mergedHooks) {
            try hooksFile.backUp()
            try hooksFile.write(mergedHooks)
        }
        if !ClaudeSettings.same(settingsData, mergedSettings) {
            try settingsFile.backUp()
            try settingsFile.write(mergedSettings)
        }
    }

    func test(with client: HarnessTestClient) async -> HarnessTestResult { await client.testHTTP(endpoint: Harness.agy.hookEndpoint) }
}
