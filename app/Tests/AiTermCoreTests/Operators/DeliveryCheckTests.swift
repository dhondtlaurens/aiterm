import Testing
import Foundation
@testable import AiTermCore

/// The delivery check's file as Settings › Agents and New Broadcast read it: which version a pass covers,
/// each agent's Messaging sentence, iTerm2's own checks, and the command Run check types.
@Suite struct DeliveryCheckTests {
    /// One entry as `delivery_check.agent_entry` writes it.
    private static func agent(_ version: Any?, paste: Bool = true, submit: Bool = true, failed: [String] = []) -> [String: Any] {
        var scenarios: [String: Any] = [:]
        for name in DeliveryCheck.pasteSafeScenarios + DeliveryCheck.submitSafeScenarios {
            scenarios[name] = ["passed": !failed.contains(name), "detail": "…"]
        }
        return ["version": version ?? NSNull(), "pasteSafe": paste, "submitSafe": submit,
                "checkedAt": "2026-10-21T07:00:00Z", "scenarios": scenarios]
    }

    private static var iterm: [String: Any] { [
        "version": "3.7.2", "keystrokesPassThrough": true, "backgroundWindow": true, "checkedAt": "2026-10-21T07:00:00Z",
        "scenarios": ["keystrokesPassThrough": ["passed": true, "detail": ""], "backgroundWindow": ["passed": true, "detail": ""]],
    ] }

    private static func file(_ entries: [String: Any]) -> DeliveryCheckFile {
        DeliveryCheckFile(data: try? JSONSerialization.data(withJSONObject: entries))
    }

    // -- which version a pass covers ----------------------------------------------------------------

    @Test func aPassCoversEveryPatchOfItsMajorAndMinor() {
        #expect(DeliveryCheck.covers(checked: "2.1.301", installed: "2.1.301"))
        #expect(DeliveryCheck.covers(checked: "2.1.301", installed: "2.1.9"))
        #expect(DeliveryCheck.covers(checked: "2.1.301", installed: "2.1.400"))
        #expect(DeliveryCheck.covers(checked: "0.160.0", installed: "0.160.12"))
    }

    @Test func anotherMinorOrMajorIsNotCovered() {
        #expect(!DeliveryCheck.covers(checked: "2.1.301", installed: "2.2.0"))
        #expect(!DeliveryCheck.covers(checked: "2.1.301", installed: "2.0.301"))
        #expect(!DeliveryCheck.covers(checked: "2.1.301", installed: "3.1.301"))
        #expect(!DeliveryCheck.covers(checked: "0.160.0", installed: "0.16.0"), "compared as numbers, not text")
    }

    @Test func aMissingOrUnreadableVersionIsNotCovered() {
        #expect(!DeliveryCheck.covers(checked: "2.1.301", installed: nil))
        #expect(!DeliveryCheck.covers(checked: nil, installed: "2.1.301"))
        #expect(!DeliveryCheck.covers(checked: "2.1", installed: "2.1.301"))
        #expect(!DeliveryCheck.covers(checked: "2.1.301", installed: "2.1"))
        #expect(!DeliveryCheck.covers(checked: "2.1.301", installed: "two"))
        #expect(!DeliveryCheck.covers(checked: "", installed: ""))
    }

    @Test func aVersionLineIsItsMajorAndMinor() {
        #expect(DeliveryCheck.versionLine("2.1.301") == "2.1")
        #expect(DeliveryCheck.versionLine("0.160.0") == "0.160")
        #expect(DeliveryCheck.versionLine("2.1") == nil)
        #expect(DeliveryCheck.versionLine(nil) == nil)
    }

    // -- Messaging, per agent -----------------------------------------------------------------------

    @Test func onlyClaudeAndCodexAreChecked() {
        let file = Self.file(["claude": Self.agent("2.1.301"), "codex": Self.agent("0.160.0")])
        #expect(DeliveryCheck.agents == [.claude, .codex])
        #expect(DeliveryCheck.messaging(.pi, file: file, installed: "1.0.0") == nil)
    }

