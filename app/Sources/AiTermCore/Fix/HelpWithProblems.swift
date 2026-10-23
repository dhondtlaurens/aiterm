import Foundation

/// Help with problems runs as the Operator, whose agent is Claude.
public enum FixerAgent: Sendable {
    // Codex remains only until the app's legacy fix-session fixtures are migrated.
    case claude, codex
    public var agent: AgentKind { self == .claude ? .claude : .codex }
    public var shortName: String { self == .claude ? "Claude" : "Codex" }
}

/// Settings › Agents' “Help with problems”: whether a problem AiTerm hits offers Find a Fix. The fix
/// runs as the Operator (spec §8, §13): its agent is always Claude, at Settings › Operator's model and
/// reasoning, so the one choice left is the switch. Without Claude Code it is off, whatever was saved.
public struct HelpWithProblems: Equatable, Sendable {
    public var isOn: Bool

    public init(isOn: Bool) { self.isOn = isOn }

    /// The UserDefaults key. The old Fix with AI keys (`fixer`, `fixerIsOn`) are not read.
    public static let key = "operator.helpWithProblems"

    /// Whether the switch can be on: the Operator's agent, Claude Code, is installed.
    public func isAvailable(installed: Set<AgentKind>) -> Bool { installed.contains(.claude) }

    /// Claude when the switch is on and Claude Code is installed; Off otherwise. Never another vendor.
    public func resolve(installed: Set<AgentKind>) -> FixerResolution {
        isOn && isAvailable(installed: installed) ? .ready(.claude) : .off
    }

    /// The saved switch; on until it is turned off.
    public static func load(defaults: UserDefaults) -> HelpWithProblems {
        HelpWithProblems(isOn: defaults.object(forKey: key) as? Bool ?? true)
    }

    public static func save(_ choice: HelpWithProblems, defaults: UserDefaults) {
        defaults.set(choice.isOn, forKey: key)
    }
}

/// What every Find a Fix is: the agent it asks, or Off — no button.
public enum FixerResolution: Equatable, Sendable {
    case ready(FixerAgent)
    case off
}
