import Testing
import Foundation
@testable import AiTermCore

@Suite struct ModelFilesTests {
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
        #expect(models[0].efforts == AgentKind.pi.harness.efforts(for: nil))
        #expect(models[0].defaultEffort == "medium")
        #expect(models[1].efforts.isEmpty)
        #expect(models[1].defaultEffort == nil)
    }

    @Test func piModelParserHandlesEmptyAndRejectsBrokenTables() throws {
        #expect(try PiModelCatalog.parse("\n").isEmpty)
        #expect(throws: ModelListError.self) {
            try PiModelCatalog.parse("provider model\nx y")
        }
        #expect(throws: ModelListError.self) {
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
        #expect(try PiModelCatalog.discover(executable: "/usr/local/bin/pi", runner: empty).isEmpty)

        let failed = HarnessCommandRunner(locate: { _ in "/usr/local/bin/pi" }, run: { _, _, _, _ in
            ProcessOutput(status: 2, stdout: "", stderr: "bad auth", timedOut: false)
        })
        #expect(throws: ModelListError.self) { try PiModelCatalog.discover(executable: "/usr/local/bin/pi", runner: failed) }

        let timedOut = HarnessCommandRunner(locate: { _ in "/usr/local/bin/pi" }, run: { _, _, _, _ in
            ProcessOutput(status: 15, stdout: "", stderr: "", timedOut: true)
        })
        #expect(throws: ModelListError.self) { try PiModelCatalog.discover(executable: "/usr/local/bin/pi", runner: timedOut) }
    }

    @Test func testClaudeModelsFromSettingsOrDefaults() {
        // The aliases are always offered, `availableModels` is added after them.
        let ids = { (models: [AgentModel]) in models.map(\.id) }
        #expect(ids(ModelFiles.claudeModels(catalogJSON: nil, settingsJSON: Data(#"{"availableModels":["claude-opus-5","claude-fable-5-1"]}"#.utf8), claudeJSON: nil))
                == ["opus", "sonnet", "fable", "haiku", "claude-opus-5", "claude-fable-5-1"])
        #expect(ids(ModelFiles.claudeModels(catalogJSON: nil, settingsJSON: Data(#"{"availableModels":["opus","claude-opus-5"]}"#.utf8), claudeJSON: nil))
                == ["opus", "sonnet", "fable", "haiku", "claude-opus-5"], "an alias repeated in settings must not appear twice")
        #expect(ids(ModelFiles.claudeModels(catalogJSON: nil, settingsJSON: Data("{}".utf8), claudeJSON: nil)) == ["opus", "sonnet", "fable", "haiku"])
        #expect(ids(ModelFiles.claudeModels(catalogJSON: nil, settingsJSON: nil, claudeJSON: nil)) == ["opus", "sonnet", "fable", "haiku"])
    }

    /// The models Claude Code itself offers beyond the aliases live in `~/.claude.json`, with the
    /// label and one-liner the CLI shows in `/model` — so the sheet lists exactly what the CLI does.
    @Test func testClaudeModelsFromClaudeJSONCache() {
        let json = Data(#"""
        {"additionalModelOptionsCache":[{"value":"claude-fable-5-1[1m]","label":"Fable","description":"Fable 5.1 · Most capable"}]}
        """#.utf8)
        let models = ModelFiles.claudeModels(catalogJSON: nil, settingsJSON: nil, claudeJSON: json)
        #expect(models.map(\.id).last == "claude-fable-5-1[1m]")
        #expect(models.last?.label == "Fable")
        #expect(models.last?.detail == "Fable 5.1 · Most capable")
        #expect(models.allSatisfy { $0.efforts == AgentKind.claude.harness.efforts(for: nil) })
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
        let models = ModelFiles.codexModels(modelsCacheJSON: cache)
        #expect(models.map(\.id) == ["gpt-5.6-sol", "gpt-5.5"], "a model marked hide is not offered")
        #expect(models[0].label == "GPT-5.6-Sol")
        #expect(models[0].detail == "Everyday workhorse.")
        #expect(models[0].efforts == ["low", "medium", "high"])
        #expect(models[0].defaultEffort == "medium")
        #expect(models[1].efforts == ["high", "xhigh"], "reasoning levels are per model, not one static list")
        #expect(models[1].defaultEffort == "xhigh")
    }

    @Test func noCacheOrAnEmptyOneOffersGPT56Alone() {
        for cache in [nil, Data("{}".utf8), Data(#"{"models":[]}"#.utf8)] {
            let models = ModelFiles.codexModels(modelsCacheJSON: cache)
            #expect(models.map(\.id) == ["gpt-5.6"])
            #expect(models.first?.efforts == AgentKind.codex.harness.efforts(for: nil))
            #expect(models.first?.defaultEffort == Harness.codex.defaultEffort)
        }
    }

    /// The reasoning list the sheet shows follows the picked model; the agent's own list stands in
    /// only when no model is picked at all. (A model that publishes an *empty* list is a different
    /// case — it takes no reasoning flag — and `testAClaudeModelWithoutThinkingOffersNoEfforts`
    /// covers it.)
    @Test func testEffortsFollowTheModel() {
        let model = AgentModel(id: "gpt-5.6-sol", label: "Sol", detail: nil, efforts: ["low", "high"], defaultEffort: "high")
        #expect(AgentKind.codex.harness.efforts(for: model) == ["low", "high"])
        #expect(AgentKind.codex.harness.efforts(for: nil) == ["minimal", "low", "medium", "high", "xhigh"])
        #expect(AgentKind.claude.harness.efforts(for: nil) == ["low", "medium", "high"])
    }

    /// Claude Code 2.1.251+ drives `/model` from a signed catalogue it caches under
    /// `~/.claude/cache/model-catalog/<org>-<hash>-cc.json`. That file — not the four aliases — is
    /// what the CLI's own picker lists, so the sheet must read it: real ids, the CLI's names and
    /// one-liners, and the effort levels each model publishes.
    @Test func testClaudeModelsFromTheModelCatalogCache() {
        let models = ModelFiles.claudeModels(catalogJSON: Fixtures.claudeCatalog, settingsJSON: nil, claudeJSON: nil)
        #expect(models.map(\.id) == ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5-20251001"],
                "the catalogue replaces the aliases; its order is the order /model shows")
        #expect(models[0].label == "Fable 5.1")
        #expect(models[0].detail == "For your toughest challenges")
        #expect(models[0].efforts == ["low", "medium", "high", "xhigh", "max"], "Claude publishes five levels, not three")
        #expect(models[0].defaultEffort == "high", "the level badged Default is the default")
    }

    /// Claude Code 2.1.311 badges its default level "Recommended", and badges Max with a warning:
    /// the recommended level is the default, never the warned one at the end.
    @Test func theLevelBadgedRecommendedIsTheDefault() {
        let models = ModelFiles.claudeModels(catalogJSON: Fixtures.claudeCatalogRecommended, settingsJSON: nil, claudeJSON: nil)
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-fable-5-1"])
        #expect(models[0].defaultEffort == "medium", "Opus 5.5 recommends medium")
        #expect(models[1].defaultEffort == "high", "Fable 5.1 recommends high")
    }

    /// A model whose levels carry no default badge falls back to Claude Code's own default, not to
    /// the costliest level at the end of the list.
    @Test func withoutADefaultBadgeTheDefaultIsHighNotTheLastLevel() {
        let catalog = Data(#"""
        {"version":2,"catalog":{"surface":"cc","config":{"id":"cc","models":[
          {"id":"claude-opus-5-5","name":"Opus 5.5","thinking":{"type":"effort","effort_options":[
            {"id":"low","name":"Low"},{"id":"medium","name":"Medium"},{"id":"high","name":"High"},{"id":"max","name":"Max"}]}},
          {"id":"claude-tiny","name":"Tiny","thinking":{"type":"effort","effort_options":[{"id":"low","name":"Low"},{"id":"medium","name":"Medium"}]}}
        ]}}}
        """#.utf8)
        let models = ModelFiles.claudeModels(catalogJSON: catalog, settingsJSON: nil, claudeJSON: nil)
        #expect(models[0].defaultEffort == "high")
        #expect(models[1].defaultEffort == "low", "without high, the least costly level")
    }

    /// `thinking: {"type": "none"}` (Haiku) means the model takes no effort flag at all.
    @Test func testAClaudeModelWithoutThinkingOffersNoEfforts() {
        let haiku = ModelFiles.claudeModels(catalogJSON: Fixtures.claudeCatalog, settingsJSON: nil, claudeJSON: nil).last
        #expect(haiku?.efforts == [])
        #expect(haiku?.defaultEffort == nil)
        #expect(AgentKind.claude.harness.efforts(for: haiku) == [])
        #expect(AgentKind.claude.harness.defaultEffort(for: haiku) == nil)
    }

    /// The extras in `~/.claude.json` are still merged in after the catalogue — the 1M-context
    /// variants live there and the catalogue does not list them.
    @Test func testClaudeCatalogueIsExtendedByTheClaudeJSONCache() {
        let json = Data(#"""
        {"additionalModelOptionsCache":[{"value":"claude-fable-5-1[1m]","label":"Fable","description":"Fable 5.1 · 1M context"}]}
        """#.utf8)
        let ids = ModelFiles.claudeModels(catalogJSON: Fixtures.claudeCatalog, settingsJSON: nil, claudeJSON: json).map(\.id)
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
        let models = ModelFiles.claudeModels(catalogJSON: Fixtures.claudeCatalog, settingsJSON: nil, claudeJSON: json)
        let by = { (id: String) in models.first { $0.id == id } }
        #expect(by("claude-fable-5-1[1m]")?.efforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(by("claude-fable-5-1[1m]")?.defaultEffort == "high")
        #expect(by("claude-haiku-4-5-20251001[1m]")?.efforts == [], "Haiku takes no effort flag in either context size")
        #expect(by("some-unknown-model")?.efforts == AgentKind.claude.harness.efforts(for: nil), "nothing to inherit from: the three-level fallback")
    }

    /// No catalogue on disk (a fresh install, or a CLI too old to write one) falls back to the
    /// aliases exactly as before, so the sheet is never empty.
    @Test func testClaudeFallsBackToAliasesWithoutACatalogue() {
        #expect(ModelFiles.claudeModels(catalogJSON: nil, settingsJSON: nil, claudeJSON: nil).map(\.id) == ["opus", "sonnet", "fable", "haiku"])
        #expect(ModelFiles.claudeModels(catalogJSON: Data("{}".utf8), settingsJSON: nil, claudeJSON: nil).map(\.id) == ["opus", "sonnet", "fable", "haiku"],
                "an empty catalogue is not an answer")
    }

    /// The reasoning levels must follow the Claude model too, not a single static list.
    @Test func testClaudeEffortsFollowTheModel() {
        let fable = ModelFiles.claudeModels(catalogJSON: Fixtures.claudeCatalog, settingsJSON: nil, claudeJSON: nil)[0]
        #expect(AgentKind.claude.harness.efforts(for: fable) == ["low", "medium", "high", "xhigh", "max"])
        #expect(AgentKind.claude.harness.efforts(for: nil) == ["low", "medium", "high"], "no model picked: the legacy three")
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
        #expect(ModelCatalogue(home: home, runner: .nothingInstalled).read(.claude).models.map(\.id).first == "claude-fable-5-1")
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

        /// Trimmed from a real catalogue (CLI 2.1.311): the default is badged "Recommended", Max warns.
        static let claudeCatalogRecommended = Data(#"""
        {"version":2,"catalog":{"surface":"cc","config":{"id":"cc","models":[
          {"id":"claude-opus-5-5","name":"Opus 5.5","short_name":"Opus","section":"main",
           "thinking":{"type":"effort","effort_options":[{"id":"low","name":"Low"},
             {"id":"medium","name":"Medium","badge":{"message":"Recommended","variant":"neutral"}},{"id":"high","name":"High"},
             {"id":"xhigh","name":"Extra"},{"id":"max","name":"Max","badge":{"message":"3.5× or more usage","variant":"warning"}}]}},
          {"id":"claude-fable-5-1","name":"Fable 5.1","short_name":"Fable","section":"main",
           "thinking":{"type":"effort","effort_options":[{"id":"low","name":"Low"},{"id":"medium","name":"Medium"},
             {"id":"high","name":"High","badge":{"message":"Recommended","variant":"neutral"}},{"id":"xhigh","name":"Extra"},{"id":"max","name":"Max"}]}}
        ]}}}
        """#.utf8)
    }
}

@Suite struct AgyModelCatalogTests {
    /// `agy models` prints one id and label a row, tab-separated; its progress line goes to stderr.
    /// A model's rows fold into one model, its efforts in order and medium its default; a row whose
    /// label names no effort is a model without levels.
    @Test func agyModelsFoldEachModelsEffortRows() throws {
        let output = "gemini-4-neon-high\tGemini 4 Neon (High)\ngemini-4-neon-xhigh\tGemini 4 Neon (XHigh)\n"
            + "gemini-4-neon-low\tGemini 4 Neon (Low)\ngemini-4-neon-medium\tGemini 4 Neon (Medium)\n"
            + "gemini-3.1-pro-low\tGemini 3.1 Pro (Low)\ngemini-3.1-pro-high\tGemini 3.1 Pro (High)\n\n"
            + "gemini-pro-orchestrator\tOrchestrator\n"
        let models = try AgyModelCatalog.parse(output)
        #expect(models == [
            AgentModel(id: "gemini-4-neon", label: "Gemini 4 Neon", detail: nil,
                       efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium"),
            AgentModel(id: "gemini-3.1-pro", label: "Gemini 3.1 Pro", detail: nil, efforts: ["low", "high"], defaultEffort: "low"),
            AgentModel(id: "gemini-pro-orchestrator", label: "Orchestrator", detail: nil, efforts: [], defaultEffort: nil),
        ])
    }

    /// The launch joins a model and its effort into the CLI's own id, and leaves one that names it already.
    @Test func agyCLIModelJoinsTheEffort() {
        #expect(AgyModelCatalog.cliModel("gemini-4-neon", reasoning: "high") == "gemini-4-neon-high")
        #expect(AgyModelCatalog.cliModel("gemini-4-neon-high", reasoning: "high") == "gemini-4-neon-high")
        #expect(AgyModelCatalog.cliModel("gemini-pro-orchestrator", reasoning: nil) == "gemini-pro-orchestrator")
        #expect(AgyModelCatalog.cliModel("gemini-pro-orchestrator", reasoning: "") == "gemini-pro-orchestrator")
    }

    /// A default saved as the CLI's full id, before the catalogue folded efforts, reads as its model at that effort.
    @Test func aSavedAgyIdThatNamesItsEffortResolvesToItsModel() throws {
        let defaults = ScratchDefaults.make()
        ModelSettings.save(ModelPreference(model: "gemini-4-neon-high", reasoning: nil), for: .agy, defaults: defaults)
        let catalog = try AgyModelCatalog.parse("gemini-4-neon-low\tGemini 4 Neon (Low)\ngemini-4-neon-high\tGemini 4 Neon (High)\n")
        #expect(ModelSettings.resolution(for: .agy, catalog: catalog, defaults: defaults)
                == .valid(ModelPreference(model: "gemini-4-neon", reasoning: "high")))
        #expect(ModelSettings.resolution(for: .agy, catalog: catalog, remembered: "gemini-4-neon-low", defaults: ScratchDefaults.make())
                == .valid(ModelPreference(model: "gemini-4-neon", reasoning: "low")))
    }

    @Test func agyModelParserRejectsARowWithoutItsLabel() throws {
        #expect(throws: ModelListError.malformed(.agy, "Malformed Antigravity model row: gemini-4-neon-high")) {
            try AgyModelCatalog.parse("gemini-4-neon-high\n")
        }
        #expect(try AgyModelCatalog.parse("").isEmpty)
    }

    @Test func agyDiscoveryRunsModelsAndWordsItsFailures() throws {
        let listed = HarnessCommandRunner(locate: { _ in "/usr/local/bin/agy" }, run: { _, arguments, _, timeout in
            #expect(arguments == ["models"])
            #expect(timeout == 15)
            return ProcessOutput(status: 0, stdout: "gemini-4-neon-high\tGemini 4 Neon (High)\n", stderr: "Fetching available models...\n", timedOut: false)
        })
        #expect(try AgyModelCatalog.discover(executable: "/usr/local/bin/agy", runner: listed).map(\.id) == ["gemini-4-neon"])

        let failed = HarnessCommandRunner(locate: { _ in "/usr/local/bin/agy" }, run: { _, _, _, _ in
            ProcessOutput(status: 1, stdout: "", stderr: "Fetching available models...\nauthentication required", timedOut: false)
        })
        #expect(throws: ModelListError.failed(.agy, 1, "Fetching available models...\nauthentication required")) {
            try AgyModelCatalog.discover(executable: "/usr/local/bin/agy", runner: failed)
        }
        #expect(ModelListError.failed(.agy, 1, "Fetching available models...\nauthentication required").localizedDescription
                == "The Antigravity model catalogue is unavailable: authentication required")
    }
}
