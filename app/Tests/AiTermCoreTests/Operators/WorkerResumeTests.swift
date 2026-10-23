import Foundation
import Testing
@testable import AiTermCore

/// A worker reopened in a closed window resumes its conversation with the flags it launched with
/// (`OperatedWorkerCommandTests.oneProfileForEveryBroadcast` holds every agent's resume to its launch words).
@Suite struct WorkerResumeTests {
    /// Reopening an operated task keeps the same permissions as a fresh launch.
    @Test func aCodexResumeKeepsTheBypass() {
        let resume = AgentCommand.resumeWorker(agent: .codex, conversation: "t-1", model: "gpt-6-astra", reasoning: "high")
        #expect(resume == "codex resume t-1 --dangerously-bypass-approvals-and-sandbox -m gpt-6-astra -c model_reasoning_effort=high")
    }
}
