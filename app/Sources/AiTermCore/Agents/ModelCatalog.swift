import Foundation

/// One entry of an agent's model list. `id` is what goes on the command line; `label` and `detail`
/// are what the CLI itself shows for it, so the sheet reads like the agent's own `/model` picker.
public struct AgentModel: Equatable, Hashable, Identifiable, Sendable {
    public var id: String, label: String, detail: String?, efforts: [String], defaultEffort: String?
    public init(id: String, label: String, detail: String?, efforts: [String], defaultEffort: String?) {
        self.id = id; self.label = label; self.detail = detail; self.efforts = efforts; self.defaultEffort = defaultEffort
    }
}

public enum ModelCatalog {
    public static let claudeAliases = ["opus", "sonnet", "fable", "haiku"]
    public static let claudeEfforts = ["low", "medium", "high"]
    public static let codexEfforts = ["minimal", "low", "medium", "high", "xhigh"]

    // -- claude ---------------------------------------------------------------------

    /// Spec 4.3, widened twice by real runs. Claude Code 2.1.251+ drives its own `/model` picker
    /// from a signed catalogue it caches under `~/.claude/cache/model-catalog/<org>-<hash>-cc.json`
    /// — real ids, the CLI's names and one-liners, and the effort levels each model publishes. That
    /// file is the list, so the sheet reads it exactly as it reads Codex's `models_cache.json`.
    /// Anything Claude Code caches as an *extra* option in `~/.claude.json`
    /// (`additionalModelOptionsCache`, where the 1M-context variants live) is appended, as is
    /// `availableModels` from `~/.claude/settings.json`. Only when there is no catalogue at all —
    /// a fresh install, or a CLI too old to write one — do the four aliases stand in for it.
    public static func claudeModels(catalogJSON: Data?, settingsJSON: Data?, claudeJSON: Data?) -> [AgentModel] {
        var out = claudeCatalogModels(catalogJSON)
        if out.isEmpty {
            out = claudeAliases.map { AgentModel(id: $0, label: $0.capitalized, detail: nil, efforts: claudeEfforts, defaultEffort: "high") }
        }
        func add(_ model: AgentModel) { if !out.contains(where: { $0.id == model.id }) { out.append(model) } }

        if let data = settingsJSON, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = obj["availableModels"] as? [String] {
            for id in models { add(AgentModel(id: id, label: id, detail: nil, efforts: claudeEfforts, defaultEffort: "high")) }
        }
        if let data = claudeJSON, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let options = obj["additionalModelOptionsCache"] as? [[String: Any]] {
            for option in options {
                guard let id = option["value"] as? String, !id.isEmpty else { continue }
                // `claude-fable-5-1[1m]` is the same model in a bigger context window, so it
                // supports the same reasoning levels; only something the catalogue does not know
                // at all falls back to the legacy three.
                let base = out.first { $0.id == id.prefix(while: { $0 != "[" }) }
                add(AgentModel(id: id, label: (option["label"] as? String) ?? id, detail: option["description"] as? String,
                               efforts: base?.efforts ?? claudeEfforts, defaultEffort: base.map(\.defaultEffort) ?? "high"))
            }
        }
        return out
    }

    /// `catalog.config.models[]` of the cached model catalogue, in the order `/model` shows them.
    /// `thinking.type == "effort"` publishes the levels; the one badged `Default` is the default.
    /// `thinking.type == "none"` (Haiku) means the model takes no `--effort` at all, which is why
    /// an empty `efforts` is a real answer here and not a missing one.
    static func claudeCatalogModels(_ catalogJSON: Data?) -> [AgentModel] {
        guard let data = catalogJSON, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = root["catalog"] as? [String: Any], let config = catalog["config"] as? [String: Any],
              let raw = config["models"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let thinking = entry["thinking"] as? [String: Any]
            let options = (thinking?["type"] as? String) == "effort" ? (thinking?["effort_options"] as? [[String: Any]] ?? []) : []
            let efforts = options.compactMap { $0["id"] as? String }
            let defaultEffort = options.first { ($0["badge"] as? [String: Any])?["message"] as? String == "Default" }?["id"] as? String
            return AgentModel(id: id, label: (entry["name"] as? String) ?? id, detail: entry["description"] as? String,
                              efforts: efforts, defaultEffort: defaultEffort ?? efforts.last)
        }
    }

