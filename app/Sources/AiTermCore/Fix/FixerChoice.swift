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

/// Settings › Agents' “Fix with AI”: whether Fix buttons are offered, and the agent they ask. The
/// agent is kept while the switch is off, so turning it back on asks the same one.
public struct FixerChoice: Equatable, Sendable {
    public var isOn: Bool
    public var agent: FixerAgent

    public init(isOn: Bool, agent: FixerAgent) {
        self.isOn = isOn
        self.agent = agent
    }

    /// On, asking `fixer`.
    public static func agent(_ fixer: FixerAgent) -> FixerChoice { FixerChoice(isOn: true, agent: fixer) }
    /// Off, keeping `fixer` for when it is turned back on.
    public static func off(keeping fixer: FixerAgent = FixerAgent.allCases[0]) -> FixerChoice {
        FixerChoice(isOn: false, agent: fixer)
    }

    /// The chosen agent when it is installed, else that agent named as missing — never another
    /// vendor's (spec §3, decision 7).
    public func resolve(installed: Set<AgentKind>) -> FixerResolution {
        guard isOn else { return .off }
        return installed.contains(agent.agent) ? .ready(agent) : .missing(agent)
    }
}

public enum FixerResolution: Equatable, Sendable {
    case ready(FixerAgent)
    /// Greyed, its tooltip naming the agent that is not installed.
    case missing(FixerAgent)
    case off
}

public enum FixerSettings {
    /// The agent — or, from a version before the switch, `off`, read as any unknown value is.
    private static let key = "fixer"
    /// Whether the switch is on; missing before the switch existed, when an agent in `key` meant on.
    private static let isOnKey = "fixerIsOn"

    /// The choice the person made — or that first launch saved for them — and nil before either.
    /// Never saves, so the app can tell a first launch from a later one. A value this version does
    /// not know reads as Off, keeping the first fixer.
    public static func saved(defaults: UserDefaults) -> FixerChoice? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        guard let fixer = FixerAgent(rawValue: raw) else { return .off() }
        let isOn = defaults.object(forKey: isOnKey) as? Bool ?? true
        return FixerChoice(isOn: isOn, agent: fixer)
    }

    /// The saved choice; on first launch the first installed fixer, switched on, saved at once so a
    /// later install never changes it. With none installed, Off.
    public static func load(defaults: UserDefaults, installed: Set<AgentKind>) -> FixerChoice {
        if let saved = saved(defaults: defaults) { return saved }
        let first = FixerAgent.allCases.first { installed.contains($0.agent) }
        let choice = first.map(FixerChoice.agent) ?? .off()
        save(choice, defaults: defaults)
        return choice
    }

    public static func save(_ choice: FixerChoice, defaults: UserDefaults) {
        defaults.set(choice.agent.rawValue, forKey: key)
        defaults.set(choice.isOn, forKey: isOnKey)
    }
}
