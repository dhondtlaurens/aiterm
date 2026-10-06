import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import AiTermCore
@testable import AiTermTestSupport

/// "Pull main": the project's default branch brought to origin's, fast-forward only, wherever
/// it is checked out — or nowhere.
@Suite(.blocking) final class DefaultBranchPullTests {
    let git = GitRunner.hermetic()
    /// The project's checkout, a clone of `remote`, on the default branch.
    let repo: String
    /// Someone else's clone of the same origin, whose pushes `repo` has not fetched.
    let other: String
    /// Every folder `clones` made, removed with the test.
    private var roots: [String] = []

    init() throws {
        var made: [String] = []
        (repo, other) = try Self.clones(defaultBranch: "main", git: .hermetic(), into: &made)
        roots = made
    }
    deinit { for root in roots { try? FileManager.default.removeItem(atPath: root) } }

    @Test func testFastForwardsTheBranchWhereItIsCheckedOut() throws {
        try push(2, from: other)
        #expect(try Repository(repo, git: git).pullDefaultBranch() == .fastForwarded("main", commits: 2))
        #expect(try sha("main", in: repo) == sha("main", in: other))
        #expect(try sha("HEAD", in: repo) == sha("main", in: other), "the checkout's files moved with it")
        #expect(try git.run(["status", "--porcelain"], in: repo).isEmpty)
    }

