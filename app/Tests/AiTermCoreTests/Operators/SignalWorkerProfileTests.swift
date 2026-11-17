import Foundation
import Testing
import AiTermCore

@Suite struct SignalWorkerProfileTests {
    @Test func publishingWorkersKeepQuestionAndMergeLimitsWhileOperatorRemainsReadOnly() {
        let words = AgentCommand.workerWords(agent: .claude, model: "test", reasoning: nil, publishing: true)
        #expect(words.contains("AskUserQuestion"))
        #expect(words.contains("Bash(gh pr merge:*)"))
        #expect(!words.contains("Bash(git merge:*)"))
        #expect(AgentCommand.workerWords(agent: .claude, model: "test", reasoning: nil, readOnly: true).contains("Bash(git merge:*)"))
        #expect(!words.contains("Bash(git push:*)"))
        #expect(!words.contains("Bash(gh pr create:*)"))
        #expect(OperatorLaunch.shellDenials.contains("Bash(git push:*)"))
        #expect(OperatorLaunch.shellDenials.contains("Bash(gh pr create:*)"))
        #expect(AgentCommand.workerWords(agent: .claude, model: "test", reasoning: nil).contains("Bash(git push:*)"))
        let resume = AgentCommand.resumeWorker(agent: .claude, conversation: "test-id", model: "test", reasoning: nil, publishing: true)
        #expect(resume.contains("--resume test-id"))
        #expect(!resume.contains("Bash(git push:*"))
    }
    @Test func anInspectedBlockedWorkerCanResumeWithoutAnObsoleteReplyIntent() throws {
        var record = SignalTask(signal: UUID(), item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        record.phase = .blocked
        record.pendingReplies = ["main": SignalWorkerReply(at: Date(), fingerprint: "old-reply")]
        let resumed = try SignalTransitions.apply(.resume, to: record, at: Date())
        #expect(resumed.pendingReplies == nil)
        #expect(resumed.ownership == record.ownership + 1)
    }
}
