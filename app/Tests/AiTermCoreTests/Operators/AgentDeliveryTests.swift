import Testing
import Foundation
@testable import AiTermCore

/// Whether an agent's workers can be messaged, as run_status says it before anything is planned on it: the
/// delivery check's verdict, held against the version installed.
@Suite struct AgentDeliveryTests {
    @Test func theVersionTheCheckPassedCanBeMessagedAsItsVerdictSays() {
        let auto = AgentDelivery.of(.claude, verdict: DeliveryVerdict(policy: .auto, version: "2.1.301"), installed: "2.1.301")
        #expect(auto == AgentDelivery(messaging: .auto, installedVersion: "2.1.301", checkedVersion: "2.1.301", note: nil))
        let paste = AgentDelivery.of(.codex, verdict: DeliveryVerdict(policy: .pasteOnly, version: "0.160.0"), installed: "0.160.0")
        #expect(paste.messaging == .pasteOnly)
        #expect(paste.note == "Messages to its workers are pasted without Enter: the person presses Enter to send each one.")
    }

    /// A patch release since the check is covered, as the daemon covers it: the same major and minor.
    @Test func aPatchReleaseSinceTheCheckIsStillCovered() {
        let patched = AgentDelivery.of(.claude, verdict: DeliveryVerdict(policy: .auto, version: "2.1.301"), installed: "2.1.305")
        #expect(patched == AgentDelivery(messaging: .auto, installedVersion: "2.1.305", checkedVersion: "2.1.301", note: nil))
        let earlier = AgentDelivery.of(.claude, verdict: DeliveryVerdict(policy: .auto, version: "2.1.301"), installed: "2.1.299")
        #expect(earlier.messaging == .auto)
    }

    /// The broadcast's case: Codex moved to a new minor since the check, so nothing typed reaches its workers.
    @Test func anotherVersionInstalledOrNoneCheckedCannotBeMessaged() {
        let updated = AgentDelivery.of(.codex, verdict: DeliveryVerdict(policy: .auto, version: "0.150.0"), installed: "0.160.0")
        #expect(updated == AgentDelivery(messaging: .off, installedVersion: "0.160.0", checkedVersion: "0.150.0",
                                         note: "Codex 0.160.0 is installed, but AiTerm's delivery check covers 0.150.x only."))
        let major = AgentDelivery.of(.claude, verdict: DeliveryVerdict(policy: .auto, version: "2.1.301"), installed: "3.1.301")
        #expect(major.messaging == .off)
        let unchecked = AgentDelivery.of(.codex, verdict: nil, installed: "0.160.0")
        #expect(unchecked == AgentDelivery(messaging: .off, installedVersion: "0.160.0", checkedVersion: nil,
                                           note: "AiTerm's delivery check hasn't passed Codex 0.160.0."))
        let failed = AgentDelivery.of(.codex, verdict: DeliveryVerdict(policy: .off, version: "0.160.0"), installed: "0.160.0")
        #expect(failed.messaging == .off && failed.checkedVersion == "0.160.0")
        #expect(failed.note == "AiTerm's delivery check didn't pass Codex 0.160.0.")
    }

    @Test func anInstalledVersionNotReadLeavesTheVerdictAndSaysWhichVersionItHoldsFor() {
        let unread = AgentDelivery.of(.claude, verdict: DeliveryVerdict(policy: .auto, version: "2.1.301"), installed: nil)
        #expect(unread == AgentDelivery(messaging: .auto, installedVersion: nil, checkedVersion: "2.1.301",
                                        note: "AiTerm couldn't read which Claude Code version is installed: its workers can be messaged only while it is 2.1.x."))
    }

    @Test func itReadsAsJSONWithItsVersions() throws {
        let delivery = AgentDelivery(messaging: .pasteOnly, installedVersion: "0.160.0", checkedVersion: "0.160.0", note: nil)
        let json = String(decoding: try JSONEncoder().encode(delivery), as: UTF8.self)
        #expect(json.contains(#""messaging":"pasteOnly""#) && json.contains(#""installedVersion":"0.160.0""#)
                && json.contains(#""checkedVersion":"0.160.0""#))
    }
}

/// The version each agent CLI installed here reports, read from its `--version` in the login shell once,
/// and again only when its executable changes.
@Suite struct AgentVersionsTests {
    @Test func eachVersionLineReadsAsItsNumber() {
        let output = "banner from .zshrc\nclaude\t2.1.301 (Claude Code)\ncodex\tcodex-cli 0.160.0\npi\t\n"
        #expect(AgentVersions.versions(in: output) == [.claude: "2.1.301", .codex: "0.160.0"])
    }

    @Test func theShellIsAskedOnceUntilAnExecutableChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
