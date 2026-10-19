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

    @Test func staysWhenPinned() {
        let agent = ModelChoice.launchAgent(planned: .claude, pinned: true, weekly: [.claude: 95, .codex: 10], installed: [.claude, .codex])
        #expect(agent == .claude)
    }

    @Test func staysWhenTheOtherIsAlsoHigh() {
        let agent = ModelChoice.launchAgent(planned: .claude, pinned: false, weekly: [.claude: 84, .codex: 80], installed: [.claude, .codex])
        #expect(agent == .claude)
    }

    @Test func staysWhenTheOtherIsNotInstalled() {
        let agent = ModelChoice.launchAgent(planned: .claude, pinned: false, weekly: [.claude: 84], installed: [.claude])
        #expect(agent == .claude)
    }
}
