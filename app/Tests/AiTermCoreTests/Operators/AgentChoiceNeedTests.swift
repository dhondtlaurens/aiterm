import Foundation
import Testing
@testable import AiTermCore

@Suite struct AgentChoiceNeedTests {
    let opus = AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")
    let sonnet = AgentChoice(agent: .claude, model: "claude-sonnet-5-5", reasoning: nil)
    let codex = AgentChoice(agent: .codex, model: "gpt-5.5", reasoning: "high")
    let agy = AgentChoice(agent: .agy, model: "gemini-4-neon", reasoning: "medium")
    let first = UUID(), second = UUID()

    @Test func oneRowAndOneProjectNeedNoChoice() {
        #expect(AgentChoiceNeed.decide(permitted: [opus], projects: nil, conversationAgent: nil) == .ready(opus))
        #expect(AgentChoiceNeed.decide(permitted: [opus], projects: [first], conversationAgent: nil) == .ready(opus))
        #expect(AgentChoiceNeed.decide(permitted: [agy], projects: nil, conversationAgent: nil) == .ready(agy))
    }
    @Test func severalRowsOrProjectsAreLeftToChoose() {
        #expect(AgentChoiceNeed.decide(permitted: [opus, codex, agy], projects: nil, conversationAgent: nil) == .choose(rows: [opus, codex, agy], projects: nil))
        let projectOnly = AgentChoiceNeed.decide(permitted: [opus], projects: [first, second], conversationAgent: nil)
        #expect(projectOnly == .choose(rows: [opus], projects: [first, second]))
        #expect(projectOnly.isProjectOnly)
        let both = AgentChoiceNeed.decide(permitted: [opus, codex], projects: [first, second], conversationAgent: nil)
        #expect(both == .choose(rows: [opus, codex], projects: [first, second]) && !both.isProjectOnly)
    }
    @Test func aSavedConversationKeepsItsAgent() {
        #expect(AgentChoiceNeed.decide(permitted: [opus, codex], projects: nil, conversationAgent: .codex) == .ready(codex))
        #expect(AgentChoiceNeed.decide(permitted: [opus, codex, agy], projects: nil, conversationAgent: .agy) == .ready(agy))
        #expect(AgentChoiceNeed.decide(permitted: [opus, sonnet, codex], projects: nil, conversationAgent: .claude) == .choose(rows: [opus, sonnet], projects: nil))
        #expect(AgentChoiceNeed.decide(permitted: [codex], projects: nil, conversationAgent: .claude) == .ready(codex),
                "No row for the conversation's agent: the full choice, and a new conversation.")
        #expect(AgentChoiceNeed.decide(permitted: [opus, codex], projects: nil, conversationAgent: .pi) == .choose(rows: [opus, codex], projects: nil))
    }
    @Test func rowsTheOperatorCannotStartAreNotChoosable() {
        let pi = AgentChoice(agent: .pi, model: "local", reasoning: nil), blank = AgentChoice(agent: .claude, model: "", reasoning: nil)
        #expect(AgentChoiceNeed.decide(permitted: [pi, opus], projects: nil, conversationAgent: nil) == .ready(opus))
        #expect(AgentChoiceNeed.decide(permitted: [pi, blank], projects: nil, conversationAgent: nil) == .unavailable)
        #expect(AgentChoiceNeed.decide(permitted: [], projects: nil, conversationAgent: nil) == .unavailable)
    }
    @Test func theFallbackIsTheFirstChoosableRowInTheListOrder() {
        #expect(AgentChoiceNeed.choose(rows: [codex, opus], projects: nil).fallback == codex)
    }
    @Test func aDecidedChoiceRoundTrips() throws {
        let record = AgentChoiceRecord(row: codex, project: first, reason: "Claude is at 91% this week.", decided: .oracleAgreed,
                                       round: 2, note: nil, at: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(AgentChoiceRecord.self, from: data) == record)
    }
}
