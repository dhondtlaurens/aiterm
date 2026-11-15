import Foundation
import AiTermCore

enum OperatorSkills {
    static let agents: [AgentKind] = [.claude, .codex]

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
