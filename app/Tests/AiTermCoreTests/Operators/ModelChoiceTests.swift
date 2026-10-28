import Testing
import Foundation
@testable import AiTermCore

@Suite struct ModelChoiceTests {
    private static let opus = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: ["low", "high"], defaultEffort: "high")
    private static let sonnet = AgentModel(id: "sonnet", label: "Sonnet", detail: nil, efforts: ["medium"], defaultEffort: nil)
    private static let fallback: (model: String, reasoning: String?) = ("opus", "high")

    private func resolve(_ requested: String?, installed: Set<AgentKind> = [.claude]) throws(ModelChoice.Refusal) -> (model: String, reasoning: String?) {
        try ModelChoice.resolve(agent: .claude, requested: requested, installed: installed,
                                catalogue: [Self.opus, Self.sonnet], defaultModel: Self.fallback)
    }

    @Test func unknownModelIsRefused() {
        #expect(throws: ModelChoice.Refusal.unknownModel("gpt-9", .claude)) { try resolve("gpt-9") }
    }

    @Test func aModelNotInstalledIsRefused() {
        #expect(throws: ModelChoice.Refusal.notInstalled(.codex)) {
            try ModelChoice.resolve(agent: .codex, requested: "opus", installed: [.claude],
                                    catalogue: [Self.opus], defaultModel: ("gpt-5", nil))
        }
    }

    /// A known model comes with its own default effort, which may be none.
    @Test func aKnownModelCarriesItsDefaultReasoning() throws {
        let opus = try resolve("opus")
        #expect(opus.model == "opus" && opus.reasoning == "high")
        let sonnet = try resolve("sonnet")
        #expect(sonnet.model == "sonnet" && sonnet.reasoning == nil)
    }

    @Test func nilTakesTheDefault() throws {
        let chosen = try resolve(nil)
        #expect(chosen.model == "opus")
        #expect(chosen.reasoning == "high")
    }

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
