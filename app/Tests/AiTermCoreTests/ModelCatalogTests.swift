import Testing
import Foundation
@testable import AiTermCore

@Suite struct ModelCatalogTests {
    @Test func piModelsComeFromProviderQualifiedRows() throws {
        let output = """
        provider      model          context  max-out  thinking  images
        openai-codex  gpt-5.6-sol    272K     128K     yes       yes
        anthropic     claude-sonnet  200K     64K      no        yes
        """
        let models = try PiModelCatalog.parse(output)
        #expect(models.map(\.id) == ["openai-codex/gpt-5.6-sol", "anthropic/claude-sonnet"])
        #expect(models[0].label == "openai-codex / gpt-5.6-sol")
        #expect(models[0].detail == "272K context · 128K max · images")
        #expect(models[0].efforts == PiModelCatalog.thinkingLevels)
        #expect(models[0].defaultEffort == "medium")
        #expect(models[1].efforts.isEmpty)
        #expect(models[1].defaultEffort == nil)
    }

    @Test func piModelParserHandlesEmptyAndRejectsBrokenTables() throws {
        #expect(try PiModelCatalog.parse("\n").isEmpty)
        #expect(throws: PiModelCatalogError.self) {
            try PiModelCatalog.parse("provider model\nx y")
        }
        #expect(throws: PiModelCatalogError.self) {
            try PiModelCatalog.parse("provider model context max-out thinking images\np only-two")
        }
    }

    @Test func piDiscoveryDistinguishesNoProvidersFromCommandFailure() throws {
        let empty = HarnessCommandRunner(locate: { _ in "/usr/local/bin/pi" }, run: { _, arguments, environment, timeout in
            #expect(arguments == ["--offline", "--list-models"])
            #expect(environment["PI_OFFLINE"] == "1")
            #expect(timeout == 5)
            return ProcessOutput(status: 0, stdout: "\n", stderr: "", timedOut: false)
        })
        #expect(try PiModelCatalog.discover(runner: empty).isEmpty)

        let missing = HarnessCommandRunner(locate: { _ in nil }, run: { _, _, _, _ in
            Issue.record("a missing executable must not be launched")
            return ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false)
        })
        #expect(throws: PiModelCatalogError.self) { try PiModelCatalog.discover(runner: missing) }

        let failed = HarnessCommandRunner(locate: { _ in "/usr/local/bin/pi" }, run: { _, _, _, _ in
            ProcessOutput(status: 2, stdout: "", stderr: "bad auth", timedOut: false)
        })
        #expect(throws: PiModelCatalogError.self) { try PiModelCatalog.discover(runner: failed) }

        let timedOut = HarnessCommandRunner(locate: { _ in "/usr/local/bin/pi" }, run: { _, _, _, _ in
            ProcessOutput(status: 15, stdout: "", stderr: "", timedOut: true)
        })
        #expect(throws: PiModelCatalogError.self) { try PiModelCatalog.discover(runner: timedOut) }
    }

    @Test func testClaudeModelsFromSettingsOrDefaults() {
        // Spec 4.3: the aliases are always offered, `availableModels` is added after them.
        let ids = { (models: [AgentModel]) in models.map(\.id) }
        #expect(ids(ModelCatalog.claudeModels(catalogJSON: nil, settingsJSON: Data(#"{"availableModels":["claude-opus-5","claude-fable-5-1"]}"#.utf8), claudeJSON: nil))
                == ["opus", "sonnet", "fable", "haiku", "claude-opus-5", "claude-fable-5-1"])
        #expect(ids(ModelCatalog.claudeModels(catalogJSON: nil, settingsJSON: Data(#"{"availableModels":["opus","claude-opus-5"]}"#.utf8), claudeJSON: nil))
                == ["opus", "sonnet", "fable", "haiku", "claude-opus-5"], "an alias repeated in settings must not appear twice")
        #expect(ids(ModelCatalog.claudeModels(catalogJSON: nil, settingsJSON: Data("{}".utf8), claudeJSON: nil)) == ["opus", "sonnet", "fable", "haiku"])
        #expect(ids(ModelCatalog.claudeModels(catalogJSON: nil, settingsJSON: nil, claudeJSON: nil)) == ["opus", "sonnet", "fable", "haiku"])
    }

    /// The models Claude Code itself offers beyond the aliases live in `~/.claude.json`, with the
    /// label and one-liner the CLI shows in `/model` — so the sheet lists exactly what the CLI does.
    @Test func testClaudeModelsFromClaudeJSONCache() {
        let json = Data(#"""
        {"additionalModelOptionsCache":[{"value":"claude-fable-5-1[1m]","label":"Fable","description":"Fable 5.1 · Most capable"}]}
        """#.utf8)
        let models = ModelCatalog.claudeModels(catalogJSON: nil, settingsJSON: nil, claudeJSON: json)
        #expect(models.map(\.id).last == "claude-fable-5-1[1m]")
        #expect(models.last?.label == "Fable")
        #expect(models.last?.detail == "Fable 5.1 · Most capable")
        #expect(models.allSatisfy { $0.efforts == ModelCatalog.claudeEfforts })
    }

    /// Codex publishes its real model list — display names, reasoning levels and the default level
    /// per model — in `~/.codex/models_cache.json`. Hidden models are not offered.
    @Test func testCodexModelsFromModelsCache() {
        let cache = Data(#"""
        {"models":[
          {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"Everyday workhorse.","visibility":"list",
           "default_reasoning_level":"medium",
           "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}]},
          {"slug":"gpt-reserve","display_name":"GPT-Reserve","visibility":"hide",
           "supported_reasoning_levels":[{"effort":"low"}]},
          {"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list","default_reasoning_level":"xhigh",
           "supported_reasoning_levels":[{"effort":"high"},{"effort":"xhigh"}]}
        ]}
        """#.utf8)
        let models = ModelCatalog.codexModels(modelsCacheJSON: cache, configTOML: nil)
        #expect(models.map(\.id) == ["gpt-5.6-sol", "gpt-5.5"], "a model marked hide is not offered")
        #expect(models[0].label == "GPT-5.6-Sol")
        #expect(models[0].detail == "Everyday workhorse.")
        #expect(models[0].efforts == ["low", "medium", "high"])
        #expect(models[0].defaultEffort == "medium")
        #expect(models[1].efforts == ["high", "xhigh"], "reasoning levels are per model, not one static list")
        #expect(models[1].defaultEffort == "xhigh")
    }

    @Test func testCodexModelsFallBackToConfigProfiles() {
        let toml = """
        model = "gpt-5.6"
        model_reasoning_effort = "high"
        [profiles.fast]
        model = "gpt-5.6-mini"
        [profiles.deep]
        model = "gpt-5.6"
        [tui]
        theme = "dark"
        model = "should-not-appear"
        """
        #expect(ModelCatalog.codexModels(modelsCacheJSON: nil, configTOML: toml).map(\.id) == ["gpt-5.6", "gpt-5.6-mini"])
        #expect(ModelCatalog.codexModels(modelsCacheJSON: nil, configTOML: nil).map(\.id) == ["gpt-5.6"])
        #expect(ModelCatalog.codexModels(modelsCacheJSON: Data("{}".utf8), configTOML: toml).map(\.id) == ["gpt-5.6", "gpt-5.6-mini"],
                "an empty cache is not an answer; fall through to the config")
    }

    /// TOML allows a comment after a value, and after a header; neither is part of the model id.
    /// An unquoted value is not TOML at all, so Codex would not load the file: it names no model.
    @Test func testCodexConfigModelIdsStopAtTheirQuotes() {
        let toml = """
        model = "gpt-5.6" # the default
        [profiles.fast] # quick
        model='gpt-5.6-mini'   # quick
        [profiles.bare]
        model = gpt-bare # unquoted
        """
        #expect(ModelCatalog.codexConfigModels(configTOML: toml).map(\.id) == ["gpt-5.6", "gpt-5.6-mini"])
    }

    /// Read by each key's full path, not line by line: a dotted profile key counts, and a line that
    /// only looks like `model = …` inside a multi-line string, or a `model` in another table, does not.
    @Test func testCodexConfigModelsAreReadByKeyPath() {
        let toml = """
        notes = \"\"\"
        model = "from-a-string"
        \"\"\"
        profiles.dotted.model = "gpt-dotted"
        [profiles.deep.extra]
        model = "too-deep"
        ["profiles".'quoted']
        model = "gpt-quoted"
        """
        #expect(ModelCatalog.codexConfigModels(configTOML: toml).map(\.id) == ["gpt-dotted", "gpt-quoted"])
    }

    /// The reasoning list the sheet shows follows the picked model; the agent's own list stands in
    /// only when no model is picked at all. (A model that publishes an *empty* list is a different
    /// case — it takes no reasoning flag — and `testAClaudeModelWithoutThinkingOffersNoEfforts`
    /// covers it.)
    @Test func testEffortsFollowTheModel() {
        let model = AgentModel(id: "gpt-5.6-sol", label: "Sol", detail: nil, efforts: ["low", "high"], defaultEffort: "high")
        #expect(ModelCatalog.efforts(for: .codex, model: model) == ["low", "high"])
        #expect(ModelCatalog.efforts(for: .codex, model: nil) == ModelCatalog.codexEfforts)
        #expect(ModelCatalog.efforts(for: .claude, model: nil) == ModelCatalog.claudeEfforts)
    }

    /// Claude Code 2.1.251+ drives `/model` from a signed catalogue it caches under
    /// `~/.claude/cache/model-catalog/<org>-<hash>-cc.json`. That file — not the four aliases — is
    /// what the CLI's own picker lists, so the sheet must read it: real ids, the CLI's names and
    /// one-liners, and the effort levels each model publishes.
    @Test func testClaudeModelsFromTheModelCatalogCache() {
        let models = ModelCatalog.claudeModels(catalogJSON: Fixtures.claudeCatalog, settingsJSON: nil, claudeJSON: nil)
        #expect(models.map(\.id) == ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5-20251001"],
                "the catalogue replaces the aliases; its order is the order /model shows")
        #expect(models[0].label == "Fable 5.1")
        #expect(models[0].detail == "For your toughest challenges")
        #expect(models[0].efforts == ["low", "medium", "high", "xhigh", "max"], "Claude publishes five levels, not three")
        #expect(models[0].defaultEffort == "high", "the level badged Default is the default")
    }

    /// `thinking: {"type": "none"}` (Haiku) means the model takes no effort flag at all.
    @Test func testAClaudeModelWithoutThinkingOffersNoEfforts() {
        let haiku = ModelCatalog.claudeModels(catalogJSON: Fixtures.claudeCatalog, settingsJSON: nil, claudeJSON: nil).last
        #expect(haiku?.efforts == [])
        #expect(haiku?.defaultEffort == nil)
        #expect(ModelCatalog.efforts(for: .claude, model: haiku) == [])
        #expect(ModelCatalog.defaultEffort(for: .claude, model: haiku) == nil)
    }

    /// The extras in `~/.claude.json` are still merged in after the catalogue — the 1M-context
    /// variants live there and the catalogue does not list them.
    @Test func testClaudeCatalogueIsExtendedByTheClaudeJSONCache() {
        let json = Data(#"""
        {"additionalModelOptionsCache":[{"value":"claude-fable-5-1[1m]","label":"Fable","description":"Fable 5.1 · 1M context"}]}
        """#.utf8)
        let ids = ModelCatalog.claudeModels(catalogJSON: Fixtures.claudeCatalog, settingsJSON: nil, claudeJSON: json).map(\.id)
        #expect(ids == ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5-20251001", "claude-fable-5-1[1m]"])
    }

    /// A `[1m]` entry from `~/.claude.json` is a context variant of a catalogue model, not a
    /// different model: it supports exactly the same reasoning levels. Giving it the three-level
    /// fallback would quietly drop `xhigh` and `max` for anyone who picks the 1M variant.
    @Test func testAContextVariantInheritsItsBaseModelsEfforts() {
        let json = Data(#"""
        {"additionalModelOptionsCache":[{"value":"claude-fable-5-1[1m]","label":"Fable","description":"1M context"},
                                        {"value":"claude-haiku-4-5-20251001[1m]","label":"Haiku","description":"1M context"},
                                        {"value":"some-unknown-model","label":"Other","description":null}]}
        """#.utf8)
        let models = ModelCatalog.claudeModels(catalogJSON: Fixtures.claudeCatalog, settingsJSON: nil, claudeJSON: json)
        let by = { (id: String) in models.first { $0.id == id } }
        #expect(by("claude-fable-5-1[1m]")?.efforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(by("claude-fable-5-1[1m]")?.defaultEffort == "high")
        #expect(by("claude-haiku-4-5-20251001[1m]")?.efforts == [], "Haiku takes no effort flag in either context size")
        #expect(by("some-unknown-model")?.efforts == ModelCatalog.claudeEfforts, "nothing to inherit from: the three-level fallback")
    }

    /// No catalogue on disk (a fresh install, or a CLI too old to write one) falls back to the
    /// aliases exactly as before, so the sheet is never empty.
    @Test func testClaudeFallsBackToAliasesWithoutACatalogue() {
        #expect(ModelCatalog.claudeModels(catalogJSON: nil, settingsJSON: nil, claudeJSON: nil).map(\.id) == ["opus", "sonnet", "fable", "haiku"])
        #expect(ModelCatalog.claudeModels(catalogJSON: Data("{}".utf8), settingsJSON: nil, claudeJSON: nil).map(\.id) == ["opus", "sonnet", "fable", "haiku"],
                "an empty catalogue is not an answer")
    }

    /// The reasoning levels must follow the Claude model too, not a single static list.
    @Test func testClaudeEffortsFollowTheModel() {
        let fable = ModelCatalog.claudeModels(catalogJSON: Fixtures.claudeCatalog, settingsJSON: nil, claudeJSON: nil)[0]
        #expect(ModelCatalog.efforts(for: .claude, model: fable) == ["low", "medium", "high", "xhigh", "max"])
        #expect(ModelCatalog.efforts(for: .claude, model: nil) == ModelCatalog.claudeEfforts, "no model picked: the legacy three")
    }

    /// The cache file is named per org and per surface; the sheet must find the `-cc` one (Claude
    /// Code's own surface) and ignore the others.
    @Test func testTheClaudeCatalogueFileIsFoundByItsSurfaceSuffix() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let dir = home.appendingPathComponent(".claude/cache/model-catalog")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("org-abc-web.json"))
        try Fixtures.claudeCatalog.write(to: dir.appendingPathComponent("org-abc-cc.json"))
        #expect(ModelCatalog.models(for: .claude, home: home).map(\.id).first == "claude-fable-5-1")
    }

    enum Fixtures {
        /// Trimmed from a real `~/.claude/cache/model-catalog/<org>-<hash>-cc.json` (CLI 2.1.274).
        static let claudeCatalog = Data(#"""
        {"version":2,"fetchedAt":1789634773346,"catalog":{"surface":"cc","config":{"id":"cc","models":[
          {"id":"claude-fable-5-1","name":"Fable 5.1","short_name":"Fable","description":"For your toughest challenges","section":"main",
           "thinking":{"type":"effort","effort_options":[{"id":"low","name":"Low"},{"id":"medium","name":"Medium"},
             {"id":"high","name":"High","badge":{"message":"Default","variant":"neutral"}},{"id":"xhigh","name":"Extra"},{"id":"max","name":"Max"}]}},
          {"id":"claude-opus-5","name":"Opus 5","short_name":"Opus","description":"For complex tasks","section":"main",
           "thinking":{"type":"effort","effort_options":[{"id":"low","name":"Low"},{"id":"medium","name":"Medium"},
             {"id":"high","name":"High","badge":{"message":"Default","variant":"neutral"}},{"id":"xhigh","name":"Extra"},{"id":"max","name":"Max"}]}},
          {"id":"claude-sonnet-5","name":"Sonnet 5","short_name":"Sonnet","description":"Most efficient for everyday tasks","section":"main",
           "thinking":{"type":"effort","effort_options":[{"id":"low","name":"Low"},{"id":"medium","name":"Medium"},
             {"id":"high","name":"High","badge":{"message":"Default","variant":"neutral"}}]}},
          {"id":"claude-haiku-4-5-20251001","name":"Haiku 4.5","short_name":"Haiku","description":"Fastest for quick answers","section":"main",
           "thinking":{"type":"none"}}
        ]}}}
        """#.utf8)
    }
}
