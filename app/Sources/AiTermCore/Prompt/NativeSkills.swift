import Foundation

/// One read per catalogue load. Only the filesystem portion belongs in SkillCatalog's stamp cache:
/// package sources and enablement can change without touching any of its watched paths.
public struct NativeSkills: Sendable {
    typealias Query = @Sendable (AgentKind, URL?, [String: String]) -> String?
    private var piDirectory: @Sendable () -> String? = { nil }
    private var query: Query?

    private init() {}

    init(piDirectory: @escaping @Sendable () -> String? = { nil }, query: @escaping Query) {
        self.piDirectory = piDirectory
        self.query = query
    }

    public static let filesystem = NativeSkills()
    static let request = #"{"type":"get_commands","id":"aiterm-skills"}"# + "\n"

    public static let live = NativeSkills(piDirectory: { LoginShellLocator.shared.current()?.piAgentDirectory }) { agent, cwd, environment in
        let harness = agent.harness
        guard let arguments = harness.skillListArguments, let executable = HarnessCommandRunner.live.locate(harness.executable),
              let output = try? HarnessCommandRunner.launch(executable, arguments, environment, 5, in: cwd,
                  input: agent == .pi ? Data(request.utf8) : nil, limit: 4 * 1024 * 1024),
              output.status == 0, !output.timedOut, !output.stdoutTruncated else { return nil }
        return output.stdout
    }

    public func antigravityPlugins(home: URL) -> [AgentCompletion] {
        struct Plugin: Decodable { let name: String, enabled: Bool, path: String?, skills: [String]? }
        guard let output = query?(.agy, nil, ["HOME": home.path]),
              let plugins = try? JSONDecoder().decode([Plugin].self, from: Data(output.utf8)) else { return [] }
        var found: [AgentCompletion] = []
        for plugin in plugins where plugin.enabled {
            let root = plugin.path.map { URL(fileURLWithPath: $0).appendingPathComponent("skills") }
            for name in plugin.skills ?? [] {
                let leaf = SkillCatalog.leafName(name)
                let description = root.flatMap { SkillCatalog.frontmatter(of: $0.appendingPathComponent(leaf).appendingPathComponent("SKILL.md"))["description"] }
                found.append(AgentCompletion(name: SkillCatalog.qualify(name, with: plugin.name), kind: .skill,
                                             detail: description, source: .plugin(plugin.name)))
            }
        }
        return found
    }

    /// For a new worktree the RPC runs in its source checkout, but destination trust controls
    /// which project suggestions may be carried forward. An existing checkout is queried directly.
    public func discover(agent: AgentKind, projectPath: String?, prospectivePath: String? = nil, home: URL,
                         claudeConfig: ClaudeConfig = ClaudeConfig(), plugins: [AgentCompletion]? = nil) -> [AgentCompletion] {
        guard let query, agent == .pi, let projectPath else {
            let disk = SkillCatalog.discover(agent: agent, projectPath: projectPath, home: home, claudeConfig: claudeConfig)
            guard agent == .agy else { return disk }
            return SkillCatalog.ordered(disk + (plugins ?? antigravityPlugins(home: home)))
        }

        let project = URL(fileURLWithPath: projectPath, isDirectory: true)
        let directory = piDirectory().map { value in
            if value == "~" { return home }
            if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
            return URL(fileURLWithPath: value, relativeTo: project).standardizedFileURL
        } ?? home.appendingPathComponent(".pi/agent")
        let disk = SkillCatalog.discover(agent: .pi, projectPath: projectPath, home: home, piDirectory: directory)
        let templates = disk.filter { $0.kind == .command }
        let destination = prospectivePath.map { URL(fileURLWithPath: $0) } ?? project
        let settings = PiSkillSettings(agentDirectory: directory, project: project, destination: destination)
        guard settings.enabled else { return templates }
        let env = ["HOME": home.path, "PI_CODING_AGENT_DIR": directory.path, "PI_OFFLINE": "1"]
        let native = query(.pi, project, env).flatMap(Self.piSkills)
        let previewLoose = prospectivePath != nil && settings.trust != false
            && (settings.trust == nil || !settings.sourceTrusted)
        let eligible: (AgentCompletion) -> Bool = { $0.source != .project || settings.trust == true }
        guard let native else {
            return disk.filter { $0.kind == .command || eligible($0) || previewLoose }
        }
        let preview = previewLoose ? disk.filter { $0.source == .project && $0.kind == .skill } : []
        return SkillCatalog.ordered(templates + native.filter(eligible) + preview)
    }

    static func piSkills(_ output: String) -> [AgentCompletion]? {
        struct Reply: Decodable {
            struct Payload: Decodable {
                struct Command: Decodable {
                    struct Info: Decodable { let scope: String }
                    let name: String, source: String, description: String?, sourceInfo: Info?
                }
                let commands: [Command]
            }
            let id: String, type: String, command: String, success: Bool, data: Payload?
        }
        for line in output.split(whereSeparator: \.isNewline) {
            guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(line.utf8)),
                  reply.id == "aiterm-skills", reply.type == "response", reply.command == "get_commands" else { continue }
            guard reply.success, let payload = reply.data else { return nil }
            var found: [AgentCompletion] = []
            for item in payload.commands where item.source == "skill" {
                guard item.name.hasPrefix("skill:"), let scope = item.sourceInfo?.scope,
                      ["user", "project"].contains(scope) else { return nil }
                found.append(AgentCompletion(name: item.name, kind: .skill, detail: item.description,
                                             source: scope == "project" ? .project : .user))
            }
            return found
        }
        return nil
    }
}

private struct PiSkillSettings {
    let enabled: Bool, trust: Bool?, sourceTrusted: Bool

    init(agentDirectory: URL, project: URL, destination: URL) {
        struct Settings: Decodable {
            struct Legacy: Decodable { var enableSkillCommands: Bool? }
            var enableSkillCommands: Bool?, defaultProjectTrust: String?
            var skills: Legacy?
            private enum CodingKeys: CodingKey { case enableSkillCommands, defaultProjectTrust, skills }
            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                enableSkillCommands = try fields.decodeIfPresent(Bool.self, forKey: .enableSkillCommands)
                defaultProjectTrust = try fields.decodeIfPresent(String.self, forKey: .defaultProjectTrust)
                // Current settings use an array for skills; the older object held this preference.
                skills = try? fields.decode(Legacy.self, forKey: .skills)
            }
            var enabled: Bool? { enableSkillCommands ?? skills?.enableSkillCommands }
        }
        func read<T: Decodable>(_ type: T.Type, _ file: URL) -> T? {
            guard let bytes = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(type, from: bytes)
        }
        let global = read(Settings.self, agentDirectory.appendingPathComponent("settings.json"))
        let decisions = read([String: Bool?].self, agentDirectory.appendingPathComponent("trust.json"))?.compactMapValues { $0 } ?? [:]
        func decision(at url: URL) -> Bool? {
            var folder = CanonicalPath.of(url.path)
            while !folder.isEmpty {
                if let value = decisions[folder] { return value }
                if folder == "/" { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
            switch global?.defaultProjectTrust {
            case "always": return true
            case "never": return false
            default: return nil
            }
        }
        trust = decision(at: destination)
        sourceTrusted = decision(at: project) == true
        let local = trust == true ? read(Settings.self, project.appendingPathComponent(".pi/settings.json")) : nil
        enabled = local?.enabled ?? global?.enabled ?? true
    }
}