    @Test func aPassForTheInstalledLineIsReady() {
        let file = Self.file(["claude": Self.agent("2.1.301"), "codex": Self.agent("0.160.0")])
        #expect(DeliveryCheck.messaging(.claude, file: file, installed: "2.1.305") == .ready("Messaging ready for 2.1"))
        #expect(DeliveryCheck.messaging(.codex, file: file, installed: "0.160.0") == .ready("Messaging ready for 0.160"))
    }

    @Test func noPassIsNotChecked() {
        #expect(DeliveryCheck.messaging(.claude, file: .missing, installed: "2.1.301") == .needsAttention("Messaging not checked for 2.1"))
        let other = Self.file(["codex": Self.agent("0.160.0")])
        #expect(DeliveryCheck.messaging(.claude, file: other, installed: "2.1.301") == .needsAttention("Messaging not checked for 2.1"))
        let noVersion = Self.file(["claude": Self.agent(nil)])
        #expect(DeliveryCheck.messaging(.claude, file: noVersion, installed: "2.1.301") == .needsAttention("Messaging not checked for 2.1"))
    }

    @Test func aPassForAnotherLineIsNotChecked() {
        let file = Self.file(["claude": Self.agent("2.1.301")])
        #expect(DeliveryCheck.messaging(.claude, file: file, installed: "2.2.0") == .needsAttention("Messaging not checked for 2.2"))
    }

    @Test func anUnknownInstalledVersionIsNotChecked() {
        let file = Self.file(["claude": Self.agent("2.1.301")])
        #expect(DeliveryCheck.messaging(.claude, file: file, installed: nil) == .needsAttention("Messaging not checked: version unknown"))
    }

    /// A failed pass names what failed, from its scenarios, in the order the check requires them.
    @Test func aFailedPassNamesItsScenarios() {
        let one = Self.file(["claude": Self.agent("2.1.301", paste: false, failed: ["approvalRace"])])
        #expect(DeliveryCheck.messaging(.claude, file: one, installed: "2.1.301") == .needsAttention("Messaging failed: approvalRace"))
        let three = Self.file(["codex": Self.agent("0.160.0", paste: false, submit: false, failed: ["takeover", "menuPaste", "approvalRace"])])
        #expect(DeliveryCheck.messaging(.codex, file: three, installed: "0.160.0") == .needsAttention("Messaging failed: menuPaste and 2 more"))
    }

    /// A run stops at its first failure: the card names that one, not the scenarios it never reached,
    /// and keeps its reason for the card's details.
    @Test func aRunThatStoppedNamesWhereAndWhy() {
        var entry = Self.agent("0.163.0", paste: false, submit: false, failed: ["menuPaste", "approvalRace", "permissionPaste"])
        entry["failedAt"] = "menuPaste"
        entry["failure"] = "Expected menu prompt. The /model menu did not open."
        let file = Self.file(["codex": entry])
        #expect(DeliveryCheck.messaging(.codex, file: file, installed: "0.163.2") == .needsAttention("Messaging failed: menuPaste"))
        #expect(DeliveryCheck.failure(.codex, file: file, installed: "0.163.2") == "Expected menu prompt. The /model menu did not open.")
        #expect(DeliveryCheck.failure(.codex, file: file, installed: "0.164.0") == nil, "a verdict for another version says nothing")
        #expect(DeliveryCheck.failure(.claude, file: Self.file(["claude": Self.agent("2.1.301")]), installed: "2.1.301") == nil)
    }

    /// A scenario the check did not reach counts as failed, as `delivery_check._passed` counts it.
    @Test func aScenarioNotRunCountsAsFailed() {
        var entry = Self.agent("2.1.301", submit: false)
        var scenarios = entry["scenarios"] as! [String: Any]
        scenarios["takeover"] = nil
        entry["scenarios"] = scenarios
        let file = Self.file(["claude": entry])
        #expect(DeliveryCheck.messaging(.claude, file: file, installed: "2.1.301") == .needsAttention("Messaging failed: takeover"))
    }

