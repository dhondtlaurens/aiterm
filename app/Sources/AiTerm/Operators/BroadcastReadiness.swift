import Foundation
import AiTermCore

/// What New Broadcast's Start waits for: every agent the Operator may plan on — Claude Code and Codex,
/// those installed (`ModelChoice.pair`) — Ready on its Settings card, Messaging included, and iTerm2's
/// own delivery checks passed. The Operator's own wake line needs no Messaging pass, but its workers'
/// steers do, so every agent it may plan a task on is waited for. Each piece not ready is one line, in
/// the words its card says it, so the footer and Settings never disagree.
enum BroadcastReadiness: Equatable {
    /// A piece is still being read, and none read so far is not ready.
    case checking
    case ready
    /// One line per piece not ready; a piece still being read meanwhile is left out.
    case notReady([String])

    /// The footer Notice's title over the lines.
    static let title = "Not ready to start"

    var lines: [String] { if case .notReady(let lines) = self { lines } else { [] } }

    /// `installed` are the agent CLIs on this Mac, `snapshots` the cards' probes, `messaging` each
    /// agent's Messaging and `iterm` iTerm2's own checks; nil where not read yet.
    static func of(installed: Set<AgentKind>, snapshots: [AgentKind: HarnessSnapshot],
                   messaging: (AgentKind) -> DeliveryReadiness?, iterm: DeliveryReadiness?) -> BroadcastReadiness {
        let agents = ModelChoice.pair.filter(installed.contains)
        guard !agents.isEmpty else { return .notReady(["No agent to plan on: install Claude Code or Codex in Settings › Agents"]) }
        var lines: [String] = [], reading = false
        for agent in agents {
            guard let snapshot = snapshots[agent], let messaging = messaging(agent) else { reading = true; continue }
            let card = HarnessCardPresentation.snapshot(snapshot, messaging: messaging)
            if card.health != .ready { lines.append("\(agent.displayName): \(HarnessCardPresentation.status(for: card).text)") }
        }
        switch iterm {
        case nil: reading = true
        case .needsAttention(let sentence)?: lines.append(sentence)
        case .ready?: break
        }
        if !lines.isEmpty { return .notReady(lines) }
        return reading ? .checking : .ready
    }
}
