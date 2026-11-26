import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The app's half of the compatibility check (`scripts/compat-check.sh`, docs/testing.md). The
/// check drives each agent CLI live with what the app would install and launch, and saves what the
/// CLI sent and wrote into `daemon/tests/fixtures/compat/<agent>/`. This suite keeps the check's
/// inputs in step with the app (`compat/launch.json`, `compat/drivers/`), so a flag or hook the app
/// gains is one the next capture exercises, and reads each capture with the app's own readers: the
/// model lists, the headless answers, and every flag the app passes in the CLI's own help. A failure
/// after a new capture means the CLI changed what the app reads; never regenerate a capture to pass.
@Suite struct CompatContractTests {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let compat = repo.appendingPathComponent("compat")
    /// Set to 1 to write the templates from the app instead of comparing: a deliberate change only.
    static let recording = ProcessInfo.processInfo.environment["AITERM_RECORD_COMPAT"] == "1"
    /// What stands for a value in a template; the capture fills each in.
    static let port = "__AITERM_HOOK_PORT__", shim = "__AITERM_SHIM__"

    // -- the templates the capture launches and installs from --

    /// Every command line the app runs a CLI with, by agent and use, its variable parts as `{name}`.
    static func launches() -> [String: [String: [String]]] {
        let (model, reasoning) = ("{model}", "{reasoning}")
        func oracle(_ agent: AgentKind) -> [String] {
            let run = OracleLaunch.invocation(OracleSetting(isOn: true, agent: agent, model: model, reasoning: reasoning),
                                                 prompt: "{prompt}", folder: "{folder}", projects: ["{project}"], answerFile: "{answer}")
            return [run.executable] + run.arguments
        }
        let folder = URL(fileURLWithPath: "/{run}")
        var result: [String: [String: [String]]] = [:]
        for agent in AgentKind.allCases {
            let harness = agent.harness
            var uses: [String: [String]] = [
                "task": harness.launchWords(model: model, reasoning: reasoning),
                "resume": harness.resumeWords(conversation: "{conversation}", model: model, reasoning: reasoning),
                "challenge": oracle(agent),
            ]
            if AgentCommand.workerAgents.contains(agent) {
                uses["worker"] = AgentCommand.workerWords(agent: agent, model: model, reasoning: reasoning)
                uses["review"] = AgentCommand.workerWords(agent: agent, model: model, reasoning: reasoning, readOnly: true)
            }
            if agent == .claude {
                uses["operator"] = OperatorLaunch.launchWords(model: model, effort: reasoning, folder: folder)
                uses["operatorResume"] = OperatorLaunch.launchWords(model: model, effort: reasoning, folder: folder, resuming: "{conversation}")
            }
            result[agent.rawValue] = uses
        }
        return result
    }

    static func claudeSettings() throws -> Data {
        try ClaudeSettings.merge(nil, hookURL: "http://127.0.0.1:\(port)" + Harness.claude.hookEndpoint, shimPath: shim).0
    }

    static func codexBlock() -> String {
        CodexHookConfig.block(hookURL: "http://127.0.0.1:\(port)") + "\n"
    }

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    private static func check(_ name: String, _ expected: Data) throws {
        let url = compat.appendingPathComponent(name)
        if recording {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try expected.write(to: url)
            return
        }
        let found = try Data(contentsOf: url)
        #expect(found == expected, "compat/\(name) differs from what the app builds: run this suite with AITERM_RECORD_COMPAT=1, then capture again (scripts/compat-check.sh)")
    }

    @Test func theLaunchTemplatesAreWhatTheAppRuns() throws {
        try Self.check("launch.json", Self.json(Self.launches()))
    }

    @Test func theClaudeDriverTemplateIsWhatTheAppMerges() throws {
        try Self.check("drivers/claude-settings.json", Self.claudeSettings() + Data("\n".utf8))
    }

