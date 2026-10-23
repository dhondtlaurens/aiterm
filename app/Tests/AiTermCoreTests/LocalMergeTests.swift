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

    /// Hermetic git whose merge gets as far as the merge state, then is killed at the deadline.
    struct MergeTimesOut: GitRunning {
        let inner: any GitRunning = GitRunner.hermetic()
        func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
            guard args.first == "merge", args.contains("--no-ff"), let sha = args.last else {
                return try inner.run(args, in: dir, timeout: timeout, environment: environment)
            }
            _ = try? inner.run(["merge", "--no-ff", "--no-commit", sha], in: dir, timeout: timeout, environment: environment)
            throw GitError(args: args, code: 15, stderr: "git merge timed out after 300 s", timedOut: true)
        }
    }

    func mergeState(_ path: String) throws -> String? {
        try git.ask(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: path, none: [1])
    }

    @Test func aFailedMergeStateCheckReportsItsOwnFailure() async throws {
        let c = try checkout()
        let runner = TimingOutGitRunner(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], inner: MergeTimesOut())
        defer { _ = try? git.run(["merge", "--abort"], in: c.repo.path) }
        do {
            _ = try await LocalMerge.merge(sha: c.sha, into: "main", in: Repository(c.repo.path, git: runner))
            Issue.record("expected a failed MERGE_HEAD check")
        } catch {
            #expect((error as? GitError)?.args == ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"])
        }
    }

    /// A merge killed at its deadline leaves no merge half done in your checkout.
    @Test func aTimedOutMergeIsTakenBack() async throws {
        let c = try checkout()
        let repo = Repository(c.repo.path, git: MergeTimesOut())
        await #expect(throws: GitError.self) { try await LocalMerge.merge(sha: c.sha, into: "main", in: repo) }
        #expect(try mergeState(c.repo.path) == nil, "no MERGE_HEAD")
        #expect(try git.run(["status", "--porcelain"], in: c.repo.path).isEmpty, "nothing staged")
        #expect(try git.run(["rev-parse", "main"], in: c.repo.path) == c.main)
    }

    /// A hook that stops the merge is said as a hook, not a conflict, and the merge is taken back.
    @Test(arguments: ["pre-merge-commit", "commit-msg"])
    func aFailingHookIsNoConflictAndIsTakenBack(hook: String) async throws {
        let c = try checkout()
        let script = c.repo.path + "/.git/hooks/" + hook
        try "#!/bin/sh\necho 'lint failed: 3 problems' >&2\necho 'see the log' >&2\nexit 1\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        await #expect(throws: LocalMerge.Refusal.hookStopped(defaultBranch: "main", output: "lint failed: 3 problems")) {
            try await LocalMerge.merge(sha: c.sha, into: "main", in: c.repo)
        }
        #expect(try mergeState(c.repo.path) == nil, "no MERGE_HEAD, \(hook)")
        #expect(try git.run(["status", "--porcelain"], in: c.repo.path).isEmpty, "nothing staged, \(hook)")
        #expect(try git.run(["rev-parse", "main"], in: c.repo.path) == c.main)
        #expect(LocalMerge.Refusal.hookStopped(defaultBranch: "main", output: "lint failed: 3 problems").localizedDescription
                == "A Git hook stopped the merge into main: lint failed: 3 problems.")
    }

    /// Branch names are compared exactly: a checked-out `Main` is not the default branch `main`.
    @Test func aBranchNamedLikeTheDefaultInAnotherCaseIsNotIt() async throws {
        let c = try checkout()
        try git.run(["branch", "-M", "main", "Main"], in: c.repo.path)
        let before = try git.run(["rev-parse", "HEAD"], in: c.repo.path)
        await #expect(throws: LocalMerge.Refusal.notOnDefaultBranch(c.repo.path, current: "Main", defaultBranch: "main")) {
            try await LocalMerge.merge(sha: c.sha, into: "main", in: c.repo)
        }
        #expect(try git.run(["rev-parse", "HEAD"], in: c.repo.path) == before, "nothing merged")
    }
}
