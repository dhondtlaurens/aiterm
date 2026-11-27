import Foundation
import AiTermCore

/// Advice about the signal’s own installed agents and iTerm2 before its tasks start. Each piece
/// that needs attention is one line in its Settings card’s words, with Messaging included.
enum SignalReadiness: Equatable {
    /// A piece is still being read, and none read so far is not ready.
    case checking
    case ready
    /// One line per piece not ready; a piece still being read meanwhile is left out.
    case notReady([String])

    /// The footer Notice's title over the lines.
    static let title = "Fix this before its tasks start"
    static let checkingTitle = "Checking agents…"

    var lines: [String] { if case .notReady(let lines) = self { lines } else { [] } }

    /// `installed` are the agent CLIs on this Mac, `snapshots` the cards' probes, `messaging` each
    /// agent's Messaging and `iterm` iTerm2's own checks; nil where not read yet.
    static func of(agents: [AgentKind], installed: Set<AgentKind>, snapshots: [AgentKind: HarnessSnapshot],
                   messaging: (AgentKind) -> DeliveryReadiness?, iterm: DeliveryReadiness?, showingModels: Bool = false) -> SignalReadiness {
        guard installed.contains(.claude) else { return .notReady(["The Operator needs Claude Code. Install it in Settings › Agents."]) }
        let agents = AgentCommand.workerAgents.filter { agents.contains($0) && installed.contains($0) }
        var lines: [String] = [], reading = false
        for agent in agents {
            guard let snapshot = snapshots[agent], let messaging = messaging(agent) else { reading = true; continue }
            let card = HarnessCardPresentation.snapshot(snapshot, messaging: messaging)
            if card.health == .ready { continue }
            if showingModels, card.checks.contains(where: { $0.id == .models && !$0.passed }) {
                // The picker explains Models here. Surface any remaining failed check.
                if let other = card.checks.first(where: { $0.id != .models && !$0.passed })?.explanation {
                    lines.append("\(agent.displayName): \(other)")
                }
            } else {
                lines.append("\(agent.displayName): \(HarnessCardPresentation.status(for: card).text)")
            }
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