    @Test func theCodexDriverTemplateIsWhatTheAppMerges() throws {
        try Self.check("drivers/codex-hooks.toml", Data(Self.codexBlock().utf8))
    }

    /// The `aiterm` named hook as the app merges it, which the capture installs in its scratch workspace.
    @Test func theAntigravityDriverTemplateIsWhatTheAppMerges() throws {
        let hooks = try JSONSerialization.data(withJSONObject: [AgyHooks.name: AgyHooks.entry(hookURL: "http://127.0.0.1:\(Self.port)" + Harness.agy.hookEndpoint)],
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try Self.check("drivers/agy-hooks.json", hooks + Data("\n".utf8))
    }

    // -- the captures, read as the app reads the CLI --

    static let captures = repo.appendingPathComponent("daemon/tests/fixtures/compat")

    static func captured(_ agent: AgentKind, _ path: String) throws -> Data {
        let url = captures.appendingPathComponent(agent.rawValue).appendingPathComponent(path)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            Issue.record("no \(path) in the \(agent.rawValue) capture: run scripts/compat-check.sh --agents \(agent.rawValue)")
            throw CancellationError()
        }
        return data
    }

    static func text(_ agent: AgentKind, _ path: String) throws -> String { String(decoding: try captured(agent, path), as: UTF8.self) }

    static func object(_ data: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }

    /// What the capture's own model is, as the capture note names it.
    static func capturedModel(_ agent: AgentKind) throws -> String { try object(captured(agent, "capture.json"))["model"] as? String ?? "" }

