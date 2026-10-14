import Testing
import Foundation
import Synchronization
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) final class FixLandingTests {
    let git = GitRunner.hermetic()
    var world: ConflictWorld

    init() throws { world = try ConflictWorld(git: .hermetic()) }
    deinit { world.removeAll() }

    private func request(branch: String) -> FixRequest {
        FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: branch,
                   recreateRebase: true, retry: .createReview)
    }

    /// A clone whose feat/x was resolved to “both” on top of origin's.
    private func resolvedClone(branch: String = "feat/x") throws -> FixClone {
        let clone = try FixClone.make(for: request(branch: branch), git: git, root: world.root)
        try "topic=both\n".write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
        try git.run(["add", "config.ts"], in: clone.path)
        try git.run(["-c", "core.editor=true", "rebase", "--continue"], in: clone.path)
        return clone
    }

    @Test func landsABranchCheckedOutNowhereAndKeepsABackup() throws {
        let old = try world.sha("feat/x", in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        let landing = try Repository(world.repo, git: git).landFix(from: clone)
        #expect(try world.sha("feat/x", in: world.repo) == clone.tip("feat/x"))
        #expect(try world.sha("aiterm/backup/feat/x", in: world.repo) == old, "the short name resolves")
        #expect(landing == FixLanding(branch: "feat/x", old: old, new: try clone.tip("feat/x")))
        #expect(landing.backup == "aiterm/backup/feat/x")
        #expect(try git.run(["branch", "--list", "aiterm/*"], in: world.repo).isEmpty, "not a branch any picker lists")
    }

    /// Review focus 5: a commit in a terminal while the agent worked.
    @Test func aBranchThatMovedMeanwhileIsRefusedAndNothingLands() throws {
        let clone = try resolvedClone(); defer { clone.remove() }
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        try world.commit("meanwhile", file: "other.txt", contents: "x\n", in: world.repo)
        try git.run(["checkout", "-q", "main"], in: world.repo)
        let moved = try world.sha("feat/x", in: world.repo)
        #expect(throws: FixRefusal.branchMovedMeanwhile("feat/x")) { try Repository(world.repo, git: git).landFix(from: clone) }
        #expect(try world.sha("feat/x", in: world.repo) == moved)
        #expect(try git.run(["for-each-ref", "refs/aiterm"], in: world.repo).isEmpty, "no backup, no leftover ref")
    }

    /// The branch moves between the check and the move: the compare-and-swap refuses it, and the
    /// backup an earlier fix left is exactly as it was.
    @Test func aBranchThatMovesAtTheLastMomentIsRefusedAndTheEarlierBackupIsKept() throws {
        let earlier = try world.sha("main", in: world.repo)
        try git.run(["update-ref", "refs/aiterm/backup/feat/x", earlier], in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        let racing = MovingGitRunner(inner: git, branch: "refs/heads/feat/x", repo: world.repo)
        #expect(throws: FixRefusal.branchMovedMeanwhile("feat/x")) { try Repository(world.repo, git: racing).landFix(from: clone) }
        #expect(racing.moved)
        #expect(try world.sha("refs/aiterm/backup/feat/x", in: world.repo) == earlier)
        #expect(try world.sha("feat/x", in: world.repo) != clone.tip("feat/x"))
        #expect(try git.run(["for-each-ref", "refs/aiterm/fix"], in: world.repo).isEmpty)
    }

    @Test func aBackupReplacesTheEarlierOne() throws {
        try git.run(["update-ref", "refs/aiterm/backup/feat/x", try world.sha("main", in: world.repo)], in: world.repo)
        let old = try world.sha("feat/x", in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        _ = try Repository(world.repo, git: git).landFix(from: clone)
        #expect(try world.sha("refs/aiterm/backup/feat/x", in: world.repo) == old)
    }

    @Test func landsWhereTheBranchIsCheckedOutAndKeepsUntrackedFiles() throws {
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        try "keep me\n".write(toFile: world.repo + "/untracked.txt", atomically: true, encoding: .utf8)
        let clone = try resolvedClone(); defer { clone.remove() }
        _ = try Repository(world.repo, git: git).landFix(from: clone)
        #expect(try world.sha("HEAD", in: world.repo) == clone.tip("feat/x"))
        #expect(try String(contentsOfFile: world.repo + "/config.ts", encoding: .utf8) == "topic=both\n")
        #expect(FileManager.default.fileExists(atPath: world.repo + "/untracked.txt"))
        #expect(try git.run(["symbolic-ref", "--short", "HEAD"], in: world.repo) == "feat/x", "still on the branch")
    }

    /// A fix that only adds a commit is a fast-forward of the old tip: `merge --ff-only`.
    @Test func aFastForwardLandsWhereTheBranchIsCheckedOut() throws {
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        let old = try world.sha("HEAD", in: world.repo)
        let clone = try FixClone.make(for: request(branch: "feat/x"), git: git, root: world.root)
        defer { clone.remove() }
        try git.run(["rebase", "--abort"], in: clone.path)
        try world.commit("fix", file: "fix.txt", contents: "x\n", in: clone.path)
        let recording = RecordingGitRunner(forwardingTo: git)
        _ = try Repository(world.repo, git: recording).landFix(from: clone)
        #expect(try world.sha("HEAD", in: world.repo) == clone.tip("feat/x"))
        #expect(try git.run(["rev-parse", "HEAD~1"], in: world.repo) == old)
        #expect(recording.calls.contains { $0.args.contains("merge") && $0.args.contains("--ff-only") })
        #expect(!recording.calls.contains { $0.args.contains("reset") })
    }

    /// Git names the folder by its real path (`/private/var/…`), which is what the refusal carries.
    @Test func aCheckoutWithChangesIsRefusedAndNothingMoves() throws {
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        let old = try world.sha("HEAD", in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        try "dirty\n".write(toFile: world.repo + "/config.ts", atomically: true, encoding: .utf8)
        #expect(throws: FixRefusal.checkoutHasChanges(try git.run(["rev-parse", "--show-toplevel"], in: world.repo))) { try Repository(world.repo, git: git).landFix(from: clone) }
        #expect(try world.sha("HEAD", in: world.repo) == old)
        #expect(try String(contentsOfFile: world.repo + "/config.ts", encoding: .utf8) == "dirty\n")
        #expect(try git.run(["for-each-ref", "refs/aiterm"], in: world.repo).isEmpty, "no backup for a fix that did not land")
    }

    @Test func theTemporaryRefIsGone() throws {
        let clone = try resolvedClone(); defer { clone.remove() }
        _ = try Repository(world.repo, git: git).landFix(from: clone)
        #expect(try git.run(["for-each-ref", "refs/aiterm/fix"], in: world.repo).isEmpty)
    }

    /// The fetch runs with hooks off, in the repository the fix lands in.
    @Test func theFetchRunsWithHooksOff() throws {
        let clone = try resolvedClone(); defer { clone.remove() }
        let recording = RecordingGitRunner(forwardingTo: git)
        _ = try Repository(world.repo, git: recording).landFix(from: clone)
        let fetch = try #require(recording.calls.first { $0.args.contains("fetch") })
        #expect(fetch.args.starts(with: ["-c", "core.hooksPath=/dev/null", "fetch"]))
    }

    /// Review focus 1: a branch name with slashes all the way through.
    @Test func aDeepBranchNameLands() throws {
        world.removeAll()
        world = try ConflictWorld(git: git, branch: "feat/a/b")
        let clone = try resolvedClone(branch: "feat/a/b"); defer { clone.remove() }
        let landing = try Repository(world.repo, git: git).landFix(from: clone)
        #expect(landing.backup == "aiterm/backup/feat/a/b")
        #expect(try world.sha("feat/a/b", in: world.repo) == clone.tip("feat/a/b"))
        #expect(try world.sha("aiterm/backup/feat/a/b", in: world.repo) == landing.old)
    }

    @Test func theWorkflowLandsItOnItsQueue() async throws {
        let old = try world.sha("feat/x", in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        let project = Project(id: UUID(), name: "Repo", path: world.repo, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let landing = try await TaskWorkflow(git: git).landFix(from: clone, in: project)
        #expect(landing.old == old)
        #expect(try world.sha("feat/x", in: world.repo) == landing.new)
    }
}

/// Git that, just before the compare-and-swap `update-ref` of `branch`, commits on it from
/// elsewhere, as a terminal would in the instant between AiTerm's check and its move.
private final class MovingGitRunner: GitRunning {
    private let inner: any GitRunning, branch: String, repo: String
    private let didMove = Mutex(false)
    var moved: Bool { didMove.withLock { $0 } }

    init(inner: any GitRunning, branch: String, repo: String) { self.inner = inner; self.branch = branch; self.repo = repo }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if args.first == "update-ref", args.count == 4, args[1] == branch, !didMove.withLock({ let was = $0; $0 = true; return was }) {
            let tip = try inner.run(["rev-parse", branch], in: dir)
            let moved = try inner.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit-tree", "-p", tip, "-m", "meanwhile", tip + "^{tree}"], in: dir)
            try inner.run(["update-ref", branch, moved], in: dir)
        }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}
