import Testing
import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#endif
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct WorktreesTests {
    let git = GitRunner.hermetic()
    var repo: String

    /// Fully resolves symlinks in `path` using POSIX `realpath(3)`, matching what real `git`
    /// reports for `rev-parse --show-toplevel` and `worktree list --porcelain`. Foundation's
    /// `URL.resolvingSymlinksInPath()` cannot be used here: on this toolchain it special-cases
    /// `/tmp`, `/var` and `/etc` and, for a path that already exists on disk, normalizes back to
    /// the short alias (e.g. `/private/var/...` -> `/var/...`) instead of the physical path git
    /// actually returns, so it can never agree with git's output for a temp-directory repo.
    private static func realPath(_ path: String) -> String {
        guard let cResolved = realpath(path, nil) else { return path }
        defer { free(cResolved) }
        return String(cString: cResolved)
    }

    init() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        repo = Self.realPath(raw)
        _ = try git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
    }

    @Test func missingDirectoryNeverFallsBackToTheAppsRepository() throws {
        #expect(throws: (any Error).self) { try git.run(["rev-parse", "--show-toplevel"], in: repo + "/missing") }
    }

    @Test func testSlugAndBranchName() {
        #expect(BranchNaming.slug("Add graceful SIGTERM shutdown to the worker (drain in-flight tasks, fail-fast the rest)") == "add-graceful-sigterm-shutdown-to-the-worker-drai")
        #expect(BranchNaming.branchSlug(key: "WEB-5447", summary: "Add graceful SIGTERM") == "web-5447-add-graceful-sigterm")
        #expect(BranchNaming.branchSlug(key: nil, summary: "Sidebar avatars") == "sidebar-avatars")
    }

    @Test func testToplevelAndDefaultBranchWithoutRemote() throws {
        #expect(try Repository.toplevel(of: repo + "/", git: git) == repo)
        #expect(try Repository.toplevel(of: FileManager.default.temporaryDirectory.path, git: git) == nil)
        #expect(Repository(repo, git: git).defaultBranch() == "main")
        #expect(try Repository(repo, git: git).remoteUrl() == nil)
        #expect(BranchNaming.isValid("feat/x-1", git: git))
        #expect(!BranchNaming.isValid("feat//bad..name", git: git))
    }

    /// "No remote" is git's answer; a timeout is not, and reads as an error rather than as `nil`.
    @Test func aRemoteLookupThatFailsIsNotAnAnswer() throws {
        let flaky = FlakyGitRunner()
        flaky.failing = true
        #expect(throws: GitError.self) { try Repository(repo, git: flaky).remoteUrl() }
        flaky.failing = false
        #expect(try Repository(repo, git: flaky).remoteUrl() == nil)
        _ = try git.run(["remote", "add", "origin", "git@example.com:app.git"], in: repo)
        #expect(try Repository(repo, git: flaky).remoteUrl() == "git@example.com:app.git")
        flaky.failing = true
        #expect(throws: GitError.self) { try Repository(repo, git: flaky).remoteUrl() }
    }

    /// The remote the checked-out branch tracks wins over `origin`, and a remote that is not
    /// called origin is found when there is no other.
    @Test func remoteUrlPrefersTheUpstreamThenOriginThenAnyRemote() throws {
        _ = try git.run(["remote", "add", "fork", "git@example.com:fork.git"], in: repo)
        #expect(try Repository(repo, git: git).remoteUrl() == "git@example.com:fork.git")
        _ = try git.run(["remote", "add", "origin", "git@example.com:app.git"], in: repo)
        #expect(try Repository(repo, git: git).remoteUrl() == "git@example.com:app.git")
        _ = try git.run(["config", "branch.main.remote", "fork"], in: repo)
        _ = try git.run(["config", "branch.main.merge", "refs/heads/main"], in: repo)
        _ = try git.run(["update-ref", "refs/remotes/fork/main", "HEAD"], in: repo)
        #expect(try Repository(repo, git: git).remoteUrl() == "git@example.com:fork.git")
    }

    /// A detached HEAD has no upstream and a repository without a commit has no branch to ask: git
    /// answers 128 to `@{upstream}` for both, which is "no remote here" and not a failure.
    @Test func remoteUrlOfADetachedOrUnbornRepositoryIsNilNotAnError() throws {
        try git.run(["checkout", "-q", "--detach"], in: repo)
        #expect(try Repository(repo, git: git).remoteUrl() == nil)
        _ = try git.run(["remote", "add", "origin", "git@example.com:app.git"], in: repo)
        #expect(try Repository(repo, git: git).remoteUrl() == "git@example.com:app.git", "detached, it falls through to origin")

        let unborn = repo + "-unborn"
        defer { try? FileManager.default.removeItem(atPath: unborn) }
        try git.run(["init", "-q", "-b", "main", unborn], in: "/")
        #expect(try Repository(unborn, git: git).remoteUrl() == nil)
        _ = try git.run(["remote", "add", "origin", "git@example.com:unborn.git"], in: unborn)
        #expect(try Repository(unborn, git: git).remoteUrl() == "git@example.com:unborn.git")
    }

    /// A default branch git cannot name is `nil`, and the name shown for it is "main"; a git that
    /// times out names nothing, and says so rather than naming "main".
    @Test func aDefaultBranchLookupThatFailsIsNotTheFallback() throws {
        _ = try git.run(["branch", "-m", "main", "trunk"], in: repo)
        #expect(try Repository(repo, git: git).detectDefaultBranch() == nil)
        #expect(Repository(repo, git: git).defaultBranch() == "main")
        _ = try git.run(["branch", "-m", "trunk", "master"], in: repo)
        let flaky = FlakyGitRunner()
        #expect(try Repository(repo, git: flaky).detectDefaultBranch() == "master")
        flaky.failing = true
        #expect(throws: GitError.self) { try Repository(repo, git: flaky).detectDefaultBranch() }
    }

    /// The base-branch popup is fed by git, not by a guess: the default branch leads, local
    /// branches follow, and a branch that only exists on origin is offered under its short name.
    @Test func testBranchesListsDefaultFirstThenLocalsAndRemoteOnly() throws {
        _ = try git.run(["branch", "release/2026-09"], in: repo)
        _ = try git.run(["branch", "feat/local-only"], in: repo)
        // A bare clone stood up as `origin`, then a branch pushed to it and deleted locally, is the
        // only honest way to make a remote-only branch.
        let remote = Self.realPath(FileManager.default.temporaryDirectory.appendingPathComponent("wt-remote-\(UUID().uuidString)").path)
        _ = try git.run(["init", "-q", "--bare", remote], in: repo)
        _ = try git.run(["remote", "add", "origin", remote], in: repo)
        _ = try git.run(["branch", "feat/remote-only"], in: repo)
        _ = try git.run(["push", "-q", "origin", "main", "release/2026-09", "feat/local-only", "feat/remote-only"], in: repo)
        _ = try git.run(["branch", "-D", "feat/remote-only"], in: repo)

        let found = Repository(repo, git: git).branches()
        #expect(found.first == "main", "the default branch leads, whatever its commit date")
        #expect(found.contains("release/2026-09"))
        #expect(found.contains("feat/local-only"))
        #expect(found.contains("feat/remote-only"), "a branch that exists only on origin is still a valid base")
        #expect(!found.contains("origin/main"), "a remote branch is offered under its short name")
        #expect(!found.contains("HEAD"))
        #expect(Set(found).count == found.count, "a branch that is both local and on origin appears once")
    }

    @Test func testCreateLocksExcludesAndListsThenRemoves() throws {
        let path = try Repository(repo, git: git).addTaskWorktree(slug: "web-1-thing", branch: "feat/web-1-thing", base: "main")
        #expect(path == repo + "/.worktrees/web-1-thing")
        #expect(FileManager.default.fileExists(atPath: path + "/.git"))
        let exclude = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.contains(".worktrees/"))
        let list = try Repository(repo, git: git).managedWorktrees()
        #expect(list.map(\.branch) == ["feat/web-1-thing"])
        #expect(list.map(\.lockReason) == [Worktree.taskLockReason])
        #expect(try git.run(["worktree", "list", "--porcelain"], in: repo).contains("locked"))
        #expect(try git.run(["status", "--porcelain"], in: repo).isEmpty, "worktree dir must not show as untracked")
        try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: "feat/web-1-thing", force: false)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: (any Error).self) { try git.run(["rev-parse", "--verify", "feat/web-1-thing"], in: repo) }
    }

    /// A branch git will not delete must not skip the prune that follows: a stale entry left by a
    /// checkout deleted outside git stays listed until something prunes it.
    @Test func aRefusedBranchDeletionStillPrunes() throws {
        let path = try Repository(repo, git: git).addTaskWorktree(slug: "a", branch: "feat/a", base: "main")
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "unmerged"], in: path)
        let stale = repo + "/.worktrees/stale"
        try git.run(["worktree", "add", "-q", "-b", "feat/stale", stale], in: repo)
        try FileManager.default.removeItem(atPath: stale)

        #expect(throws: GitError.self) { try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: "feat/a", force: false) }
        #expect(try Repository(repo, git: git).worktrees().map(\.path) == [repo])
    }

    /// git drops its record of a worktree even when it cannot delete all of it. What it leaves is
    /// a folder no git knows, and removing that again used to fail "is not a working tree" for good.
    @Test func aRemovalGitGaveUpOnHalfwayIsFinishedByTheNext() throws {
        let path = try Repository(repo, git: git).addTaskWorktree(slug: "a", branch: "feat/a", base: "main")
        // Git's half: the checkout and its registration gone, a folder of build output left.
        try git.run(["worktree", "unlock", path], in: repo)
        try git.run(["worktree", "remove", path], in: repo)
        try FileManager.default.createDirectory(atPath: path + "/app/.nuxt", withIntermediateDirectories: true)
        try "export {}\n".write(toFile: path + "/app/.nuxt/nuxt.d.ts", atomically: true, encoding: .utf8)

        try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: "feat/a", force: false)

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try Repository(repo, git: git).worktrees().map(\.path) == [repo])
        #expect(try git.run(["for-each-ref", "--format=%(refname)", "refs/heads/feat/a"], in: repo).isEmpty)
    }

    /// The same failure, as it happens: a process still running in the checkout — a dev server's
    /// watcher — writes files back while git deletes it, and git gives up after dropping its record.
    @Test func aRemovalGitGivesUpOnHalfwayStillFinishes() throws {
        let path = try Repository(repo, git: git).addTaskWorktree(slug: "a", branch: "feat/a", base: "main")

        try Repository(repo, git: RefillingGitRunner()).removeWorktree(at: path, deleteBranch: nil, force: false)

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try Repository(repo, git: git).worktrees().map(\.path) == [repo])
    }

    /// Only a leftover of AiTerm's own is deleted: a folder outside `.worktrees/` that git does not
    /// know as a worktree is refused and kept, whatever is in it.
    @Test func aFolderOutsideTheWorktreesIsNeverDeleted() throws {
        let folder = repo + "/notes"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) { try Repository(repo, git: git).removeWorktree(at: folder, deleteBranch: nil, force: true) }
        #expect(FileManager.default.fileExists(atPath: folder))
    }

    /// Unsaved work is what `git worktree remove` refuses without `--force`, asked ahead of it so a
    /// window can close before anything is deleted — and never of a folder git no longer knows,
    /// where `git status` would answer for the project's own checkout.
    @Test func unsavedWorkIsWhatRemoveWouldRefuse() throws {
        let path = try Repository(repo, git: git).addTaskWorktree(slug: "a", branch: "feat/a", base: "main")
        #expect(try !Repository(repo, git: git).hasUnsavedWork(at: path))
        try "draft".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
        #expect(try Repository(repo, git: git).hasUnsavedWork(at: path))

        try "dirty".write(toFile: repo + "/project.txt", atomically: true, encoding: .utf8)
        try git.run(["worktree", "unlock", path], in: repo)
        try git.run(["worktree", "remove", "--force", path], in: repo)
        try FileManager.default.createDirectory(atPath: path + "/app", withIntermediateDirectories: true)
        #expect(try !Repository(repo, git: git).hasUnsavedWork(at: path))
    }

    /// Only the leading `refs/heads/` is git's; the rest is the branch's name.
    @Test func aBranchNameContainingRefsHeadsIsListedWhole() throws {
        let path = repo + "/.worktrees/odd"
        try git.run(["worktree", "add", "-q", "-b", "x/refs/heads/y", path], in: repo)
        #expect(try Repository(repo, git: git).worktrees().first { $0.path == path }?.branch == "x/refs/heads/y")
    }

    /// Final review item C: a linked worktree added as a project is an ordinary repository path as
    /// far as AiTerm is concerned, but its `.git` is a *file*, so the old
    /// `<repo>/.git/info/exclude` assumption made `create` throw before git ever ran. Resolving the
    /// exclude file with `git rev-parse --git-path info/exclude` puts the line in the common dir's
    /// `info/exclude` — the main repository's — which is where git reads it from for every worktree.
    @Test func testCreateInsideALinkedWorktreeExcludesInTheCommonDir() throws {
        let linked = try Repository(repo, git: git).addTaskWorktree(slug: "outer", branch: "feat/outer", base: "main")
        #expect(!((try? FileManager.default.attributesOfItem(atPath: linked + "/.git")[.type] as? FileAttributeType) == .typeDirectory),
                "a linked worktree's .git must be a file for this test to mean anything")

        // Clear the line the outer `create` wrote, so what the assertions below see can only have
        // come from the nested create resolving the common dir's exclude file.
        try "".write(toFile: repo + "/.git/info/exclude", atomically: true, encoding: .utf8)

        let nested = try Repository(linked, git: git).addTaskWorktree(slug: "inner", branch: "feat/inner", base: "main")
        #expect(nested == linked + "/.worktrees/inner")
        #expect(FileManager.default.fileExists(atPath: nested + "/.git"))

        let exclude = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.contains(".worktrees/"))
        #expect(exclude.components(separatedBy: ".worktrees/").count - 1 == 1, "the exclude line must not be duplicated per worktree")
        #expect(try git.run(["status", "--porcelain"], in: linked).isEmpty, "the nested worktree dir must not show as untracked")
    }

    @Test func testCreateFailsCleanlyOnExistingBranch() throws {
        _ = try git.run(["branch", "feat/dup"], in: repo)
        let error = #expect(throws: (any Error).self) { try Repository(repo, git: git).addTaskWorktree(slug: "dup", branch: "feat/dup", base: "main") }
        #expect((error as? GitError)?.stderr.contains("already exists") ?? false)
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/dup"))
    }

    /// Not every failed add leaves nothing: one whose `post-checkout` hook fails is reported as a
    /// failure, yet git keeps the checkout — and keeps it locked, the lock being part of the add.
    @Test func anAddWhoseHookFailsLeavesALockedWorktree() throws {
        let hook = repo + "/.git/hooks/post-checkout"
        try FileManager.default.createDirectory(atPath: repo + "/.git/hooks", withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 1\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        #expect(throws: GitError.self) { try Repository(repo, git: git).addTaskWorktree(slug: "hooked", branch: "feat/hooked", base: "main") }
        let left = try Repository(repo, git: git).worktrees().first { $0.branch == "feat/hooked" }
        #expect(left?.lockReason == Worktree.taskLockReason)
    }

    @Test func testRefusesSymlinkedWorktreesDir() throws {
        try FileManager.default.createSymbolicLink(atPath: repo + "/.worktrees", withDestinationPath: "/tmp")
        #expect(throws: (any Error).self) { try Repository(repo, git: git).addTaskWorktree(slug: "x", branch: "feat/x", base: "main") }
    }

    /// `GitRunner.run` used to read stdout to EOF, then stderr to EOF,
    /// then `waitUntilExit()`. A pipe's kernel buffer is ~64 KB; a child that writes more than
    /// that to stderr while `run` is still blocked draining stdout would fill the stderr pipe,
    /// block the child on its next stderr write, and deadlock `run` forever (classic `Process`
    /// two-pipe deadlock). There's no portable git subcommand that reliably emits >64 KB of
    /// stderr, so this test points `GitRunner` at a throwaway shell script standing in for
    /// "git": it writes 200,000 bytes (well over 64 KB) to stderr via `yes | head -c 200000 >&2`
    /// while also writing to stdout, then exits 0. The call is raced against a 10s timeout on a
    /// background thread so a regression fails the test instead of hanging the suite.
    @Test func testRunDoesNotDeadlockOnLargeStderr() throws {
        let script = repo + "/fake-git-big-stderr.sh"
        try "#!/bin/sh\nyes e | head -c 200000 >&2\necho ok\nexit 0\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let bigStderrGit = GitRunner(git: script)
        let repoPath = repo

        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<Result<String, Error>?>(nil)
        // A real thread, as ProcessRunner's own readers are: a `DispatchQueue.global()` block can
        // wait out the whole deadline under the parallel runner, once every worker is parked.
        Thread {
            let outcome = Result { try bigStderrGit.run([], in: repoPath) }
            result.withLock { $0 = outcome }
            semaphore.signal()
        }.start()

        guard semaphore.wait(timeout: .now() + 10) == .success else {
            Issue.record("GitRunner.run hung for >10s reading a >64KB stderr pipe (pipe deadlock regression)")
            return
        }
        switch result.withLock({ $0 }) {
        case .success(let output): #expect(output == "ok")
        case .failure(let error): Issue.record("expected success, got \(error)")
        case nil: Issue.record("semaphore signalled without a result")
        }
    }

    /// A bare remote carrying `feat/mr-branch`, cloned into a working repo whose only local branch is
    /// `main`. This is the shape a review actually meets: the branch exists on origin and nowhere else.
    private func repoWithRemoteOnlyBranch() throws -> String {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("rv-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let root = Self.realPath(raw)   // after creating it: `realpath` of a missing path resolves nothing
        let remote = root + "/remote.git", work = root + "/work"
        _ = try git.run(["init", "-q", "--bare", "-b", "main", remote], in: root)
        _ = try git.run(["clone", "-q", remote, work], in: root)
        let id = ["-c", "user.name=t", "-c", "user.email=t@t"]
        _ = try git.run(id + ["commit", "-q", "--allow-empty", "-m", "init"], in: work)
        _ = try git.run(["push", "-q", "origin", "HEAD:main"], in: work)
        _ = try git.run(["checkout", "-q", "-b", "feat/mr-branch"], in: work)
        _ = try git.run(id + ["commit", "-q", "--allow-empty", "-m", "mr"], in: work)
        _ = try git.run(["push", "-q", "origin", "feat/mr-branch"], in: work)
        _ = try git.run(["checkout", "-q", "main"], in: work)
        _ = try git.run(["branch", "-D", "feat/mr-branch"], in: work)
        return work
    }

    @Test func testCheckoutCreatesALocalBranchTrackingOrigin() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(path == repo + "/.worktrees/review-mr-branch")
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) == "feat/mr-branch")
        #expect(try git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: path) == "origin/feat/mr-branch")
        // Locked like a task's worktree, so `git worktree prune` cannot take it.
        #expect(try git.run(["worktree", "list", "--porcelain"], in: repo).contains("locked"))
    }

    /// A `--single-branch` clone's `remote.origin.fetch` covers only its own branch, so `git fetch
    /// origin <branch>` brings the commits but leaves `refs/remotes/origin/<branch>` unwritten.
    /// Without that ref, a branch origin has reads as one it lacks, and a base is a stale one.
    private func singleBranchCloneOfRepoWithAnotherBranch() throws -> (clone: String, remote: String) {
        let repo = try repoWithRemoteOnlyBranch()
        let remote = (try git.run(["remote", "get-url", "origin"], in: repo))
        let root = (repo as NSString).deletingLastPathComponent
        let clone = root + "/single"
        _ = try git.run(["clone", "-q", "--single-branch", "-b", "main", remote, clone], in: root)
        #expect(try git.run(["config", "--get-all", "remote.origin.fetch"], in: clone) == "+refs/heads/main:refs/remotes/origin/main")
        return (clone, remote)
    }

    @Test func aReviewOfABranchOnlyOriginHasWorksInASingleBranchClone() throws {
        let (clone, _) = try singleBranchCloneOfRepoWithAnotherBranch()
        let path = try Repository(clone, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) == "feat/mr-branch")
        // `--track` refuses a tracking ref the clone's fetch config does not cover, so the review's
        // push target is written directly.
        #expect(try git.run(["config", "branch.feat/mr-branch.remote"], in: clone) == "origin")
        #expect(try git.run(["config", "branch.feat/mr-branch.merge"], in: clone) == "refs/heads/feat/mr-branch")
    }

    @Test func aTaskCanStartFromABranchOnlyOriginHasInASingleBranchClone() throws {
        let (clone, remote) = try singleBranchCloneOfRepoWithAnotherBranch()
        let path = try Repository(clone, git: git).addTaskWorktree(slug: "task", branch: "feat/task", base: "feat/mr-branch")
        #expect(try git.run(["rev-parse", "HEAD"], in: path) == (try git.run(["rev-parse", "feat/mr-branch"], in: remote)))
    }

    /// Git lets a branch live in one worktree. A branch that is an AiTerm task's never gets here —
    /// its review opens in the task — so whatever still has it is refused with where it is.
    @Test func testCheckoutRefusesABranchCheckedOutElsewhereAndCreatesNothing() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let elsewhere = URL(fileURLWithPath: repo).deletingLastPathComponent().path + "/elsewhere"
        _ = try git.run(["worktree", "add", "-q", elsewhere, "feat/mr-branch"], in: repo)
        #expect(throws: WorktreeError.branchCheckedOut("feat/mr-branch", at: elsewhere)) {
            try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        }
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/review-mr-branch"))
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: elsewhere) == "feat/mr-branch", "the checkout is untouched")
    }

    /// The project's own folder is the person's, so it is refused like any other checkout — but
    /// with the default branch it could be switched to, and whether it has changes that forbid it.
    @Test func aBranchCheckedOutInTheProjectFolderIsRefusedWithTheBranchToSwitchTo() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try git.run(["checkout", "-q", "feat/mr-branch"], in: repo)
        #expect(throws: WorktreeError.branchInProjectFolder("feat/mr-branch", at: repo, switchTo: "main", hasChanges: false)) {
            try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        }
        try "draft\n".write(toFile: repo + "/notes.txt", atomically: true, encoding: .utf8)
        #expect(throws: WorktreeError.branchInProjectFolder("feat/mr-branch", at: repo, switchTo: "main", hasChanges: true)) {
            try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        }
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/review-mr-branch"))
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) == "feat/mr-branch", "the folder is untouched")
    }

    /// The default branch itself has nothing to switch to: it is refused as any checkout is.
    @Test func theDefaultBranchCheckedOutInTheProjectFolderOffersNoSwitch() throws {
        let repo = try repoWithRemoteOnlyBranch()
        #expect(throws: WorktreeError.branchCheckedOut("main", at: repo)) {
            try Repository(repo, git: git).addReviewWorktree(slug: "review-main", branch: "main")
        }
    }

    /// The footer's Switch: the folder moves to the default branch, the reviewed branch keeps its
    /// commits, and the review can then have it.
    @Test func switchingTheProjectFolderFreesTheBranchForAReview() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try git.run(["checkout", "-q", "feat/mr-branch"], in: repo)
        let tip = try sha("feat/mr-branch", in: repo)
        try Repository(repo, git: git).switchProjectFolder(off: "feat/mr-branch", to: "main")
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) == "main")
        #expect(try sha("feat/mr-branch", in: repo) == tip)
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) == "feat/mr-branch")
    }

    /// Changes made since the sheet offered the switch are not carried to the other branch: the
    /// switch is refused again, with them, and the folder stays where it was.
    @Test func switchingAProjectFolderWithChangesIsRefusedAndMovesNothing() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try git.run(["checkout", "-q", "feat/mr-branch"], in: repo)
        try "draft\n".write(toFile: repo + "/notes.txt", atomically: true, encoding: .utf8)
        #expect(throws: WorktreeError.branchInProjectFolder("feat/mr-branch", at: repo, switchTo: "main", hasChanges: true)) {
            try Repository(repo, git: git).switchProjectFolder(off: "feat/mr-branch", to: "main")
        }
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) == "feat/mr-branch")
        #expect(FileManager.default.fileExists(atPath: repo + "/notes.txt"))
    }

    /// The folder is named by its own name, and what the switch would do — or why it can't — said.
    @Test func aBranchInTheProjectFolderSaysWhatSwitchingWouldDo() {
        let folder = "/Users/sam/Sites/acme-storefront"
        #expect(WorktreeError.branchInProjectFolder("shop-412", at: folder, switchTo: "main", hasChanges: false).errorDescription
                == "“shop-412” is checked out in acme-storefront itself. Switch that folder to main, and the review gets a worktree of its own.")
        #expect(WorktreeError.branchInProjectFolder("shop-412", at: folder, switchTo: "main", hasChanges: true).errorDescription
                == "“shop-412” is checked out in acme-storefront, with uncommitted changes. Commit or stash them there, then review it.")
    }

    /// A folder someone already moved off the branch has nothing left to switch.
    @Test func switchingAProjectFolderThatLeftTheBranchDoesNothing() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try git.run(["checkout", "-q", "-b", "feat/elsewhere"], in: repo)
        try Repository(repo, git: git).switchProjectFolder(off: "feat/mr-branch", to: "main")
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) == "feat/elsewhere")
    }

    /// The bare repository `repoWithRemoteOnlyBranch` made as the clone's origin.
    private func origin(of repo: String) -> String { URL(fileURLWithPath: repo).deletingLastPathComponent().path + "/remote.git" }

    /// A second clone of the same origin: someone else, whose pushes this one has not fetched.
    private func clone(of repo: String) throws -> String {
        let other = URL(fileURLWithPath: repo).deletingLastPathComponent().path + "/other"
        _ = try git.run(["clone", "-q", origin(of: repo), other], in: URL(fileURLWithPath: repo).deletingLastPathComponent().path)
        return other
    }

    private func sha(_ ref: String, in dir: String) throws -> String { try git.run(["rev-parse", ref], in: dir) }
    private func commit(_ message: String, in dir: String) throws {
        _ = try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", message], in: dir)
    }
    private func hasLocalBranch(_ branch: String, in repo: String) throws -> Bool {
        try git.run(["for-each-ref", "--format=%(refname)", "refs/heads/" + branch], in: repo).isEmpty == false
    }

    /// Pushes one more commit to `feat/mr-branch` from a second clone, the way the merge request's
    /// author would, and returns it. `repo`'s own refs know nothing about it until a fetch.
    private func pushNewCommitToMRBranch(of repo: String) throws -> String {
        let other = URL(fileURLWithPath: repo).deletingLastPathComponent().path + "/other"
        _ = try git.run(["clone", "-q", "-b", "feat/mr-branch", repo + "/../remote.git", other], in: repo)
        try commit("later", in: other)
        _ = try git.run(["push", "-q", "origin", "feat/mr-branch"], in: other)
        return try sha("HEAD", in: other)
    }

    /// A local branch is whatever was last pulled, and the fetch never moves it. Behind origin, it
    /// is fast-forwarded, so the review starts from what the author pushed.
    @Test func testCheckoutFastForwardsAStaleLocalBranch() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try git.run(["branch", "-q", "--track", "feat/mr-branch", "origin/feat/mr-branch"], in: repo)
        let fresh = try pushNewCommitToMRBranch(of: repo)
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) == "feat/mr-branch")
        #expect(try sha("HEAD", in: path) == fresh)
    }

    /// Ahead of origin is not stale: those are unpushed commits, an earlier review's fixes say.
    @Test func testCheckoutKeepsALocalBranchThatIsAhead() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try git.run(["branch", "-q", "--track", "feat/mr-branch", "origin/feat/mr-branch"], in: repo)
        _ = try git.run(["checkout", "-q", "feat/mr-branch"], in: repo)
        try commit("my fix", in: repo)
        let mine = try sha("HEAD", in: repo)
        _ = try git.run(["checkout", "-q", "main"], in: repo)
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(try sha("HEAD", in: path) == mine)
    }

    /// Diverged, neither side can move without losing the other's commits: that is for a person.
    @Test func testCheckoutRefusesADivergedLocalBranch() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try git.run(["branch", "-q", "--track", "feat/mr-branch", "origin/feat/mr-branch"], in: repo)
        _ = try git.run(["checkout", "-q", "feat/mr-branch"], in: repo)
        try commit("mine", in: repo)
        let mine = try sha("HEAD", in: repo)
        _ = try git.run(["checkout", "-q", "main"], in: repo)
        _ = try pushNewCommitToMRBranch(of: repo)
        #expect(throws: WorktreeError.branchDiverged("feat/mr-branch", local: 1, remote: 1)) {
            try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        }
        #expect(try sha("feat/mr-branch", in: repo) == mine)
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/review-mr-branch"))
    }

    /// The footer's Rebase: the local commits replayed on origin's, in a checkout of its own since
    /// the branch is checked out nowhere, and the review then takes the branch as it is ahead.
    @Test func rebasingADivergedReviewBranchPutsItsCommitsOnOrigins() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try git.run(["branch", "-q", "--track", "feat/mr-branch", "origin/feat/mr-branch"], in: repo)
        _ = try git.run(["checkout", "-q", "feat/mr-branch"], in: repo)
        try commit("mine", in: repo)
        _ = try git.run(["checkout", "-q", "main"], in: repo)
        let theirs = try pushNewCommitToMRBranch(of: repo)
        #expect(try Repository(repo, git: git).rebaseOntoOrigin("feat/mr-branch") == BranchRebase(branch: "feat/mr-branch", ahead: 1))
        #expect(try sha("feat/mr-branch~1", in: repo) == theirs, "origin's commits are under the local one")
        #expect(try git.run(["log", "-1", "--format=%s", "feat/mr-branch"], in: repo) == "mine")
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) == "feat/mr-branch")
    }

    /// A git that could not say whether one side contains the other — it timed
    /// out — has not said the branch diverged. The review fails with git's reason.
    @Test func aReviewWhoseBranchGitCannotCompareFailsWithGitsReason() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try git.run(["branch", "-q", "--track", "feat/mr-branch", "origin/feat/mr-branch"], in: repo)
        _ = try pushNewCommitToMRBranch(of: repo)
        #expect { try Repository(repo, git: TimingOutGitRunner(["merge-base"])).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch") }
            throws: { ($0 as? GitError)?.timedOut == true }
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/review-mr-branch"))
    }

    /// Nor has one that could not say whether there is an origin said there is none: a branch only
    /// origin has was refused as being nowhere, and a task started from a base it never fetched.
    @Test func aWorktreeInARepositoryGitCannotAskForItsOriginFailsWithGitsReason() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let timingOut = TimingOutGitRunner(["remote", "get-url"])
        #expect { try Repository(repo, git: timingOut).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch") }
            throws: { ($0 as? GitError)?.timedOut == true }
        #expect { try Repository(repo, git: timingOut).addTaskWorktree(slug: "a-task", branch: "feat/a-task", base: "main") }
            throws: { ($0 as? GitError)?.timedOut == true }
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/a-task"))
    }

    /// Nor has one that could not say whether origin has the base said it has not: the task
    /// started from the local base, which can be far behind origin's, rather than fail.
    @Test func aTaskWhoseBaseGitCannotLookUpOnOriginFailsWithGitsReason() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let timingOut = TimingOutGitRunner(["rev-parse", "--verify"])
        #expect { try Repository(repo, git: timingOut).addTaskWorktree(slug: "a-task", branch: "feat/a-task", base: "main") }
            throws: { ($0 as? GitError)?.timedOut == true }
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/a-task"))
    }

    /// Neither local nor on origin — a fork's branch, say — is nothing that could be pushed to.
    @Test func testCheckoutRefusesABranchThatIsNowhere() throws {
        let repo = try repoWithRemoteOnlyBranch()
        #expect(throws: WorktreeError.branchNotOnOrigin("feat/from-a-fork")) {
            try Repository(repo, git: git).addReviewWorktree(slug: "review-from-a-fork", branch: "feat/from-a-fork")
        }
    }

    /// Without an origin the local branch is all there is.
    @Test func testCheckoutWithoutOriginChecksOutTheLocalBranch() throws {
        _ = try git.run(["branch", "feat/local"], in: repo)
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-local", branch: "feat/local")
        #expect(try git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) == "feat/local")
    }

    // -- releasing a review's branch ------------------------------------------------

    /// The branch a review checked out, once its worktree is gone: deleted when every commit on it
    /// is on origin, kept — and why — when some are not. The remote branch is never touched.
    @Test func testReleasingAReviewBranchDeletesItOnlyWhenEverythingIsPushed() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try commit("fix one", in: path)
        try commit("fix two", in: path)
        try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: nil, force: false)
        #expect(Repository(repo, git: git).releaseReviewBranch("feat/mr-branch", target: "main")
                == .kept(.unpushed(commits: 2)))
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))

        _ = try git.run(["push", "-q", "origin", "feat/mr-branch"], in: repo)
        #expect(Repository(repo, git: git).releaseReviewBranch("feat/mr-branch", target: "main") == .deleted)
        #expect(try !hasLocalBranch("feat/mr-branch", in: repo))
        #expect(try git.run(["ls-remote", "--heads", "origin", "feat/mr-branch"], in: repo).isEmpty == false, "origin keeps it")
        #expect(Repository(repo, git: git).releaseReviewBranch("feat/mr-branch", target: "main") == .untouched)
    }

    /// GitLab deletes a merged branch on origin; merged into the target, the local copy holds
    /// nothing that is not there. Not merged, it is the only copy left.
    @Test func testReleasingAReviewBranchWhoseRemoteIsGone() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: nil, force: false)
        _ = try git.run(["push", "-q", "origin", "--delete", "feat/mr-branch"], in: repo)
        #expect(Repository(repo, git: git).releaseReviewBranch("feat/mr-branch", target: "main")
                == .kept(.unmerged(target: "main")))

        _ = try git.run(["push", "-q", "origin", "feat/mr-branch:main"], in: repo)
        _ = try git.run(["fetch", "-q", "origin"], in: repo)
        #expect(Repository(repo, git: git).releaseReviewBranch("feat/mr-branch", target: "main") == .deleted)
    }

    /// Origin is asked, not its cached tracking ref. Deleted on origin by someone else — this clone
    /// has not fetched since, so `origin/feat/mr-branch` still points at the review's commit — the
    /// local branch is the only copy of work never merged, and is kept.
    @Test func testAReviewBranchDeletedOnOriginBehindAStaleTrackingRefIsKept() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: nil, force: false)
        _ = try git.run(["branch", "-D", "feat/mr-branch"], in: origin(of: repo))
        #expect(try git.run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/feat/mr-branch"], in: repo).isEmpty == false,
                "the tracking ref is stale, which is the point")

        #expect(Repository(repo, git: git).releaseReviewBranch("feat/mr-branch", target: "main")
                == .kept(.unmerged(target: "main")))
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// Force-pushed on origin to something else: the stale tracking ref still holds the review's
    /// commit, but origin's branch no longer does.
    @Test func testAReviewBranchForcePushedOnOriginIsKept() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: nil, force: false)
        let other = try clone(of: repo)
        _ = try git.run(["checkout", "-q", "-B", "feat/mr-branch", "origin/main"], in: other)
        try commit("rewritten", in: other)
        _ = try git.run(["push", "-q", "--force", "origin", "feat/mr-branch"], in: other)

        #expect(Repository(repo, git: git).releaseReviewBranch("feat/mr-branch", target: "main")
                == .kept(.unpushed(commits: 1)))
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// Origin cannot be asked — offline, credentials refused. That confirms nothing, so the branch
    /// stays, whatever the tracking ref claims.
    @Test func testAReviewBranchIsKeptWhenOriginCannotBeChecked() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: nil, force: false)
        _ = try git.run(["remote", "set-url", "origin", repo + "/../gone.git"], in: repo)

        guard case .kept(.originUnreachable(let why)) = Repository(repo, git: git).releaseReviewBranch("feat/mr-branch", target: "main") else {
            Issue.record("expected the branch to be kept as origin could not be asked"); return
        }
        #expect(!why.isEmpty, "with git's reason")
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// Merged on origin and its branch deleted there, by someone else, since this clone last
    /// fetched: origin's target as it is now holds every commit, so the local copy goes.
    @Test func testAReviewBranchMergedOnOriginSinceTheLastFetchIsDeleted() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: nil, force: false)
        let other = try clone(of: repo)
        _ = try git.run(["push", "-q", "origin", "origin/feat/mr-branch:main"], in: other)
        _ = try git.run(["push", "-q", "origin", "--delete", "feat/mr-branch"], in: other)

        #expect(Repository(repo, git: git).releaseReviewBranch("feat/mr-branch", target: "main") == .deleted)
        #expect(try !hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// A branch another worktree has checked out is someone's checkout: never deleted, whatever
    /// origin says.
    @Test func testAReviewBranchCheckedOutElsewhereIsKept() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        #expect(Repository(repo, git: git).releaseReviewBranch("feat/mr-branch", target: "main") == .kept(.checkedOut(at: path)))
    }

    /// A git that could not say whether the branch's commits are on origin's — or
    /// whether there is an origin — has not said they are not: the branch is kept, and the reason
    /// is git's, not "0 commits not on origin" or nothing at all.
    @Test func aReviewBranchGitCannotJudgeIsKeptWithGitsReason() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: nil, force: false)
        for timingOut in [TimingOutGitRunner(["merge-base"]), TimingOutGitRunner(["remote", "get-url"])] {
            let release = Repository(repo, git: timingOut).releaseReviewBranch("feat/mr-branch", target: "main")
            guard case .kept(.unchecked(let why)) = release else {
                Issue.record("expected the branch kept as git could not be asked, got \(release)"); continue
            }
            #expect(why.contains("timed out"))
        }
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// Kept for commits origin lacks that git could not count: kept all the same, with no number,
    /// rather than "0 commits not on origin".
    @Test func aReviewBranchWhoseUnpushedCommitsGitCannotCountIsKeptWithoutANumber() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try commit("fix", in: path)
        try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: nil, force: false)
        let release = Repository(repo, git: TimingOutGitRunner(["rev-list"])).releaseReviewBranch("feat/mr-branch", target: "main")
        guard case .kept(.unpushed(let commits)) = release else { Issue.record("expected the branch kept, got \(release)"); return }
        #expect(commits == nil)
        #expect(try hasLocalBranch("feat/mr-branch", in: repo))
    }

    /// No origin, nothing to judge the branch against: it is left exactly as it was.
    @Test func testReleasingAReviewBranchWithoutOriginLeavesIt() throws {
        _ = try git.run(["branch", "feat/local"], in: repo)
        #expect(Repository(repo, git: git).releaseReviewBranch("feat/local", target: "main") == .untouched)
        #expect(try hasLocalBranch("feat/local", in: repo))
    }

    /// The difference from `create` that matters most: a review's branch belongs to someone else's
    /// merge request, so no failure path may delete it.
    @Test func testCheckoutNeverDeletesTheBranchItCheckedOut() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try Repository(repo, git: git).addReviewWorktree(slug: "review-one", branch: "feat/mr-branch")
        try Repository(repo, git: git).removeWorktree(at: repo + "/.worktrees/review-one", deleteBranch: nil, force: true)
        let refs = try git.run(["for-each-ref", "--format=%(refname)", "refs/heads/feat/mr-branch"], in: repo)
        #expect(refs.contains("refs/heads/feat/mr-branch"))
    }

    /// The lock reason is the only thing on disk that tells a review's worktree from a task's, and
    /// `existing` is what the project import reads. Dropping it there is how a re-imported review
    /// becomes a task whose branch the app will offer to delete.
    @Test func testExistingReportsTheLockReasonThatTellsAReviewFromATask() throws {
        let repo = try repoWithRemoteOnlyBranch()
        _ = try Repository(repo, git: git).addTaskWorktree(slug: "a-task", branch: "feat/a-task", base: "main")
        _ = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")

        let found = try Repository(repo, git: git).managedWorktrees()
        #expect(found.count == 2)
        let reasons = Dictionary(uniqueKeysWithValues: found.map { ($0.branch, $0.lockReason) })
        #expect(reasons["feat/a-task"] == Worktree.taskLockReason)
        #expect(reasons["feat/mr-branch"] == Worktree.reviewLockReason)
    }

    /// git prints a bare `locked` line for a lock taken without a reason, and an unlocked worktree
    /// prints none at all. Neither may be read as a review.
    @Test func testExistingDistinguishesNoLockFromALockWithoutAReason() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let bare = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        _ = try git.run(["worktree", "unlock", bare], in: repo)
        var found = try Repository(repo, git: git).managedWorktrees()
        #expect(found.map(\.lockReason) == [String?.none])

        _ = try git.run(["worktree", "lock", bare], in: repo)
        found = try Repository(repo, git: git).managedWorktrees()
        #expect(found.map(\.lockReason) == [""])
        #expect(Repository(repo, git: git).lockReason(of: bare) == "")
    }

    /// A refused removal relocks what it just unlocked. It used to relock every worktree as
    /// `aiterm task`, which silently rewrote a review's marker and re-opened the hole above.
    @Test func testARefusedRemovalRestoresAReviewsOwnLockReason() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let path = try Repository(repo, git: git).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        // An untracked file makes `git worktree remove` (without --force) refuse.
        try "scratch".write(toFile: path + "/untracked.txt", atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try Repository(repo, git: git).removeWorktree(at: path, deleteBranch: nil, force: false)
        }
        #expect(FileManager.default.fileExists(atPath: path), "the refusal must leave the worktree in place")
        #expect(Repository(repo, git: git).lockReason(of: path) == Worktree.reviewLockReason)
        #expect(try Repository(repo, git: git).managedWorktrees().map(\.lockReason) == [Worktree.reviewLockReason])
    }

    /// The lock is written by `worktree add` itself (`--lock --reason`): there is no second command
    /// that can fail or time out with a finished checkout on disk, and no window in which the
    /// worktree exists unlocked for a `git worktree prune` to take.
    @Test func aWorktreeIsLockedByTheCommandThatCreatesIt() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let recording = RecordingGitRunner(forwardingTo: .hermetic())
        let review = try Repository(repo, git: recording).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        let task = try Repository(repo, git: recording).addTaskWorktree(slug: "task", branch: "feat/task", base: "main")

        #expect(!recording.calls.contains { $0.args.starts(with: ["worktree", "lock"]) }, "no separate lock step")
        let adds = recording.calls.filter { $0.args.starts(with: ["worktree", "add"]) }.map(\.args)
        #expect(adds.count == 2)
        #expect(adds.allSatisfy { $0.contains("--lock") })
        #expect(Repository(repo, git: git).lockReason(of: review) == Worktree.reviewLockReason)
        #expect(Repository(repo, git: git).lockReason(of: task) == Worktree.taskLockReason)
    }

    /// Every call that talks to origin gets the remote deadline and the stall guard; a checkout —
    /// hooks, filters, a `node_modules` to delete — gets the long one, and so does the unlock and
    /// relock around a removal; the rest are local queries.
    @Test func eachGitCallGetsTheDeadlineForWhatItDoes() throws {
        let repo = try repoWithRemoteOnlyBranch()
        let recording = RecordingGitRunner(forwardingTo: .hermetic())
        let path = try Repository(repo, git: recording).addReviewWorktree(slug: "review-mr-branch", branch: "feat/mr-branch")
        try Repository(repo, git: recording).removeWorktree(at: path, deleteBranch: nil, force: false)
        _ = Repository(repo, git: recording).releaseReviewBranch("feat/mr-branch", target: "main")
        _ = try Repository(repo, git: recording).addTaskWorktree(slug: "task", branch: "feat/task", base: "main")

        let options = ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=10"]
        for call in recording.calls {
            let remote = call.args.starts(with: options)
            let command = remote ? Array(call.args.dropFirst(options.count)) : call.args
            switch (command[0], command.dropFirst().first) {
            case ("fetch", _), ("ls-remote", _):
                #expect(remote && call.timeout == GitRunner.remoteTimeout, "\(call.args)")
            case ("worktree", "add"), ("worktree", "remove"), ("worktree", "lock"), ("worktree", "unlock"):
                #expect(!remote && call.timeout == GitRunner.checkoutTimeout, "\(call.args)")
            default:
                #expect(!remote && call.timeout == GitRunner.localTimeout, "\(call.args)")
            }
        }
        let asked = Set(recording.calls.map { $0.args.starts(with: options) ? $0.args[options.count] : $0.args[0] })
        #expect(asked.isSuperset(of: ["fetch", "ls-remote", "worktree"]))
    }
}

/// `git worktree remove` as it goes with a watcher still running in the checkout: git deletes it
/// and drops its record, the watcher writes its build output back, and git reports the folder it
/// could not delete.
private struct RefillingGitRunner: GitRunning {
    let inner: any GitRunning = GitRunner.hermetic()
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        guard args.starts(with: ["worktree", "remove"]), let path = args.last else {
            return try inner.run(args, in: dir, timeout: timeout, environment: environment)
        }
        try inner.run(args, in: dir, timeout: timeout, environment: environment)
        try FileManager.default.createDirectory(atPath: path + "/app/.nuxt", withIntermediateDirectories: true)
        try "export {}\n".write(toFile: path + "/app/.nuxt/nuxt.d.ts", atomically: true, encoding: .utf8)
        throw GitError(args: args, code: 255, stderr: "error: failed to delete '\(path)': Directory not empty")
    }
}
