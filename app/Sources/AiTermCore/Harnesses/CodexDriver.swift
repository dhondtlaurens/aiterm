import Foundation

/// Codex's driver: command hooks for its lifecycle events and an MCP server for `Stop`, merged into
/// `~/.codex/config.toml` between marker comments, every other byte of the file kept.
struct CodexDriver: HarnessDriver {
    static let configPath = ".codex/config.toml"

    let home: URL, daemonPort: Int

    var config: UserConfigFile { UserConfigFile(home: home, Self.configPath) }

    func probe() -> DriverProbe {
        let file = config
        switch file.readText() {
        case .missing: return DriverProbe(.missing)
        case .refused(let reason): return .refused(file, reason)
        case .present(let text):
            if let reason = Self.unmergeable(text) { return .refused(file, reason) }
            if HookInstaller.codexHooksAreInstalled(text, daemonPort: daemonPort) { return DriverProbe(.current) }
            return DriverProbe(HookInstaller.codexHooksAreOwned(text) ? .outdated : .missing)
        }
    }

    func install() throws {
        let file = config
        let text: String?
        switch file.readText() {
        case .missing: text = nil
        case .refused(let reason): throw file.refusal(reason)
        case .present(let contents): text = contents
        }
        if let text, let reason = Self.unmergeable(text) { throw file.refusal(reason) }
        let merged = HookInstaller.mergeCodexConfig(text, hookURL: "http://127.0.0.1:\(daemonPort)")
        guard merged != text else { return }
        try file.backUp()
        try file.write(Data(merged.utf8))
    }

    func test(with client: HarnessTestClient) async -> HarnessTestResult { await client.testHTTP(agent: .codex) }

    /// Why AiTerm's `[[hooks.<event>]]` tables cannot be appended, when they cannot.
    private static func unmergeable(_ text: String) -> String? {
        CodexHookConfig.conflict(in: text).map { "sets \($0) in a form AiTerm cannot merge" }
    }
}
