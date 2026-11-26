import Testing
import Foundation
@testable import AiTermCore

/// Each agent's support tier (`Harness.support`), what is derived from it, and the daemon's copy of it.
@Suite struct SupportTierTests {
    @Test func claudeAndCodexAreFullAndPiIsBasic() {
        #expect(Harness.claude.support == .full)
        #expect(Harness.codex.support == .full)
        #expect(Harness.pi.support == .basic)
        #expect(AgentKind.fullSupport == [.claude, .codex])
    }

    /// Workers, the delivery check and the Operator's skills follow the tier, never a list of their own.
    @Test func theFullTierListsAreDerivedFromIt() {
        #expect(AgentCommand.workerAgents == AgentKind.fullSupport)
        #expect(DeliveryCheck.agents == AgentKind.fullSupport)
    }

    /// The daemon gives each agent the same tier (`aitermd/models.py`, `support="full"` on its row).
    @Test func theDaemonAgreesOnEachAgentsTier() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/aitermd/models.py")
        let python = try String(contentsOf: file, encoding: .utf8)
        let tiers = Self.daemonTiers(in: python)
        #expect(Set(tiers.keys) == Set(AgentKind.allCases.map(\.rawValue)))
        for agent in AgentKind.allCases {
            #expect(tiers[agent.rawValue] == agent.harness.support.rawValue, "\(agent.rawValue)'s tier differs in models.py")
        }
    }

    /// The reader itself, so a comparison that quietly reads nothing cannot pass.
    @Test func theReaderReadsEachRowsTier() {
        let python = """
        HARNESSES: tuple[Harness, ...] = (
            Harness("claude", "/hook/claude", support="full",
                    input_box=("x",)),
            # a comment naming Harness("nope")
            Harness("pi", "/hook/pi"),
        )
        """
        #expect(Self.daemonTiers(in: python) == ["claude": "full", "pi": "basic"])
    }

    /// Each `Harness("<agent>", …)` row of the `HARNESSES` table and its `support`, `basic` when unset.
    static func daemonTiers(in python: String) -> [String: String] {
        guard let start = python.range(of: "HARNESSES: tuple[Harness, ...] = (") else { return [:] }
        let table = python[start.upperBound...]
        let lines = table.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix(")") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let rows = lines.joined(separator: "\n").components(separatedBy: "Harness(\"").dropFirst()
        var tiers: [String: String] = [:]
        for row in rows {
            guard let name = row.split(separator: "\"").first else { continue }
            tiers[String(name)] = row.contains("support=\"full\"") ? "full" : "basic"
        }
        return tiers
    }
}
