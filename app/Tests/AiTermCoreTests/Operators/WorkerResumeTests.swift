import Foundation
import Testing
@testable import AiTermCore

/// A worker reopened in a closed window resumes its conversation with the flags it launched with.
@Suite struct WorkerResumeTests {
    @Test func aCodexWorkerResumesItsThreadUnderTheWorkerFlags() {
        let words = AgentCommand.workerWords(agent: .codex, model: "gpt-6-astra", reasoning: "medium")
        let resume = AgentCommand.resumeWorker(agent: .codex, conversation: "019a-thread", model: "gpt-6-astra", reasoning: "medium")
        #expect(resume == (["codex", "resume", "019a-thread"] + words.dropFirst()).map(AgentCommand.shellWord).joined(separator: " "))
        #expect(!resume.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    @Test func aClaudeWorkerResumesItsSessionUnderTheWorkerFlags() {
        let words = AgentCommand.workerWords(agent: .claude, model: "m", reasoning: nil)
        #expect(words.first == "claude")
        #expect(AgentCommand.resumeWorker(agent: .claude, conversation: "c-1", model: "m", reasoning: nil)
                == (["claude", "--resume", "c-1"] + words.dropFirst()).map(AgentCommand.shellWord).joined(separator: " "))
    }

    /// The blanket bypass is what a sheet's Codex task resumes with; no operated Codex worker gets it back.
    @Test func noCodexResumeCarriesTheBypass() {
        let resume = AgentCommand.resumeWorker(agent: .codex, conversation: "t-1", model: "gpt-6-astra", reasoning: "high")
        #expect(!resume.contains("dangerously"))
        #expect(resume.contains("-s workspace-write"))
        #expect(resume.contains("-a on-request"))
    }

    /// A resumed Claude worker keeps the denials and the permission mode it launched with.
    @Test func aResumedClaudeWorkerKeepsItsDenialsAndPermissionMode() {
        let resume = AgentCommand.resumeWorker(agent: .claude, conversation: "c-1", model: "m", reasoning: nil)
        #expect(resume.hasPrefix("claude --resume c-1 "))
        #expect(resume.contains("--disallowedTools"))
        for denial in AgentCommand.operatedClaudeDenials { #expect(resume.contains(AgentCommand.shellWord(denial))) }
        #expect(resume.hasSuffix("--permission-mode auto"))
    }
}
