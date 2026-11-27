import Foundation
import AiTermCore

enum OperatorSkills {
    /// The workers' agents (`AgentKind.fullSupport`), whose skills a signal's prompt can name.
    static var agents: [AgentKind] { AgentKind.fullSupport }

    /// Installed Antigravity plugins are shared by all projects in a single Signal sheet.
    static func listed(at paths: [String?], home: URL, config: ClaudeConfig, skills: NativeSkills) -> [AgentCompletion] {
        let plugins = skills.antigravityPlugins(home: home)
        return listed(at: paths) { agent, project in
            skills.discover(agent: agent, projectPath: project, home: home, claudeConfig: config, plugins: plugins)
        }
    }

    /// Each agent's skills at each of `paths` (nil: the home alone), every name once, in that order. Blocking.
    static func listed(at paths: [String?], _ skills: (AgentKind, String?) -> [AgentCompletion]) -> [AgentCompletion] {
        var seen = Set<String>(), all: [AgentCompletion] = []
        for agent in agents {
            for path in paths {
                for item in skills(agent, path) where seen.insert(item.name).inserted { all.append(item) }
            }
        }
        return all
    }
}
