import AiTermTestSupport
import Testing
import Foundation
@testable import AiTermCore

/// The version each agent CLI installed here reports, read from its `--version` in the login shell once,
/// and again only when its executable changes.
@Suite struct AgentVersionsTests {
    @Test func eachVersionLineReadsAsItsNumber() {
        let output = "banner from .zshrc\nclaude\t2.1.301 (Claude Code)\ncodex\tcodex-cli 0.160.0\npi\t\n"
        #expect(AgentVersions.versions(in: output) == [.claude: "2.1.301", .codex: "0.160.0"])
    }

    @Test func theShellIsAskedOnceUntilAnExecutableChanges() throws {
        let folder = try ScratchFolder.make("aiterm-versions-")
        let codex = folder.appendingPathComponent("codex")
        try Data("v1".utf8).write(to: codex)
        let asked = Counter()
        let versions = AgentVersions(executables: { ["codex": codex.path] }, shell: { query in
            asked.add()
            #expect(query.contains(AgentCommand.shellQuote(codex.path) + " --version"))
            return "codex\tcodex-cli 0.\(asked.count).0\n"
        })
        #expect(versions.current([.codex]) == [.codex: "0.1.0"])
        #expect(versions.current([.codex]) == [.codex: "0.1.0"] && asked.count == 1)
        try Data("version two".utf8).write(to: codex)
        #expect(versions.current([.codex]) == [.codex: "0.2.0"], "an update rewrote it")
        #expect(AgentVersions(executables: { nil }, shell: { _ in "codex\t0.1.0" }).current([.codex]).isEmpty, "no login shell")
        let failing = Counter()
        let broken = AgentVersions(executables: { ["codex": codex.path] }, shell: { _ in failing.add(); return nil })
        #expect(broken.current([.codex]).isEmpty && broken.current([.codex]).isEmpty && failing.count == 1, "a failed shell isn't asked again")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }
}
