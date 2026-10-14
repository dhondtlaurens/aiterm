import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

struct FixerLaunchTests {
    let clone = FixClone(path: "/tmp/aiterm-fix-1", branch: "feat/x", startTip: "a", originTip: "b", git: GitRunner.hermetic())
    let request = FixRequest(title: "Couldn’t create the review.", reason: "Rebasing hit a conflict.", detail: "CONFLICT config.ts",
                             projectPath: "/p", branch: "feat/x", recreateRebase: true, retry: .createReview)
    let proposal = FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["feat/x"], drops: [], verify: "pnpm typecheck")

    @Test func claudeLooksReadOnlyWithItsHooksOffAndASchema() {
        let inv = FixerLaunch.look(.claude, model: "sonnet", reasoning: "high", clone: clone, request: request, sessionID: "S")
        #expect(inv.executable == "claude")
        #expect(inv.arguments.starts(with: ["-p"]))
        #expect(inv.arguments.contains("--session-id") && inv.arguments.contains("S"))
        #expect(inv.arguments.containsSequence(["--permission-mode", "dontAsk"]))
        #expect(inv.arguments.contains("--strict-mcp-config"))
        #expect(inv.arguments.containsSequence(["--model", "sonnet", "--effort", "high"]))
        #expect(inv.arguments.containsSequence(["--output-format", "json"]))
        #expect(inv.arguments.contains("--json-schema"))
        #expect(!inv.arguments.contains("Edit") && !inv.arguments.contains("Bash(git:*)"), "looking cannot write")
        let settings = inv.arguments[inv.arguments.firstIndex(of: "--settings")! + 1]
        #expect(settings.contains(#""disableAllHooks":true"#))
    }

    @Test func claudeAppliesByResumingWithEditsAndNoPush() {
        let inv = FixerLaunch.apply(.claude, model: "sonnet", reasoning: nil, clone: clone, proposal: proposal, sessionID: "S")
        #expect(inv.arguments.containsSequence(["--resume", "S"]))
        #expect(inv.arguments.contains("Edit") && inv.arguments.contains("Bash(git:*)"))
        #expect(inv.arguments.contains("Bash(git push:*)"))
        #expect(inv.arguments.contains("Bash(pnpm typecheck)"))
    }

    @Test func codexLooksInAReadOnlySandboxInTheClone() {
        let inv = FixerLaunch.look(.codex, model: "gpt-5.5", reasoning: "high", clone: clone, request: request, sessionID: "ignored")
        #expect(inv.executable == "codex")
        #expect(inv.arguments.starts(with: ["exec"]))
        #expect(inv.arguments.containsSequence(["--sandbox", "read-only"]))
        #expect(inv.arguments.containsSequence(["-C", clone.path]))
        #expect(inv.arguments.contains("--json") && inv.arguments.contains("--output-schema"))
        #expect(!inv.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(inv.answerFile != nil)
    }

    @Test func codexAppliesWritableWithoutNetwork() {
        let inv = FixerLaunch.apply(.codex, model: "gpt-5.5", reasoning: nil, clone: clone, proposal: proposal, sessionID: "T")
        #expect(inv.arguments.starts(with: ["exec", "resume", "T"]))
        #expect(inv.arguments.containsSequence(["-c", #"sandbox_mode="workspace-write""#]))
        #expect(!inv.arguments.contains { $0.contains("network_access=true") })
    }

    @Test func codexRunsWithoutHooksAndMayWriteTheClonesGitDirectory() {
        let look = FixerLaunch.look(.codex, model: "m", reasoning: nil, clone: clone, request: request, sessionID: "x")
        let apply = FixerLaunch.apply(.codex, model: "m", reasoning: nil, clone: clone, proposal: proposal, sessionID: "T")
        #expect(look.arguments.containsSequence(["--disable", "hooks"]) && apply.arguments.containsSequence(["--disable", "hooks"]))
        #expect(apply.arguments.containsSequence(["-c", #"sandbox_workspace_write.writable_roots=["/tmp/aiterm-fix-1/.git"]"#]))
        #expect(!look.arguments.contains { $0.contains("writable_roots") }, "looking writes nothing")
    }

    /// Codex's API refuses a schema that is not strict (spikes): every property required, none extra.
    @Test(arguments: ["look", "apply"])
    func theSchemasAreStrict(_ name: String) throws {
        let schema = name == "look" ? FixerPrompt.lookSchema : FixerPrompt.applySchema
        let object = try #require(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        #expect(object["additionalProperties"] as? Bool == false)
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(Set(object["required"] as? [String] ?? []) == Set(properties.keys))
    }

    @Test func theLookPromptCarriesTheProblemAsData() {
        let prompt = FixerPrompt.look(request: request, clone: clone)
        #expect(prompt.contains("<problem>") && prompt.contains("CONFLICT config.ts") && prompt.contains("</problem>"))
        #expect(FixerPrompt.instructions.contains("Never push"))
    }

    // -- reading answers (review focus 3) --

    @Test func claudesStructuredAnswerIsRead() throws {
        let out = ProcessOutput(status: 0, stdout: #"{"type":"result","session_id":"S","structured_output":{"outcome":"none","reason":"r"}}"#,
                                stderr: "", timedOut: false)
        let inv = FixerLaunch.look(.claude, model: "m", reasoning: nil, clone: clone, request: request, sessionID: "S")
        let (answer, session) = try FixerLaunch.lookAnswer(.claude, output: out, invocation: inv)
        #expect(answer.outcome == "none" && session == "S")
    }

    @Test func anAnswerGivenAsAStringIsReadToo() throws {
        let out = ProcessOutput(status: 0, stdout: #"{"session_id":"S","structured_output":"{\"outcome\":\"applied\",\"summary\":\"done\"}"}"#,
                                stderr: "", timedOut: false)
        let inv = FixerLaunch.apply(.claude, model: "m", reasoning: nil, clone: clone, proposal: proposal, sessionID: "S")
        let answer = try FixerLaunch.applyAnswer(.claude, output: out, invocation: inv)
        #expect(answer.outcome == "applied" && answer.summary == "done")
    }

    @Test func codexsApplyAnswerComesFromItsFile() throws {
        let dir = try GitFixture.folder("codex-apply-")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true)
        let clone = FixClone(path: dir, branch: "feat/x", startTip: "a", originTip: "b", git: GitRunner.hermetic())
        let inv = FixerLaunch.apply(.codex, model: "m", reasoning: nil, clone: clone, proposal: proposal, sessionID: "T")
        try #"{"outcome":"failed","summary":"s"}"#.write(toFile: inv.answerFile!, atomically: true, encoding: .utf8)
        let answer = try FixerLaunch.applyAnswer(.codex, output: ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false), invocation: inv)
        #expect(answer.outcome == "failed" && answer.summary == "s")
        #expect(throws: FixRefusal.unreadableAnswer(.codex)) {
            try FixerLaunch.applyAnswer(.codex, output: ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false),
                                        invocation: FixerLaunch.apply(.codex, model: "m", reasoning: nil, clone: FixClone(path: "/nonexistent", branch: "b", startTip: "a", originTip: nil, git: GitRunner.hermetic()), proposal: proposal, sessionID: "T"))
        }
    }

    @Test(arguments: ["I think the fix is to rebase.", "", #"{"type":"result"}"#, "{ not json"])
    func proseOrEmptyIsUnreadable(_ stdout: String) {
        let inv = FixerLaunch.look(.claude, model: "m", reasoning: nil, clone: clone, request: request, sessionID: "S")
        #expect(throws: FixRefusal.unreadableAnswer(.claude)) {
            try FixerLaunch.lookAnswer(.claude, output: ProcessOutput(status: 0, stdout: stdout, stderr: "", timedOut: false), invocation: inv)
        }
    }

    @Test func aTimeoutAndANonZeroExitAreTheirOwnRefusals() {
        let inv = FixerLaunch.look(.claude, model: "m", reasoning: nil, clone: clone, request: request, sessionID: "S")
        #expect(throws: FixRefusal.timedOut(.claude)) {
            try FixerLaunch.lookAnswer(.claude, output: ProcessOutput(status: 15, stdout: "", stderr: "", timedOut: true), invocation: inv)
        }
        #expect(throws: FixRefusal.agentExited(.claude, status: 1, stderr: "Not signed in")) {
            try FixerLaunch.lookAnswer(.claude, output: ProcessOutput(status: 1, stdout: "", stderr: "Not signed in", timedOut: false), invocation: inv)
        }
    }

    @Test func codexsThreadComesFromItsFirstEvent() throws {
        let dir = try GitFixture.folder("codex-answer-")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true)
        let clone = FixClone(path: dir, branch: "feat/x", startTip: "a", originTip: "b", git: GitRunner.hermetic())
        let inv = FixerLaunch.look(.codex, model: "m", reasoning: nil, clone: clone, request: request, sessionID: "x")
        try #"{"outcome":"none","reason":"r"}"#.write(toFile: inv.answerFile!, atomically: true, encoding: .utf8)
        let events = #"{"type":"thread.started","thread_id":"T-1"}"# + "\n" + #"{"type":"turn.completed"}"#
        let (answer, session) = try FixerLaunch.lookAnswer(.codex, output: ProcessOutput(status: 0, stdout: events, stderr: "", timedOut: false), invocation: inv)
        #expect(answer.reason == "r" && session == "T-1")
    }
}

extension Array where Element: Equatable {
    func containsSequence(_ needle: [Element]) -> Bool {
        guard needle.count <= count else { return false }
        return (0...(count - needle.count)).contains { Array(self[$0..<($0 + needle.count)]) == needle }
    }
}
