import Testing
import Foundation
@testable import AiTermCore

/// Each agent's support tier (`Harness.support`), what is derived from it, and the daemon's copy of it.
@Suite struct SupportTierTests {
    /// Antigravity is full since its delivery check passed (1.5.18); PI's screen is not read.
    @Test func claudeCodexAndAntigravityAreFullAndPiIsBasic() {
        #expect(Harness.claude.support == .full)
        #expect(Harness.codex.support == .full)
        #expect(Harness.agy.support == .full)
        #expect(Harness.pi.support == .basic)
        #expect(AgentKind.fullSupport == [.claude, .codex, .agy])
    }

    /// Workers and the Operator's skills follow the tier, never a list of their own. The delivery check
    /// covers every agent that is full, or on its way: a pass is what makes one full.
    @Test func theFullTierListsAreDerivedFromIt() {
        #expect(AgentCommand.workerAgents == AgentKind.fullSupport)
        #expect(DeliveryCheck.agents == [.claude, .codex, .agy])
        #expect(Set(AgentKind.fullSupport).isSubset(of: DeliveryCheck.agents))
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
        // The daemon reads the screens of exactly the CLIs the app runs the delivery check for.
        let screens = Self.daemonRows(in: python).filter { $0.value.contains("input_box=") }.keys
        #expect(Set(screens) == Set(DeliveryCheck.agents.map(\.rawValue)))
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
        daemonRows(in: python).mapValues { $0.contains("support=\"full\"") ? "full" : "basic" }
    }

    /// Each `Harness("<agent>", …)` row of the `HARNESSES` table, its comments left out.
    static func daemonRows(in python: String) -> [String: String] {
        guard let start = python.range(of: "HARNESSES: tuple[Harness, ...] = (") else { return [:] }
        let table = python[start.upperBound...]
        let lines = table.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix(")") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let rows = lines.joined(separator: "\n").components(separatedBy: "Harness(\"").dropFirst()
        var result: [String: String] = [:]
        for row in rows {
            guard let name = row.split(separator: "\"").first else { continue }
            result[String(name)] = row
        }
        return result
    }
}