    /// Paste-safe alone is AiTerm pasting without Enter: not ready for a worker the Operator must steer.
    @Test func pasteSafeAloneIsNotReady() {
        let file = Self.file(["claude": Self.agent("2.1.301", submit: false)])
        #expect(DeliveryCheck.messaging(.claude, file: file, installed: "2.1.301") == .needsAttention("Messaging failed for 2.1"))
    }

    /// Only a JSON true counts, as `load_policy` reads it.
    @Test func onlyAJSONTrueIsSafe() {
        var entry = Self.agent("2.1.301")
        entry["submitSafe"] = "true"
        let file = Self.file(["claude": entry])
        #expect(DeliveryCheck.messaging(.claude, file: file, installed: "2.1.301")?.isReady == false)
        #expect(DeliveryCheckFile(data: Data("not json".utf8)) == .missing)
        #expect(DeliveryCheckFile(data: Data("[1]".utf8)) == .missing)
        #expect(DeliveryCheckFile(data: nil) == .missing)
    }

    // -- iTerm2's own checks ------------------------------------------------------------------------

    @Test func itermsOwnChecks() {
        #expect(DeliveryCheck.iterm(Self.file(["iterm": Self.iterm])) == .ready("iTerm2 checks passed"))
        #expect(DeliveryCheck.iterm(.missing) == .needsAttention("iTerm2 checks not run"))
        var failed = Self.iterm
        failed["backgroundWindow"] = false
        failed["scenarios"] = ["keystrokesPassThrough": ["passed": true], "backgroundWindow": ["passed": false]]
        #expect(DeliveryCheck.iterm(Self.file(["iterm": failed])) == .needsAttention("iTerm2 checks failed: backgroundWindow"))
    }

    // -- Run check ----------------------------------------------------------------------------------

    /// The check for one agent, written into the policy file, from the bundle's daemon folder with the
    /// helper's Python, as the helper itself is started; iTerm2's own checks too until they have passed.
    @Test func theCommandChecksOneAgentAndItermUntilItPassed() {
        let python = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        let daemon = URL(fileURLWithPath: "/Applications/AiTerm.app/Contents/Resources/daemon")
        let env = "env PYTHONPATH='/Applications/AiTerm.app/Contents/Resources/daemon' PYTHONDONTWRITEBYTECODE=1 '/opt/homebrew/bin/python3'"
        #expect(DeliveryCheck.command(agent: .claude, file: .missing, python: python, daemonDir: daemon)
                == "\(env) -m tools.delivery_check --agents claude --write && exit")
        let passed = Self.file(["iterm": Self.iterm])
        #expect(DeliveryCheck.command(agent: .claude, file: passed, python: python, daemonDir: daemon)
                == "\(env) -m tools.delivery_check --agents claude --write --skip-iterm && exit")
        #expect(DeliveryCheck.command(agent: .codex, file: passed, python: python, daemonDir: daemon)
                == "\(env) -m tools.delivery_check --agents codex --write --skip-iterm && exit")
    }

    @Test func theFileLivesBesideTheHelpersOthers() {
        let home = URL(fileURLWithPath: "/Users/you")
        #expect(AiTermPaths.deliveryPolicyURL(home: home).path == "/Users/you/Library/Application Support/AiTerm/delivery-policy.json")
    }

    /// A watch answers only when the file changed since it last looked, its first look included.
    @Test func aWatchAnswersWhenTheFileChanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-delivery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("delivery-policy.json")
        let watch = DeliveryCheckWatch(url: url)
        #expect(watch.changed() == .missing, "the first look answers, with no file")
        #expect(watch.changed() == nil)
        try JSONSerialization.data(withJSONObject: ["claude": Self.agent("2.1.301")]).write(to: url)
        let read = try #require(watch.changed())
        #expect(DeliveryCheck.messaging(.claude, file: read, installed: "2.1.301")?.isReady == true)
        #expect(watch.changed() == nil)
        try FileManager.default.removeItem(at: url)
        #expect(watch.changed() == .missing)
    }
}
