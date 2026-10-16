import Foundation
import Testing
@testable import AiTermCore

/// A worker reopened in a closed window resumes its conversation with the flags it launched with.
@Suite struct WorkerResumeTests {
    @Test func aCodexWorkerResumesItsThreadUnderItsOperationsFlags() {
        let words = AgentCommand.workerWords(agent: .codex, model: "gpt-6-astra", reasoning: "medium", autonomy: .routine)
        let resume = AgentCommand.resumeWorker(agent: .codex, conversation: "019a-thread", model: "gpt-6-astra", reasoning: "medium", autonomy: .routine)
        #expect(resume == (["codex", "resume", "019a-thread"] + words.dropFirst()).map(AgentCommand.shellWord).joined(separator: " "))
        #expect(!resume.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    @Test func aClaudeWorkerResumesItsSessionUnderItsOperationsFlags() {
        let words = AgentCommand.workerWords(agent: .claude, model: "m", reasoning: nil, autonomy: .askFirst)
        #expect(words.first == "claude")
        #expect(AgentCommand.resumeWorker(agent: .claude, conversation: "c-1", model: "m", reasoning: nil, autonomy: .askFirst)
                == (["claude", "--resume", "c-1"] + words.dropFirst()).map(AgentCommand.shellWord).joined(separator: " "))
    }

    /// The blanket bypass is what a sheet's Codex task resumes with; no operated Codex worker gets it back.
    @Test(arguments: Autonomy.allCases) func noCodexResumeCarriesTheBypassAtAnyAutonomy(autonomy: Autonomy) {
        let resume = AgentCommand.resumeWorker(agent: .codex, conversation: "t-1", model: "gpt-6-astra", reasoning: "high", autonomy: autonomy)
        #expect(!resume.contains("dangerously"))
        #expect(resume.contains("-s workspace-write"))
        #expect(resume.contains(autonomy == .handsOff ? "-a never" : "-a on-request"))
    }

    /// A resumed Claude worker keeps the denials and the permission mode it launched with.
    @Test func aResumedClaudeWorkerKeepsItsDenialsAndPermissionMode() {
        for autonomy in Autonomy.allCases {
            let resume = AgentCommand.resumeWorker(agent: .claude, conversation: "c-1", model: "m", reasoning: nil, autonomy: autonomy)
            #expect(resume.hasPrefix("claude --resume c-1 "))
            #expect(resume.contains("--disallowedTools"))
            for denial in AgentCommand.operatedClaudeDenials { #expect(resume.contains(AgentCommand.shellWord(denial))) }
            #expect(resume.hasSuffix("--permission-mode " + (autonomy == .askFirst ? "default" : "auto")))
        }
    }
}
