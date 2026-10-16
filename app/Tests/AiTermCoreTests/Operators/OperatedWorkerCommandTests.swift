import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// A worker an operator launches (spec §4.1 table, §4.3): Claude without the menu tool, push or
/// merge, in the autonomy's permission mode; Codex sandboxed to its workspace instead of bypassed.
@Suite(.blocking) struct OperatedWorkerCommandTests {
    let wt = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").path

    @Test func aClaudeWorkerAtRoutineRunsInAutoModeWithoutTheMenuPushOrMerge() throws {
        #expect(try AgentCommand.build(agent: .claude, model: "opus", reasoning: "high", prompt: "fix it", worktreePath: wt,
                                       git: .hermetic(), operated: .routine)
                == "claude --model opus --effort high --disallowedTools AskUserQuestion 'Bash(git push:*)' "
                + "'Bash(gh pr merge:*)' 'Bash(glab mr merge:*)' --permission-mode auto 'fix it'")
    }

    @Test(arguments: [(Autonomy.askFirst, "default"), (.routine, "auto"), (.trusted, "auto"), (.handsOff, "auto")])
    func claudesPermissionModeFollowsAutonomy(_ autonomy: Autonomy, _ mode: String) {
        let words = AgentCommand.workerWords(agent: .claude, model: "opus", reasoning: nil, autonomy: autonomy)
        #expect(Array(words.suffix(2)) == ["--permission-mode", mode], "a variadic option is never last before the prompt")
        #expect(words.contains("AskUserQuestion"))
    }

    @Test(arguments: [(Autonomy.askFirst, "on-request"), (.routine, "on-request"), (.trusted, "on-request"), (.handsOff, "never")])
    func aCodexWorkerIsSandboxedToItsWorkspace(_ autonomy: Autonomy, _ approval: String) {
        #expect(AgentCommand.previewCommand(agent: .codex, model: "gpt-6-astra", reasoning: "medium", prompt: "fix it", operated: autonomy)
                == "codex -s workspace-write -a \(approval) -m gpt-6-astra -c model_reasoning_effort=medium 'fix it'")
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
        #expect(AgentCommand.workerWords(agent: .grok, model: "grok-4", reasoning: nil, autonomy: .routine) == ["grok", "-m", "grok-4"])
    }
}
