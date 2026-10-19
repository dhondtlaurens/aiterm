import Foundation
import Testing
@testable import AiTermCore

/// The agent review (spec §3.1, §5's base): another agent reads a task's branch headless, read-only, in its
/// worktree, with the skill the Review names handed to it as text.
@Suite struct AgentReviewTests {
    @Test(arguments: [AgentKind.claude, .codex])
    func theReviewIsReadOnly(_ agent: AgentKind) throws {
        let invocation = try #require(AgentReview.invocation(agent: agent, model: "m", reasoning: nil, prompt: "Review it.",
                                                             worktree: "/tmp/wt", answerFile: "/tmp/runs/review.txt"))
        let words = invocation.arguments
        switch agent {
        case .codex:
            #expect(invocation.executable == "codex")
            let sandbox = try #require(words.firstIndex(of: "--sandbox"))
            #expect(words[sandbox + 1] == "read-only")
            let folder = try #require(words.firstIndex(of: "-C"))
            #expect(words[folder + 1] == "/tmp/wt", "it reads the task's worktree")
            #expect(words.last == "Review it.")
        default:
            #expect(invocation.executable == "claude")
            let allowed = try #require(words.firstIndex(of: "--allowedTools"))
            #expect(Array(words[(allowed + 1)...].prefix(3)) == ["Read", "Grep", "Glob"])
            #expect(!words.contains { $0.contains("Bash") || $0.contains("Edit") || $0.contains("Write") })
            #expect(words.contains("dontAsk"))
        }
    }

    @Test func theOtherAgentReviewsByDefault() {
        #expect(AgentReview.defaultReviewer(for: .claude, installed: [.claude, .codex]) == .codex)
        #expect(AgentReview.defaultReviewer(for: .codex, installed: [.claude, .codex]) == .claude)
        #expect(AgentReview.defaultReviewer(for: .claude, installed: [.claude]) == .claude, "with the other missing, its own agent")
        #expect(AgentReview.defaultReviewer(for: .grok, installed: [.grok]) == nil, "only Claude or Codex reviews")
        #expect(AgentReview.defaultReviewer(for: .claude, installed: []) == nil)
    }

    @Test func theSkillsNamedAreReadOnceEach() {
        #expect(AgentReview.skillNames(in: "Do an adversarial review with /review-skill, then /superpowers:code-review. Again /review-skill.")
                == ["review-skill", "superpowers:code-review"])
        #expect(AgentReview.skillNames(in: "Look at src/app/x and and/or") == [], "a slash inside a word names no skill")
    }

    @Test func theNamedSkillIsPassedAsText() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let skill = home.appendingPathComponent(".agents/skills/review-skill")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: review-skill\n---\nAttack every assumption.\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let found = AgentReview.skills(in: "Do an adversarial review with /review-skill and /missing", agents: [.claude, .codex],
                                       projectPath: nil, home: home)
        #expect(found.map(\.name) == ["review-skill"])
        #expect(found.first?.text.contains("Attack every assumption.") == true)
        let prompt = AgentReview.prompt(title: "Add gift card", brief: "Do A.", base: "main", commits: "4f2a91c Add it", diff: "+x",
                                        truncated: false, instructions: "Do an adversarial review with /review-skill", skills: found)
        #expect(prompt.contains("Attack every assumption.") && prompt.contains("4f2a91c Add it") && prompt.contains("Change nothing"))
        #expect(!prompt.contains("\u{2014}"), "no em dash in what AiTerm writes")
    }

    @Test func theFindingsAreTheAnswer() {
        let json = #"{"result":"  Line 3 leaks the token.  "}"#
        #expect(AgentReview.findings(.claude, output: ProcessOutput(status: 0, stdout: json, stderr: "", timedOut: false), answerFile: nil)
                == "Line 3 leaks the token.")
        #expect(AgentReview.findings(.claude, output: ProcessOutput(status: 0, stdout: json, stderr: "", timedOut: true), answerFile: nil) == nil)
    }
}
