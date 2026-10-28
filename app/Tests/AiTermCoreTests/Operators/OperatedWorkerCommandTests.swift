import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// A worker the Operator launches, one profile for every broadcast: Claude without the menu tool, push
/// or merge, in auto permission mode; Codex with the same approval bypass as a regular task.
@Suite(.blocking) struct OperatedWorkerCommandTests {
    let wt = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").path

    @Test func aClaudeWorkerRunsInAutoModeWithoutTheMenuPushOrMerge() throws {
        #expect(try AgentCommand.build(agent: .claude, model: "opus", reasoning: "high", prompt: "fix it", worktreePath: wt,
                                       git: .hermetic(), operated: true)
                == "claude --model opus --effort high --disallowedTools AskUserQuestion 'Bash(git push:*)' "
                + "'Bash(gh pr merge:*)' 'Bash(glab mr merge:*)' 'Bash(gh pr create:*)' 'Bash(glab mr create:*)' 'Bash(gh pr ready:*)' 'Bash(glab mr update:*)' 'Bash(git -C * push:*)' 'Bash(git * push:*)' --permission-mode auto 'fix it'")
    }

    /// Every broadcast launches its workers the same way: the words take no setting but the agent, its model and its
    /// reasoning, and a launch, a reopen and a preview all carry them.
    @Test func oneProfileForEveryBroadcast() throws {
        let claude = AgentCommand.workerWords(agent: .claude, model: "opus", reasoning: "high")
        #expect(claude == ["claude", "--model", "opus", "--effort", "high", "--disallowedTools", "AskUserQuestion",
                           "Bash(git push:*)", "Bash(gh pr merge:*)", "Bash(glab mr merge:*)", "Bash(gh pr create:*)", "Bash(glab mr create:*)", "Bash(gh pr ready:*)", "Bash(glab mr update:*)", "Bash(git -C * push:*)", "Bash(git * push:*)", "--permission-mode", "auto"])
        let codex = AgentCommand.workerWords(agent: .codex, model: "gpt-6-astra", reasoning: "medium")
        #expect(codex == ["codex", "--dangerously-bypass-approvals-and-sandbox", "-m", "gpt-6-astra", "-c", "model_reasoning_effort=medium"])
        #expect(AgentCommand.operatedClaudeDenials == ["AskUserQuestion", "Bash(git push:*)", "Bash(gh pr merge:*)", "Bash(glab mr merge:*)", "Bash(gh pr create:*)", "Bash(glab mr create:*)", "Bash(gh pr ready:*)", "Bash(glab mr update:*)", "Bash(git -C * push:*)", "Bash(git * push:*)"])
        for agent in AgentCommand.operatedAgents {
            let words = AgentCommand.workerWords(agent: agent, model: "m", reasoning: nil)
            #expect(AgentCommand.resumeWorker(agent: agent, conversation: "c", model: "m", reasoning: nil)
                    .hasSuffix(words.dropFirst().map(AgentCommand.shellWord).joined(separator: " ")))
            #expect(try AgentCommand.build(agent: agent, model: "m", reasoning: nil, prompt: nil, worktreePath: wt,
                                           git: .hermetic(), operated: true)
                    == words.map(AgentCommand.shellWord).joined(separator: " "))
        }
    }

    @Test func claudesPermissionModeIsAutoAndLast() {
        let words = AgentCommand.workerWords(agent: .claude, model: "opus", reasoning: nil)
        #expect(Array(words.suffix(2)) == ["--permission-mode", "auto"], "a variadic option is never last before the prompt")
        #expect(words.contains("AskUserQuestion"))
    }

    @Test func aCodexWorkerUsesTheRegularTaskPermissions() {
        #expect(AgentCommand.previewCommand(agent: .codex, model: "gpt-6-astra", reasoning: "medium", prompt: "fix it", operated: true)
                == "codex --dangerously-bypass-approvals-and-sandbox -m gpt-6-astra -c model_reasoning_effort=medium 'fix it'")
    }

    /// A task you make yourself launches exactly as before.
    @Test func withoutAnOperatorTheLaunchIsUnchanged() throws {
        #expect(AgentCommand.previewCommand(agent: .codex, model: "gpt-5.6", reasoning: nil, prompt: nil)
                == "codex --dangerously-bypass-approvals-and-sandbox -m gpt-5.6")
        #expect(try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: nil, worktreePath: wt, git: .hermetic())
                == "claude --model opus")
    }

    @Test func reviewWorkersKeepTheirModelAndReadOnlyCapabilities() {
        let claude = AgentCommand.workerWords(agent: .claude, model: "opus", reasoning: "high", readOnly: true)
        #expect(claude == ["claude", "--model", "opus", "--effort", "high", "--disallowedTools"]
            + AgentCommand.operatedClaudeDenials + ["Edit", "Write", "NotebookEdit", "--permission-mode", "auto"])
        #expect(AgentCommand.workerWords(agent: .codex, model: "gpt-6-astra", reasoning: "medium", readOnly: true)
            == ["codex", "-m", "gpt-6-astra", "-c", "model_reasoning_effort=medium", "--sandbox", "read-only", "--ask-for-approval", "never"])
    }

    @Test func readOnlyDoesNotChangeAPersonsLaunch() throws {
        for agent in [AgentKind.claude, .codex] {
            #expect(try AgentCommand.build(agent: agent, model: "m", reasoning: nil, prompt: nil, worktreePath: wt,
                                           git: .hermetic(), readOnly: true)
                == AgentCommand.previewCommand(agent: agent, model: "m", reasoning: nil, prompt: nil))
        }
    }

    @Test func onlyClaudeAndCodexAreOfferedToAnOperator() {
        #expect(AgentCommand.operatedAgents == [.claude, .codex])
        #expect(AgentCommand.workerWords(agent: .pi, model: "anthropic/claude-sonnet", reasoning: nil) == ["pi", "--model", "anthropic/claude-sonnet"])
    }
}
