import Foundation
import Testing
@testable import AiTermCore

/// The line each Settings › Agents card shows from `compat/verified.json`, the versions this AiTerm
/// was last checked with (`scripts/compat-check.sh`): covered by major and minor, as Messaging is.
@Suite struct CompatVerifiedTests {
    let list = CompatVerified.decode(Data(#"""
    {"claude": {"verified": "2.1", "version": "2.1.323", "checkedAt": "2026-11-13"},
     "codex": {"verified": "0.167", "version": "0.167.0", "checkedAt": "2026-11-13"}}
    """#.utf8))

    @Test func aVersionInAVerifiedLineSaysSo() {
        #expect(list.sentence(for: .claude, installed: "2.1.330") == "2.1 verified with this AiTerm")
        #expect(list.sentence(for: .codex, installed: "0.167.2") == "0.167 verified with this AiTerm")
    }

    @Test func aNewerOrOtherLineIsNotYetVerified() {
        #expect(list.sentence(for: .claude, installed: "2.2.0") == "2.2 not yet verified with this AiTerm")
        #expect(list.sentence(for: .codex, installed: "0.166.9") == "0.166 not yet verified with this AiTerm")
    }

    @Test func anAgentTheListLeavesOutIsNotYetVerified() {
        #expect(list.sentence(for: .pi, installed: "1.4.0") == "1.4 not yet verified with this AiTerm")
    }

    @Test func anUnknownVersionSaysNothing() {
        #expect(list.sentence(for: .claude, installed: nil) == nil)
        #expect(list.sentence(for: .claude, installed: "beta") == nil)
    }

    @Test func anUnreadableListVerifiesNothing() {
        let broken = CompatVerified.decode(Data("[1, 2]".utf8))
        #expect(broken == CompatVerified(lines: [:]))
        #expect(broken.sentence(for: .claude, installed: "2.1.323") == "2.1 not yet verified with this AiTerm")
        let partial = CompatVerified.decode(Data(#"{"claude": {"version": "2.1.323"}, "grok": {"verified": "1.0"}}"#.utf8))
        #expect(partial == CompatVerified(lines: [:]))
    }

    @Test func theListIsReadFromTheBundlesCompatFolder() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("compat-verified-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: resources) }
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("compat"), withIntermediateDirectories: true)
        try Data(#"{"pi": {"verified": "1.4"}}"#.utf8).write(to: resources.appendingPathComponent("compat/verified.json"))
        #expect(CompatVerified.bundled(resourceURL: resources) == CompatVerified(lines: [.pi: "1.4"]))
        #expect(CompatVerified.bundled(resourceURL: resources.appendingPathComponent("missing")) == CompatVerified(lines: [:]))
    }
}
