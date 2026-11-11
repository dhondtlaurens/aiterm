import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct GitFixtureTests {
    @Test func copiedRepositoriesOwnTheirRefsAndObjects() async throws {
        async let first = GitFixture.makeRepoOffMain(prefix: "copy-a-")
        async let second = GitFixture.makeRepoOffMain(prefix: "copy-b-")
        let (a, b) = try await (first, second)
        let git = GitRunner.hermetic()
        let original = try git.run(["rev-parse", "HEAD"], in: b)
        try git.run(["commit", "--allow-empty", "-qm", "only a"], in: a)
        try git.run(["branch", "only-a"], in: a)
        #expect(try git.run(["rev-parse", "HEAD"], in: a) != original)
        #expect(try git.run(["rev-parse", "HEAD"], in: b) == original)
        #expect(try git.run(["branch", "--list", "only-a"], in: b).isEmpty)
        let hashPath = String(original.prefix(2)) + "/" + String(original.dropFirst(2))
        let object = URL(fileURLWithPath: a + "/.git/objects/" + hashPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: object.path)
        let handle = try FileHandle(forWritingTo: object)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("damaged only in a".utf8))
        try handle.close()
        #expect(try git.run(["fsck", "--no-dangling"], in: b).isEmpty, "copies do not share writable objects")
        try FileManager.default.removeItem(atPath: a)
        #expect(try git.run(["fsck", "--no-dangling"], in: b).isEmpty)
    }

    @Test func aFailedTemplateBuildCanBeRetriedAndOnlySuccessIsCached() throws {
        enum Transient: Error, Equatable { case timeout }
        let template = GitFixture.Template()
        var attempts = 0
        #expect(throws: Transient.timeout) {
            try template.path { attempts += 1; throw Transient.timeout }
        }
        #expect(try template.path { attempts += 1; return "seed" } == "seed")
        #expect(try template.path { attempts += 1; return "unexpected rebuild" } == "seed")
        #expect(attempts == 2)
    }

    @Test func anExplicitRunnerStillOwnsFixtureSetup() throws {
        let git = CountingGitRunner()
        let path = try GitFixture.makeRepo(prefix: "explicit-", git: git)
        #expect(git.calls == 2)
        #expect(try GitRunner.hermetic().run(["rev-list", "--count", "HEAD"], in: path) == "1")
    }
}
