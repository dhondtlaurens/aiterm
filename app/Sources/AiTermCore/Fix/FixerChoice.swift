import Foundation

/// An agent AiTerm can ask to fix a problem unattended: one whose CLI has a headless mode with a
/// JSON-schema answer, a sandbox that turns its commands' network off on macOS, a per-run switch
/// for hooks and a resumable session. Grok Build lacks the network-off and the hook switch on
/// macOS (spikes, 2026-10-14); PI has none of these.
public enum FixerAgent: String, Codable, CaseIterable, Sendable {
    case claude, codex

    public var agent: AgentKind {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }

    /// What the button says after “Fix with”: the vendor's short name, not the CLI's display name.
    public var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

public extension AgentKind {
    var fixer: FixerAgent? { FixerAgent(rawValue: rawValue) }
}

/// Settings › Agents' “Fix problems with”.
public enum FixerChoice: Equatable, Sendable {
    case agent(FixerAgent)
    case off

    /// The chosen agent when it is installed, else that agent named as missing — never another
    /// vendor's (spec §3, decision 7).
    public func resolve(installed: Set<AgentKind>) -> FixerResolution {
        switch self {
        case .off: .off
        case .agent(let fixer): installed.contains(fixer.agent) ? .ready(fixer) : .missing(fixer)
        }
    }
}

public enum FixerResolution: Equatable, Sendable {
    case ready(FixerAgent)
    /// Greyed, its tooltip naming the agent that is not installed.
    case missing(FixerAgent)
    case off
}

public enum FixerSettings {
    private static let key = "fixer"

    /// The saved choice; on first launch the first installed fixer, saved at once so a later
    /// install never changes it. A value this version does not know reads as Off.
    public static func load(defaults: UserDefaults, installed: Set<AgentKind>) -> FixerChoice {
        if let raw = defaults.string(forKey: key) {
            return raw == "off" ? .off : FixerAgent(rawValue: raw).map(FixerChoice.agent) ?? .off
        }
        let first = FixerAgent.allCases.first { installed.contains($0.agent) }
        let choice = first.map(FixerChoice.agent) ?? .off
        save(choice, defaults: defaults)
        return choice
    }

    public static func save(_ choice: FixerChoice, defaults: UserDefaults) {
        switch choice {
        case .off: defaults.set("off", forKey: key)
        case .agent(let fixer): defaults.set(fixer.rawValue, forKey: key)
        }
    }
}