    @Test func testMovesTheBranchWhenNoCheckoutHasIt() throws {
        _ = try git.run(["checkout", "-q", "-b", "feat/elsewhere"], in: repo)
        try push(1, from: other)
        #expect(try Repository(repo, git: git).pullDefaultBranch() == .fastForwarded("main", commits: 1))
        #expect(try sha("main", in: repo) == sha("main", in: other))
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) == "feat/elsewhere", "the checkout is untouched")
    }

    /// A rebase of main stopped in the project's checkout detaches HEAD there, so no checkout is
    /// listed with main. Moving the ref under it would break the person's `rebase --continue`;
    /// git's own fetch into a local branch refuses a branch mid-rebase, and so the pull does.
    @Test func testLeavesABranchMidRebaseAlone() throws {
        try push(1, from: repo)
        _ = try git.run(["pull", "-q", "--ff-only"], in: other)
        #expect(throws: GitError.self) { try git.run(["rebase", "--exec", "false", "HEAD~1"], in: repo) }
        try push(1, from: other)
        let before = try sha("main", in: repo)
        #expect(throws: GitError.self) { try Repository(repo, git: git).pullDefaultBranch() }
        #expect(try sha("main", in: repo) == before)
        #expect(throws: Never.self) { try git.run(["rebase", "--continue"], in: repo) }
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) == "main")
    }

    @Test func testSaysSoWhenAlreadyUpToDate() throws {
        #expect(try Repository(repo, git: git).pullDefaultBranch() == .upToDate("main"))
    }

    @Test func testLeavesUnpushedCommitsAlone() throws {
        try commit("local", in: repo)
        let before = try sha("main", in: repo)
        #expect(try Repository(repo, git: git).pullDefaultBranch() == .ahead("main", commits: 1))
        #expect(try sha("main", in: repo) == before)
    }

    @Test func testRefusesADivergedBranchAndMovesNothing() throws {
        try commit("local", in: repo)
        try push(1, from: other)
        let before = try sha("main", in: repo)
        #expect(throws: WorktreeError.defaultBranchDiverged("main", local: 1, remote: 1)) { try Repository(repo, git: git).pullDefaultBranch() }
        #expect(try sha("main", in: repo) == before)
    }

    /// Task 38 review: a git that could not say whether one tip contains the other — it timed out —
    /// has not said the branches diverged. The pull fails with git's reason, and moves nothing.
    @Test func aPullGitCannotCompareFailsWithGitsReasonNotAsDiverged() throws {
        try push(1, from: other)
        let before = try sha("main", in: repo)
        #expect { try Repository(repo, git: TimingOutGitRunner(["merge-base"])).pullDefaultBranch() } throws: { error in
            (error as? GitError)?.timedOut == true
        }
        #expect(try sha("main", in: repo) == before)
    }

    @Test func testSaysHowFarADivergedBranchIsFromOrigin() throws {
        #expect(WorktreeError.defaultBranchDiverged("main", local: 4, remote: 23).errorDescription
                == "Your local “main” has 4 commits that aren’t on origin, and origin has 23 commits it doesn’t.")
        #expect(WorktreeError.defaultBranchDiverged("main", local: 1, remote: 1).errorDescription
                == "Your local “main” has 1 commit that isn’t on origin, and origin has 1 commit it doesn’t.")
    }

    // -- rebasing a diverged default branch ------------------------------------------------

    @Test func testRebasesTheBranchWhereItIsCheckedOut() throws {
        try change("file.txt", to: "mine\n", in: repo)
        try push(2, from: other)
        #expect(try Repository(repo, git: git).rebaseDefaultBranch() == DefaultBranchRebase(branch: "main", ahead: 1))
        #expect(try git.run(["rev-parse", "main~1"], in: repo) == sha("main", in: other), "origin's commits are under the local one")
        #expect(try sha("HEAD", in: repo) == sha("main", in: repo))
        #expect(try String(contentsOfFile: repo + "/file.txt", encoding: .utf8) == "mine\n")
        #expect(try git.run(["status", "--porcelain"], in: repo).isEmpty)
    }

    /// A bare project, or one whose checkout is on another branch: the rebase needs a checkout,
    /// so it gets one of its own for as long as it runs.
    @Test func testRebasesTheBranchWhenNoCheckoutHasIt() throws {
        try change("file.txt", to: "mine\n", in: repo)
        _ = try git.run(["checkout", "-q", "-b", "feat/elsewhere"], in: repo)
        try push(1, from: other)
        #expect(try Repository(repo, git: git).rebaseDefaultBranch() == DefaultBranchRebase(branch: "main", ahead: 1))
        #expect(try git.run(["rev-parse", "main~1"], in: repo) == sha("main", in: other))
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) == "feat/elsewhere", "the checkout is untouched")
        #expect(try Repository(repo, git: git).worktrees().count == 1, "the rebase's own checkout is gone")
    }

    /// The rebase's own checkout is only scratch: making it runs no `post-checkout` hook (a husky
    /// setup's `npm install`) and downloads no LFS files.
    @Test func testMakesItsOwnCheckoutWithoutHooksOrLFS() throws {
        let marker = repo + "/../probe.log"
        let hook = repo + "/.git/hooks/post-checkout"
        try "#!/bin/sh\necho \"hook $1\" >> '\(marker)'\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        _ = try git.run(["config", "filter.probe.smudge", "sh -c 'echo \"smudge ${GIT_LFS_SKIP_SMUDGE:-unset}\" >> \"\(marker)\"; cat'"], in: repo)
        try change(".gitattributes", to: "*.txt filter=probe\n", in: repo)
        try change("file.txt", to: "mine\n", in: repo)
        _ = try git.run(["checkout", "-q", "-b", "feat/elsewhere"], in: repo)
        try? FileManager.default.removeItem(atPath: marker)
        try push(1, from: other)

        #expect(try Repository(repo, git: git).rebaseDefaultBranch() == DefaultBranchRebase(branch: "main", ahead: 2))
        let log = (try? String(contentsOfFile: marker, encoding: .utf8)) ?? ""
        #expect(!log.contains("hook 0000000000000000000000000000000000000000"), "no hook for the new checkout")
        #expect(log.split(separator: "\n").first == "smudge 1", "the new checkout's files are not smudged")
    }

    /// A rebase's checkout the app died before removing still has the branch checked out, which
    /// makes every `git checkout` of it fail and would have the next pull merge there. The next pull
    /// or rebase removes it first.
    @Test(arguments: [false, true]) func testRemovesTheCheckoutOfARebaseThatNeverFinished(rebase: Bool) throws {
        let stale = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-rebase-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: stale) }
        if rebase { try change("file.txt", to: "mine\n", in: repo) }
        _ = try git.run(["checkout", "-q", "-b", "feat/elsewhere"], in: repo)
        _ = try git.run(["worktree", "add", "-q", stale, "main"], in: repo)
        try push(1, from: other)

        if rebase { #expect(try Repository(repo, git: git).rebaseDefaultBranch() == DefaultBranchRebase(branch: "main", ahead: 1)) }
        else { #expect(try Repository(repo, git: git).pullDefaultBranch() == .fastForwarded("main", commits: 1)) }
        #expect(try Repository(repo, git: git).worktrees().count == 1)
        #expect(!FileManager.default.fileExists(atPath: stale))
    }

    /// A rebase in its own checkout that git refuses for a reason other than a conflict — here a
    /// `pre-rebase` hook — throws git's reason, and the checkout still goes.
    @Test func testRemovesItsOwnCheckoutWhenTheRebaseIsRefused() throws {
        let hook = repo + "/.git/hooks/pre-rebase"
        try "#!/bin/sh\necho 'no rebasing here' >&2\nexit 1\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        try change("file.txt", to: "mine\n", in: repo)
        _ = try git.run(["checkout", "-q", "-b", "feat/elsewhere"], in: repo)
        try push(1, from: other)
        let before = try sha("main", in: repo)
        #expect(throws: GitError.self) { try Repository(self.repo, git: self.git).rebaseDefaultBranch() }
        #expect(try sha("main", in: repo) == before)
        #expect(try Repository(repo, git: git).worktrees().count == 1, "the rebase's own checkout is gone")
    }

    /// Checked out in a linked worktree rather than the project's checkout, the branch is merged
    /// there, and its files move with it.
    @Test func testFastForwardsTheBranchInTheLinkedWorktreeThatHasIt() throws {
        _ = try git.run(["checkout", "-q", "-b", "feat/elsewhere"], in: repo)
        let linked = repo + "/../linked"
        _ = try git.run(["worktree", "add", "-q", linked, "main"], in: repo)
        try push(1, from: other)
        #expect(try Repository(repo, git: git).pullDefaultBranch() == .fastForwarded("main", commits: 1))
        #expect(try sha("HEAD", in: linked) == sha("main", in: other))
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) == "feat/elsewhere")
    }

    /// Origin has the default branch, but there is no local one to bring up to date.
    @Test func testRefusesAProjectWithoutALocalDefaultBranch() throws {
        _ = try git.run(["checkout", "-q", "-b", "feat/elsewhere"], in: repo)
        _ = try git.run(["branch", "-q", "-D", "main"], in: repo)
        try push(1, from: other)
        #expect(throws: WorktreeError.noLocalBranch("main")) { try Repository(self.repo, git: self.git).pullDefaultBranch() }
    }

    /// `git rebase` replays commits, not merges: a branch merged locally arrives as its commits.
    @Test func testDropsLocalMergeCommits() throws {
        _ = try git.run(["checkout", "-q", "-b", "feat/notes"], in: repo)
        try change("notes.txt", to: "notes\n", in: repo)
        _ = try git.run(["checkout", "-q", "main"], in: repo)
        _ = try git.run(["merge", "-q", "--no-ff", "-m", "Merge feat/notes", "feat/notes"], in: repo)
        try push(1, from: other)
        #expect(try Repository(repo, git: git).rebaseDefaultBranch() == DefaultBranchRebase(branch: "main", ahead: 1))
        #expect(try git.run(["log", "-1", "--format=%s", "main"], in: repo) == "change notes.txt")
    }

    /// Pinned on the command line, whatever the repository's config asks: merges are still
    /// dropped, and a branch pointing into the rewritten commits is not dragged along with them.
    @Test func testDropsMergesAndMovesNoOtherBranchWhateverConfigSays() throws {
        _ = try git.run(["config", "rebase.rebaseMerges", "true"], in: repo)
        _ = try git.run(["config", "rebase.updateRefs", "true"], in: repo)
        _ = try git.run(["checkout", "-q", "-b", "feat/notes"], in: repo)
        try change("notes.txt", to: "notes\n", in: repo)
        _ = try git.run(["checkout", "-q", "main"], in: repo)
        _ = try git.run(["merge", "-q", "--no-ff", "-m", "Merge feat/notes", "feat/notes"], in: repo)
        let notes = try sha("feat/notes", in: repo)
        try push(1, from: other)
        #expect(try Repository(repo, git: git).rebaseDefaultBranch() == DefaultBranchRebase(branch: "main", ahead: 1))
        #expect(try git.run(["log", "-1", "--format=%s", "main"], in: repo) == "change notes.txt")
        #expect(try git.run(["rev-list", "--merges", "--count", "origin/main..main"], in: repo) == "0")
        #expect(try sha("feat/notes", in: repo) == notes)
    }

    @Test func testAbortsAConflictedRebaseAndMovesNothing() throws {
        try change("file.txt", to: "mine\n", in: repo)
        try change("file.txt", to: "theirs\n", in: other)
        _ = try git.run(["push", "-q", "origin", "main"], in: other)
        let before = try sha("main", in: repo)
        #expect(throws: WorktreeError.rebaseConflicted("main")) { try Repository(repo, git: git).rebaseDefaultBranch() }
        #expect(try sha("main", in: repo) == before)
        #expect(try sha("HEAD", in: repo) == before)
        #expect(try git.run(["status", "--porcelain"], in: repo).isEmpty, "no rebase left in progress")
        #expect(try String(contentsOfFile: repo + "/file.txt", encoding: .utf8) == "mine\n")
    }

    @Test func testAbortsAConflictedRebaseInItsOwnCheckout() throws {
        try change("file.txt", to: "mine\n", in: repo)
        _ = try git.run(["checkout", "-q", "-b", "feat/elsewhere"], in: repo)
        try change("file.txt", to: "theirs\n", in: other)
        _ = try git.run(["push", "-q", "origin", "main"], in: other)
        let before = try sha("main", in: repo)
        #expect(throws: WorktreeError.rebaseConflicted("main")) { try Repository(repo, git: git).rebaseDefaultBranch() }
        #expect(try sha("main", in: repo) == before)
        #expect(try Repository(repo, git: git).worktrees().count == 1)
    }

    /// A rebase someone already has under way is theirs: git refuses the new one, and it is not
    /// aborted. Stopped, it detaches HEAD; this one's checkout went back to the branch mid-way, so
    /// the branch is listed as checked out there with the rebase still pending.
    @Test func testLeavesARebaseAlreadyUnderWayAlone() throws {
        try change("file.txt", to: "mine\n", in: repo)
        try change("file.txt", to: "theirs\n", in: other)
        _ = try git.run(["push", "-q", "origin", "main"], in: other)
        _ = try git.run(["fetch", "-q", "origin"], in: repo)
        #expect(throws: GitError.self) { try git.run(["rebase", "origin/main"], in: repo) }
        _ = try git.run(["checkout", "-q", "-f", "main"], in: repo)
        #expect(throws: GitError.self) { try Repository(repo, git: git).rebaseDefaultBranch() }
        #expect(throws: Never.self) { try git.run(["rebase", "--abort"], in: repo) }
    }

    /// Git refuses to overwrite uncommitted changes; the branch stays where it was with them.
    @Test func testRefusesToOverwriteUncommittedChanges() throws {
        try "theirs\n".write(toFile: other + "/file.txt", atomically: true, encoding: .utf8)
        _ = try git.run(["add", "file.txt"], in: other)
        try commit("add file", in: other)
        _ = try git.run(["push", "-q", "origin", "main"], in: other)
        try "mine\n".write(toFile: repo + "/file.txt", atomically: true, encoding: .utf8)
        let before = try sha("main", in: repo)
        // The refusal names the file, so the banner can too.
        #expect { try Repository(self.repo, git: self.git).pullDefaultBranch() } throws: { error in
            GitError.sentence(of: error).hasSuffix("would be overwritten by merge: file.txt.")
        }
        #expect(try sha("main", in: repo) == before)
        #expect(try String(contentsOfFile: repo + "/file.txt", encoding: .utf8) == "mine\n")
    }

    /// A repository set to stash dirty files around a merge or a rebase still has them refused:
    /// with its stash, git fast-forwards, fails to put them back, and exits 0 with conflict markers
    /// in the files and the edits in the stash.
    @Test func testRefusesUncommittedChangesWhateverAutoStashSays() throws {
        _ = try git.run(["config", "merge.autoStash", "true"], in: repo)
        _ = try git.run(["config", "rebase.autoStash", "true"], in: repo)
        try change("file.txt", to: "base\n", in: repo)
        _ = try git.run(["push", "-q", "origin", "main"], in: repo)
        _ = try git.run(["pull", "-q", "--ff-only"], in: other)
        try change("file.txt", to: "theirs\n", in: other)
        _ = try git.run(["push", "-q", "origin", "main"], in: other)
        try "mine\n".write(toFile: repo + "/file.txt", atomically: true, encoding: .utf8)
        let before = try sha("main", in: repo)

        #expect(throws: GitError.self) { try Repository(repo, git: git).pullDefaultBranch() }
        #expect(try sha("main", in: repo) == before)
        #expect(try String(contentsOfFile: repo + "/file.txt", encoding: .utf8) == "mine\n")

        try change("local.txt", to: "local\n", in: repo)
        let diverged = try sha("main", in: repo)
        #expect(throws: GitError.self) { try Repository(repo, git: git).rebaseDefaultBranch() }
        #expect(try sha("main", in: repo) == diverged)
        #expect(try String(contentsOfFile: repo + "/file.txt", encoding: .utf8) == "mine\n")
        #expect(try git.run(["stash", "list"], in: repo).isEmpty)
    }

    /// A clone of an empty repository, or a remote added by hand, has no `origin/HEAD`; the branch
    /// is then whichever of the usual names exists, not always `main`.
    @Test func testFindsMasterWithoutOriginHead() throws {
        let (repo, other) = try Self.clones(defaultBranch: "master", git: git, into: &roots)
        _ = try? git.run(["remote", "set-head", "origin", "--delete"], in: repo)
        #expect(Repository(repo, git: git).defaultBranch() == "master")
        try push(1, from: other)
        #expect(try Repository(repo, git: git).pullDefaultBranch() == .fastForwarded("master", commits: 1))
    }

    /// A default branch with a slash in its name is named whole, not by its last part.
    @Test func testNamesADefaultBranchWithASlash() throws {
        let (repo, other) = try Self.clones(defaultBranch: "release/x", git: git, into: &roots)
        _ = try git.run(["remote", "set-head", "origin", "--auto"], in: repo)
        #expect(Repository(repo, git: git).defaultBranch() == "release/x")
        try push(1, from: other)
        #expect(try Repository(repo, git: git).pullDefaultBranch() == .fastForwarded("release/x", commits: 1))
    }

    /// After the default branch is renamed on origin, a clone's `origin/HEAD` still names the old
    /// one. That name is not trusted: whichever of the usual names exists is.
    @Test func testFallsBackWhenOriginHeadNamesABranchThatIsGone() throws {
        _ = try git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"], in: repo)
        #expect(Repository(repo, git: git).defaultBranch() == "main")
        try push(1, from: other)
        #expect(try Repository(repo, git: git).pullDefaultBranch() == .fastForwarded("main", commits: 1))
    }

    @Test func testRefusesAProjectWithoutOrigin() throws {
        _ = try git.run(["remote", "remove", "origin"], in: repo)
        #expect(throws: WorktreeError.noOrigin) { try Repository(repo, git: git).pullDefaultBranch() }
    }

    // -- helpers ------------------------------------------------------------------------

    /// A bare origin on `defaultBranch` with one commit, and two clones of it, all in a folder
    /// added to `roots`.
    private static func clones(defaultBranch: String, git: any GitRunning, into roots: inout [String]) throws -> (repo: String, other: String) {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pull-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let root = realPath(raw)
        roots.append(root)
        let remote = root + "/remote.git", repo = root + "/repo", other = root + "/other"
        _ = try git.run(["init", "-q", "--bare", "-b", defaultBranch, remote], in: root)
        _ = try git.run(["clone", "-q", remote, repo], in: root)
        // A rebase commits as whoever git is configured with; the tests cannot rely on a global one.
        _ = try git.run(["config", "user.name", "t"], in: repo)
        _ = try git.run(["config", "user.email", "t@t"], in: repo)
        _ = try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        _ = try git.run(["push", "-q", "origin", "HEAD:" + defaultBranch], in: repo)
        _ = try git.run(["clone", "-q", remote, other], in: root)
        return (repo, other)
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func sha(_ ref: String, in dir: String) throws -> String { try git.run(["rev-parse", ref], in: dir) }
    private func commit(_ message: String, in dir: String) throws {
        _ = try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", message], in: dir)
    }
    /// A commit on `dir`'s current branch that writes `contents` to `file`.
    private func change(_ file: String, to contents: String, in dir: String) throws {
        try contents.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        _ = try git.run(["add", file], in: dir)
        try commit("change \(file)", in: dir)
    }
    /// `count` new commits on `dir`'s current branch, pushed to origin.
    private func push(_ count: Int, from dir: String) throws {
        for i in 0..<count { try commit("upstream \(i)", in: dir) }
        _ = try git.run(["push", "-q", "origin", "HEAD"], in: dir)
    }
}