    /// The cache file is named `<org id>-<hash>-<surface>.json`; `cc` is Claude Code's own surface.
    /// Neither part is knowable in advance, so the newest `-cc.json` in the directory is the one.
    static func claudeCatalogURL(home: URL) -> URL? {
        let dir = home.appendingPathComponent(".claude/cache/model-catalog")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.filter { $0.hasSuffix("-cc.json") }.map(dir.appendingPathComponent)
            .max { a, b in modified(a) < modified(b) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // -- codex ----------------------------------------------------------------------

    /// Codex keeps its real catalogue in `~/.codex/models_cache.json`: the display names, the
    /// reasoning levels each model supports and its default level. Models marked `hide` are the
    /// CLI's internal ones (auto-review, reserve) and are not offered. When the cache is missing or
    /// empty — a fresh install, or a network the CLI could not reach — the profiles in
    /// `config.toml` are the fallback, and `gpt-5.6` the last resort.
    public static func codexModels(modelsCacheJSON: Data?, configTOML: String?) -> [AgentModel] {
        if let data = modelsCacheJSON, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["models"] as? [[String: Any]] {
            let models: [AgentModel] = raw.compactMap { entry in
                guard let slug = entry["slug"] as? String, !slug.isEmpty else { return nil }
                guard (entry["visibility"] as? String) != "hide" else { return nil }
                let efforts = (entry["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? []
                return AgentModel(id: slug, label: (entry["display_name"] as? String) ?? slug, detail: entry["description"] as? String,
                                  efforts: efforts.isEmpty ? codexEfforts : efforts,
                                  defaultEffort: entry["default_reasoning_level"] as? String)
            }
            if !models.isEmpty { return models }
        }
        return codexConfigModels(configTOML: configTOML)
    }

    /// The root `model` and each `profiles.<name>.model`, in file order, by the key's full path:
    /// a header or dotted key names them alike, and a `model = …` line inside a multi-line string
    /// is not one.
    static func codexConfigModels(configTOML: String?) -> [AgentModel] {
        var ids: [String] = []
        for table in TOMLStatements.tables(configTOML ?? "") where !table.array {
            for statement in table.statements {
                guard let key = statement.keyPath, let value = statement.value, !value.isEmpty else { continue }
                let path = table.path + key
                guard path == ["model"] || (path.count == 3 && path[0] == "profiles" && path[2] == "model") else { continue }
                if !ids.contains(value) { ids.append(value) }
            }
        }
        if ids.isEmpty { ids = ["gpt-5.6"] }
        return ids.map { AgentModel(id: $0, label: $0, detail: nil, efforts: codexEfforts, defaultEffort: "medium") }
    }

    // -- lookup ---------------------------------------------------------------------

    public static func models(for agent: AgentKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentModel] {
        switch agent {
        case .claude:
            return claudeModels(catalogJSON: claudeCatalogURL(home: home).flatMap { try? Data(contentsOf: $0) },
                                settingsJSON: try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json")),
                                claudeJSON: try? Data(contentsOf: home.appendingPathComponent(".claude.json")))
        case .codex:
            return codexModels(modelsCacheJSON: try? Data(contentsOf: home.appendingPathComponent(".codex/models_cache.json")),
                               configTOML: try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8))
        case .grok:
            return GrokModelCatalog.models(home: home)
        case .pi:
            return (try? PiModelCatalog.discover()) ?? []
        }
    }

    /// The reasoning levels for the picked model. Both CLIs publish them per model now, so the
    /// agent's own list is only the answer when no model is picked, or when the picked model comes
    /// from a source that carries no levels (the aliases, `availableModels`). A model that
    /// publishes *no* levels — Haiku, whose catalogue entry says `thinking: none` — is not that
    /// case: it genuinely takes no reasoning flag, and returning an empty list says so.
    public static func efforts(for agent: AgentKind, model: AgentModel?) -> [String] {
        guard let model else {
            switch agent {
            case .claude: return claudeEfforts
            case .codex: return codexEfforts
            case .grok: return ["low", "medium", "high", "xhigh"]
            case .pi: return PiModelCatalog.thinkingLevels
            }
        }
        return model.efforts
    }

    public static func defaultEffort(for agent: AgentKind, model: AgentModel?) -> String? {
        guard let model else {
            switch agent {
            case .claude, .grok: return "high"
            case .codex, .pi: return "medium"
            }
        }
        return model.defaultEffort
    }
}
