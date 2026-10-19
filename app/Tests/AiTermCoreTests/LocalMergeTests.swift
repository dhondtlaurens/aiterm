import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// A local merge end (spec §5): the accepted commit merged into the project's own checkout's default branch,
/// against real repositories. It stops at the merge: nothing is pushed.
@Suite(.blocking) struct LocalMergeTests {
    let git = GitRunner.hermetic()

    /// The project's checkout back on `main`, with the task's branch one commit ahead of it, unpushed.
    func checkout() throws -> (repo: Repository, origin: String, sha: String, main: String) {
        let fixture = try GitFixture.withOrigin(branch: "feat/pluto-231")
        try git.run(["switch", "-q", "main"], in: fixture.path)
        return (Repository(fixture.path, git: git), fixture.origin, fixture.sha, try git.run(["rev-parse", "main"], in: fixture.path))
    }

    func originRefs(_ origin: String) throws -> String {
        try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: origin)
    }

    @Test func mergesWithoutPushing() async throws {
        let c = try checkout()
        let before = try originRefs(c.origin)
        let commit = try await LocalMerge.merge(sha: c.sha, into: "main", in: c.repo)
        #expect(try git.run(["rev-parse", "main"], in: c.repo.path) == commit)
        #expect(try git.run(["rev-parse", "\(commit)^1"], in: c.repo.path) == c.main, "a merge commit on the default branch")
        #expect(try git.run(["rev-parse", "\(commit)^2"], in: c.repo.path) == c.sha, "of the accepted commit")
        #expect(try originRefs(c.origin) == before, "the fake remote sees no push")
        #expect(try git.run(["rev-parse", "origin/main"], in: c.repo.path) == c.main)
    }

    /// A repeat after a lost answer merges nothing twice: the commit is in the default branch already.
    @Test func aRepeatMergesNothingTwice() async throws {
        let c = try checkout()
        let first = try await LocalMerge.merge(sha: c.sha, into: "main", in: c.repo)
        let again = try await LocalMerge.merge(sha: c.sha, into: "main", in: c.repo)
        #expect(again == first)
        #expect(try git.run(["rev-list", "--count", "main"], in: c.repo.path) == "3")
    }

    @Test func aDirtyCheckoutRefuses() async throws {
        let c = try checkout()
        let file = c.repo.path + "/notes.txt"
        try "draft".write(toFile: file, atomically: true, encoding: .utf8)
        try git.run(["add", "notes.txt"], in: c.repo.path)
        try git.run(["commit", "-q", "-m", "notes"], in: c.repo.path)
        let main = try git.run(["rev-parse", "main"], in: c.repo.path)
        try "changed".write(toFile: file, atomically: true, encoding: .utf8)
        await #expect(throws: LocalMerge.Refusal.uncommittedChanges(c.repo.path)) {
            try await LocalMerge.merge(sha: c.sha, into: "main", in: c.repo)
        }
        #expect(try git.run(["rev-parse", "main"], in: c.repo.path) == main, "nothing merged")
        #expect(LocalMerge.Refusal.uncommittedChanges("/tmp/shop").localizedDescription
                == "The project’s checkout at /tmp/shop has uncommitted changes, so AiTerm merged nothing: commit them or set them aside, then call finish_task again.")
    }

    /// An untracked file is no uncommitted change: git leaves it where it is.
    @Test func anUntrackedFileDoesNotRefuse() async throws {
        let c = try checkout()
        try "scratch".write(toFile: c.repo.path + "/scratch.txt", atomically: true, encoding: .utf8)
        _ = try await LocalMerge.merge(sha: c.sha, into: "main", in: c.repo)
    }

    @Test func aCheckoutOffTheDefaultBranchRefuses() async throws {
        let c = try checkout()
        try git.run(["switch", "-q", "-c", "spike"], in: c.repo.path)
        await #expect(throws: LocalMerge.Refusal.notOnDefaultBranch(c.repo.path, current: "spike", defaultBranch: "main")) {
            try await LocalMerge.merge(sha: c.sha, into: "main", in: c.repo)
        }
        try git.run(["switch", "-q", "--detach", "main"], in: c.repo.path)
        await #expect(throws: LocalMerge.Refusal.notOnDefaultBranch(c.repo.path, current: nil, defaultBranch: "main")) {
            try await LocalMerge.merge(sha: c.sha, into: "main", in: c.repo)
        }
        #expect(try git.run(["rev-parse", "main"], in: c.repo.path) == c.main)
        #expect(LocalMerge.Refusal.notOnDefaultBranch("/tmp/shop", current: "spike", defaultBranch: "main").localizedDescription
                == "The project’s checkout at /tmp/shop is on spike, not main, so AiTerm merged nothing: switch it to main, then call finish_task again.")
    }

    /// A conflict leaves the default branch as it was, with no merge half done.
    @Test func aConflictLeavesTheDefaultBranchAsItWas() async throws {
        let c = try checkout()
        let file = c.repo.path + "/price.txt"
        try git.run(["switch", "-q", "feat/pluto-231"], in: c.repo.path)
        try "10".write(toFile: file, atomically: true, encoding: .utf8)
        try git.run(["add", "price.txt"], in: c.repo.path)
        try git.run(["commit", "-q", "-m", "ten"], in: c.repo.path)
        let sha = try git.run(["rev-parse", "HEAD"], in: c.repo.path)
        try git.run(["switch", "-q", "main"], in: c.repo.path)
        try "12".write(toFile: file, atomically: true, encoding: .utf8)
        try git.run(["add", "price.txt"], in: c.repo.path)
        try git.run(["commit", "-q", "-m", "twelve"], in: c.repo.path)
        let main = try git.run(["rev-parse", "main"], in: c.repo.path)
        await #expect(throws: LocalMerge.Refusal.conflicted(sha: sha, defaultBranch: "main")) {
            try await LocalMerge.merge(sha: sha, into: "main", in: c.repo)
        }
        #expect(try git.run(["rev-parse", "main"], in: c.repo.path) == main)
        #expect(try git.run(["status", "--porcelain"], in: c.repo.path).isEmpty, "the merge was taken back")
    }

    @Test func onlyAFullCommitIdIsMerged() async throws {
        let c = try checkout()
        await #expect(throws: LocalMerge.Refusal.invalidCommit("feat/pluto-231")) {
            try await LocalMerge.merge(sha: "feat/pluto-231", into: "main", in: c.repo)
        }
    }
}
