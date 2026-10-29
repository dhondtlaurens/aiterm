import Testing
import Foundation
@testable import AiTermCore

@Suite struct ModelChoiceTests {
    @Test func switchesToCodexAtEightyPercent() {
        let agent = ModelChoice.launchAgent(planned: .claude, pinned: false, weekly: [.claude: 80, .codex: 10], installed: [.claude, .codex])
        #expect(agent == .codex)
    }

    /// Past 80 % the task still stays on its agent when it is pinned there, when the other agent is also at 80 %,
    /// or when the other is not installed.
    @Test(arguments: [
        (true, [.claude: 95, .codex: 10], [.claude, .codex]),
        (false, [.claude: 84, .codex: 80], [.claude, .codex]),
        (false, [.claude: 84], [.claude]),
    ] as [(Bool, [AgentKind: Int], Set<AgentKind>)])
    func staysOnItsAgent(pinned: Bool, weekly: [AgentKind: Int], installed: Set<AgentKind>) {
        let agent = ModelChoice.launchAgent(planned: .claude, pinned: pinned, weekly: weekly, installed: installed)
        #expect(agent == .claude)
    }
}

extension ModelChoiceTests {
    @Test func rowsMatchAgentModelAndReasoningInListOrder() {
        let rows = [
            AgentChoice(agent: .claude, model: "opus", reasoning: "high"),
            AgentChoice(agent: .codex, model: "mini", reasoning: nil),
            AgentChoice(agent: .codex, model: "astra", reasoning: "high"),
            AgentChoice(agent: .codex, model: "astra", reasoning: "low")
        ]
        #expect(ModelChoice.row(agent: .codex, model: nil, reasoning: nil, in: rows) == rows[1])
        #expect(ModelChoice.row(agent: .codex, model: "astra", reasoning: nil, in: rows) == rows[2])
        #expect(ModelChoice.row(agent: .codex, model: "astra", reasoning: "low", in: rows) == rows[3])
        #expect(ModelChoice.row(agent: .claude, model: "astra", reasoning: nil, in: rows) == nil)
        #expect(ModelChoice.row(agent: .codex, model: "astra", reasoning: "medium", in: rows) == nil)
        #expect(ModelChoice.row(agent: .codex, model: "unknown", reasoning: nil, in: rows) == nil)
        #expect(ModelChoice.row(agent: .codex, model: nil, reasoning: nil, in: []) == nil)
    }

    @Test func rowLaunchSwitchTakesFirstOtherAgentRow() {
        let planned = AgentChoice(agent: .claude, model: "opus", reasoning: "high")
        let other = AgentChoice(agent: .codex, model: "mini", reasoning: "low")
        let rows = [planned, other, AgentChoice(agent: .codex, model: "astra", reasoning: "high")]
        #expect(ModelChoice.launchChoice(planned: planned, pinned: false, weekly: [.claude: 80],
                                         installed: [.claude, .codex], rows: rows) == other)
        #expect(ModelChoice.launchChoice(planned: planned, pinned: false, weekly: [.claude: 80],
                                         installed: [.claude, .codex], rows: [planned]) == planned)
        #expect(ModelChoice.launchChoice(planned: planned, pinned: true, weekly: [.claude: 80],
                                         installed: [.claude, .codex], rows: rows) == planned)
        #expect(ModelChoice.launchChoice(planned: planned, pinned: false, weekly: [.claude: 79],
                                         installed: [.claude, .codex], rows: rows) == planned)
        #expect(ModelChoice.launchChoice(planned: planned, pinned: false, weekly: [.claude: 80],
                                         installed: [.claude], rows: rows) == planned)
        #expect(ModelChoice.launchChoice(planned: planned, pinned: false, weekly: [.claude: 80, .codex: 80],
                                         installed: [.claude, .codex], rows: rows) == planned)
    }
}
