import Foundation

/// Claude Code's driver: HTTP hooks for its lifecycle events and the status-line shim that carries
/// its usage, merged into `~/.claude/settings.json` beside whatever else is there (Emdash's hooks,
/// the user's own status line).
struct ClaudeDriver: HarnessDriver {
    static let settingsPath = ".claude/settings.json"

    let home: URL, daemonPort: Int, shimPath: String

    var settings: UserConfigFile { UserConfigFile(home: home, Self.settingsPath) }

    func probe() -> DriverProbe {
        let file = settings
        switch file.read() {
        case .missing: return DriverProbe(.missing)
        case .refused(let reason): return .refused(file, reason)
        case .present(let data):
            guard let object = HookInstaller.claudeSettings(data) else { return .refused(file, "is not a JSON object") }
            if HookInstaller.claudeHooksAreInstalled(object, daemonPort: daemonPort, shimPath: shimPath) {
                return DriverProbe(.current)
            }
            return DriverProbe(HookInstaller.claudeHooksAreOwned(object, shimPath: shimPath) ? .outdated : .missing)
        }
    }

    func install() throws {
        let file = settings, fileManager = FileManager.default
        let data: Data?
        switch file.read() {
        case .missing: data = nil
        case .refused(let reason): throw file.refusal(reason)
        case .present(let contents): data = contents
        }
        let (merged, original) = try HookInstaller.mergeClaudeSettings(data, hookURL: "http://127.0.0.1:\(daemonPort)/hook/claude",
                                                                       shimPath: shimPath)
        let support = try AiTermPaths.migrateSupportDirectory(homeDirectory: home)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        // T9-1 fix 4: save the original status line *before* writing the merged settings.json, so
        // a crash (or a failed/partial write) between the two can never leave Claude pointed at
        // the shim without a recorded original to fall back to.
        let originalURL = support.appendingPathComponent("statusline-original.json")
        let commandURL = support.appendingPathComponent("statusline-original.cmd")
        if let original {
            try JSONSerialization.data(withJSONObject: original).write(to: originalURL, options: .atomic)
            try HookInstaller.saveOriginalCommand(original["command"] as? String, to: commandURL)
            // Asked of the file's content only (`isRunnable` defeated): here the question is
            // whether settings.json still names our shim, not whether that shim can run. A bundle
            // that moved, or a translocated launch, would otherwise look like "the user removed
            // our status line" and throw away the record of the user's real one.
        } else if !HookInstaller.claudeStatusLineIsInstalled(data, shimPath: shimPath, isRunnable: { _ in true }) {
            // If the user removed their status line, do not revive an old saved display when
            // reinstalling the telemetry callback. Keep the original on normal shim reinstalls.
            for url in [originalURL, commandURL] where fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        } else {
            try HookInstaller.migrateOriginalCommand(from: originalURL, to: commandURL)
        }
        guard !HookInstaller.sameSettings(data, merged) else { return }
        try file.backUp()
        try file.write(merged)
    }

    func test(with client: HarnessTestClient) async -> HarnessTestResult { await client.testHTTP(agent: .claude) }
}
