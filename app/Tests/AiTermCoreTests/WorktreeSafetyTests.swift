import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// What a repository's worktree and branch work must not do to work that is not its own: a branch someone is rebasing, a
/// folder under `.worktrees/` that git no longer knows.
final class WorktreeSafetyTests {
    let git = GitRunner.hermetic()
    /// The folder every repository of the test lives in, removed with it.
    let root: String
    /// The project's checkout, a clone of `root/remote.git`.
    let repo: String
    /// Someone else's clone of the same origin.
    let other: String

    init() throws {
        let raw = NSTemporaryDirectory() + "worktree-safety-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        repo = root + "/repo"; other = root + "/other"
        let git = GitRunner.hermetic()
        try git.run(["init", "-q", "--bare", "-b", "main", root + "/remote.git"], in: root)
        try git.run(["clone", "-q", root + "/remote.git", repo], in: root)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try git.run(["push", "-q", "origin", "HEAD:main"], in: repo)
        try git.run(["clone", "-q", root + "/remote.git", other], in: root)
    }
    deinit { try? FileManager.default.removeItem(atPath: root) }

    private func commit(_ message: String, in dir: String) throws {
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", message], in: dir)
    }
    private func sha(_ ref: String, in dir: String) throws -> String { try git.run(["rev-parse", ref], in: dir) }

    /// A review of a branch that is being rebased in another checkout: git lists that checkout as
    /// detached, so nothing says the branch is in use until `worktree add` refuses it. By then the
    /// branch must not have been fast-forwarded under the rebase.
    @Test func aReviewLeavesABranchMidRebaseAlone() throws {
        try git.run(["checkout", "-q", "-b", "feat/x"], in: repo)
        try commit("mine", in: repo)
        try git.run(["push", "-q", "origin", "feat/x"], in: repo)
        try git.run(["checkout", "-q", "main"], in: repo)
        try git.run(["worktree", "add", "-q", root + "/rebasing", "feat/x"], in: repo)
        try git.run(["fetch", "-q", "origin"], in: other)
        try git.run(["checkout", "-q", "feat/x"], in: other)
        try commit("theirs", in: other)
        try git.run(["push", "-q", "origin", "feat/x"], in: other)
        #expect(throws: GitError.self) { try self.git.run(["rebase", "--exec", "false", "HEAD~1"], in: self.root + "/rebasing") }
        let before = try sha("feat/x", in: repo)

        #expect(throws: (any Error).self) { try Repository(self.repo, git: self.git).addReviewWorktree(slug: "review", branch: "feat/x") }
        #expect(try sha("feat/x", in: repo) == before)
        #expect(throws: Never.self) { try self.git.run(["rebase", "--continue"], in: self.root + "/rebasing") }
    }
}
