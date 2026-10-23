import Foundation

/// Codex's driver: command hooks for its lifecycle events and an MCP server for `Stop`, merged into
/// `~/.codex/config.toml` between marker comments, every other byte of the file kept.
struct CodexDriver: HarnessDriver {
    static let configPath = ".codex/config.toml"

    let home: URL, daemonPort: Int

    var config: UserConfigFile { UserConfigFile(home: home, Self.configPath) }

    func probe() -> DriverProbe {
        let file = config
        return file.readText().probe(file) { text in
            let parsed = TOMLStatements.parsed(text)
            if let reason = Self.unmergeable(text, parsed) { return .refused(file, reason) }
            if CodexHookConfig.merge(text, hookURL: "http://127.0.0.1:\(daemonPort)", tables: parsed.tables) == text { return DriverProbe(.current) }
            return DriverProbe(CodexHookConfig.containsOwnedTables(parsed.tables) ? .outdated : .missing)
        }
    }

    func install() throws {
        let file = config
        let text = try file.readText().requiringReadable(file)
        if let text, let reason = Self.unmergeable(text, TOMLStatements.parsed(text)) { throw file.refusal(reason) }
        let merged = CodexHookConfig.merge(text, hookURL: "http://127.0.0.1:\(daemonPort)")
        guard merged != text else { return }
        try file.backUp()
        try file.write(Data(merged.utf8))
    }

    func test(with client: HarnessTestClient) async -> HarnessTestResult { await client.testHTTP(endpoint: Harness.codex.hookEndpoint) }

    /// Why AiTerm's `[[hooks.<event>]]` tables cannot be appended to `text`, when they cannot.
    /// `parsed` is `text` parsed, which the caller has to hand anyway.
    private static func unmergeable(_ text: String, _ parsed: (tables: [TOMLStatements.Table], balanced: Bool)) -> String? {
        guard parsed.balanced else { return "cannot be parsed" }
        return CodexHookConfig.conflict(in: text, tables: parsed.tables).map { "sets \($0) in a form AiTerm cannot merge" }
    }
}