    @Test func claudesCatalogueReadsAsItsOwnModelsAndEfforts() throws {
        let folder = Self.captures.appendingPathComponent("claude/model-catalog")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix("-cc.json") }
        try #require(names.count == 1, "the capture holds no single Claude Code model catalogue: \(names)")
        let data = try Data(contentsOf: folder.appendingPathComponent(names[0]))
        // The catalogue's own ids and published efforts, read without the app's reader.
        let raw = ((Self.object(data)["catalog"] as? [String: Any])?["config"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
        let expected = raw.compactMap { entry -> (String, [String])? in
            guard let id = entry["id"] as? String else { return nil }
            let thinking = entry["thinking"] as? [String: Any]
            let efforts = (thinking?["type"] as? String) == "effort"
                ? (thinking?["effort_options"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } : []
            return (id, efforts)
        }
        try #require(!expected.isEmpty, "the catalogue lists no models where the app looks: catalog.config.models")
        let read = ModelFiles.claudeModels(catalogJSON: data, settingsJSON: nil, claudeJSON: nil)
        #expect(read.map(\.id) == expected.map(\.0))
        #expect(read.map(\.efforts) == expected.map(\.1))
        #expect(read.map(\.id) != ModelFiles.claudeAliases, "the catalogue read as the fallback aliases")
        #expect(expected.contains { !$0.1.isEmpty }, "no model publishes efforts in the catalogue")
        let model = try Self.capturedModel(.claude)
        #expect(read.contains { $0.id.contains(model) }, "the catalogue lacks the model the capture ran")
    }

    @Test func codexsModelCacheReadsAsItsOwnModelsAndEfforts() throws {
        let data = try Self.captured(.codex, "models_cache.json")
        let raw = Self.object(data)["models"] as? [[String: Any]] ?? []
        let expected = raw.compactMap { entry -> (String, [String])? in
            guard let slug = entry["slug"] as? String, (entry["visibility"] as? String) != "hide" else { return nil }
            return (slug, (entry["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String })
        }
        try #require(!expected.isEmpty, "models_cache.json lists no visible models where the app looks")
        let read = ModelFiles.codexModels(modelsCacheJSON: data)
        #expect(read.map(\.id) == expected.map(\.0))
        #expect(read.map(\.efforts) == expected.map(\.1), "a model no longer publishes its reasoning levels")
        #expect(read.map(\.id).contains(try Self.capturedModel(.codex)))
    }

    @Test func pisModelListReadsAsEveryRow() throws {
        let output = try Self.text(.pi, "list-models.txt")
        let rows = output.split(whereSeparator: \.isNewline).dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let read = try PiModelCatalog.parse(output)
        #expect(read.count == rows.count)
        #expect(read.map(\.id).contains(try Self.capturedModel(.pi)))
    }

    @Test func antigravitysModelListReadsAsEveryRow() throws {
        let output = try Self.text(.agy, "list-models.txt")
        let rows = output.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let read = try AgyModelCatalog.parse(output)
        // Each row is one model at one effort, folded into its model's levels.
        let ids = read.flatMap { model in model.efforts.isEmpty ? [model.id] : model.efforts.map { AgyModelCatalog.cliModel(model.id, reasoning: $0) } }
        #expect(ids.count == rows.count)
        let captured = try Self.object(Self.captured(.agy, "capture.json"))
        #expect(ids.contains(AgyModelCatalog.cliModel(captured["model"] as? String ?? "", reasoning: captured["reasoning"] as? String)))
    }

    private static func ran(_ stdout: String) -> ProcessOutput { ProcessOutput(status: 0, stdout: stdout, stderr: "", timedOut: false) }

    @Test func eachHeadlessAnswerReadsAsTheAppReadsIt() throws {
        let claude = OracleLaunch.critique(.claude, output: Self.ran(try Self.text(.claude, "headless/challenge.json")), answerFile: nil)
        #expect(claude?.contains("OK") == true, "Claude's -p --output-format json answer no longer reads: \(String(describing: claude))")
        let answer = Self.captures.appendingPathComponent("codex/headless/challenge-answer.txt").path
        let codex = OracleLaunch.critique(.codex, output: Self.ran(try Self.text(.codex, "headless/challenge.jsonl")), answerFile: answer)
        #expect(codex?.contains("OK") == true, "codex exec's -o answer no longer reads: \(String(describing: codex))")
        let pi = OracleLaunch.critique(.pi, output: Self.ran(try Self.text(.pi, "headless/challenge.txt")), answerFile: nil)
        #expect(pi?.contains("OK") == true, "PI's -p answer no longer reads: \(String(describing: pi))")
        let agy = OracleLaunch.critique(.agy, output: Self.ran(try Self.text(.agy, "headless/challenge.json")), answerFile: nil)
        #expect(agy?.contains("OK") == true, "Antigravity's -p --output-format json answer no longer reads: \(String(describing: agy))")
    }

    /// Every option the app passes `agent`, from its templates: a word that starts with a dash, but
    /// not `--` alone, which ends PI's options.
    static func flags(_ agent: AgentKind) -> Set<String> {
        Set((launches()[agent.rawValue] ?? [:]).values.joined().filter { $0.hasPrefix("-") && $0 != "--" && !$0.contains("{") })
    }

    @Test(arguments: AgentKind.allCases)
    func everyFlagTheAppPassesIsOneTheCLIKnows(_ agent: AgentKind) throws {
        let help = try Self.text(agent, "help.txt")
        // Flags --help leaves out are proved by a headless run instead: its answer carries the marker
        // the flag's file asked for.
        let probesFile = Self.captures.appendingPathComponent("\(agent.rawValue)/probes.json").path
        let probes = FileManager.default.contents(atPath: probesFile).map(Self.object) ?? [:]
        for flag in Self.flags(agent).sorted() {
            let listed = help.range(of: "(^|[\\s,\\[])\(NSRegularExpression.escapedPattern(for: flag))([\\s,=\\]]|$)",
                                    options: .regularExpression) != nil
            let probe = probes[flag] as? [String: Any]
            let proved = probe.map { (($0["answer"] as? String) ?? "").contains(($0["marker"] as? String) ?? "\u{0}") } ?? false
            #expect(listed || proved, "\(agent.rawValue) no longer knows \(flag): it is not in its --help, and no probe proved it")
        }
    }
}
