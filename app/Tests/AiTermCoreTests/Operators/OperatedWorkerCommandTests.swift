import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// A worker the Operator launches, one profile for every broadcast: Claude without the menu tool, push
/// or merge, in auto permission mode; Codex sandboxed to its workspace instead of bypassed.
@Suite(.blocking) struct OperatedWorkerCommandTests {
    let wt = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").path

    @Test func aClaudeWorkerRunsInAutoModeWithoutTheMenuPushOrMerge() throws {
        #expect(try AgentCommand.build(agent: .claude, model: "opus", reasoning: "high", prompt: "fix it", worktreePath: wt,
                                       git: .hermetic(), operated: true)
                == "claude --model opus --effort high --disallowedTools AskUserQuestion 'Bash(git push:*)' "
                + "'Bash(gh pr merge:*)' 'Bash(glab mr merge:*)' --permission-mode auto 'fix it'")
    }

    @Test func claudesPermissionModeIsAutoAndLast() {
        let words = AgentCommand.workerWords(agent: .claude, model: "opus", reasoning: nil)
        #expect(Array(words.suffix(2)) == ["--permission-mode", "auto"], "a variadic option is never last before the prompt")
        #expect(words.contains("AskUserQuestion"))
    }

    @Test func aCodexWorkerIsSandboxedToItsWorkspace() {
        #expect(AgentCommand.previewCommand(agent: .codex, model: "gpt-6-astra", reasoning: "medium", prompt: "fix it", operated: true)
                == "codex -s workspace-write -a on-request -m gpt-6-astra -c model_reasoning_effort=medium 'fix it'")
    }

    /// A task you make yourself launches exactly as before.
    @Test func withoutAnOperatorTheLaunchIsUnchanged() throws {
        #expect(AgentCommand.previewCommand(agent: .codex, model: "gpt-5.6", reasoning: nil, prompt: nil)
                == "codex --dangerously-bypass-approvals-and-sandbox -m gpt-5.6")
        #expect(try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: nil, worktreePath: wt, git: .hermetic())
                == "claude --model opus")
    }

    @Test func onlyClaudeAndCodexAreOfferedToAnOperator() {
        #expect(AgentCommand.operatedAgents == [.claude, .codex])
        #expect(AgentCommand.workerWords(agent: .grok, model: "grok-4", reasoning: nil) == ["grok", "-m", "grok-4"])
    }
}
