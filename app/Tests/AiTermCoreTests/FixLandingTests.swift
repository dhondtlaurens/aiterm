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

    @Test func aFailedMoveWithNoEarlierBackupLeavesNoBackup() throws {
        let clone = try resolvedClone(); defer { clone.remove() }
        let racing = MovingGitRunner(inner: git, branch: "refs/heads/feat/x", repo: world.repo)
        #expect(throws: FixRefusal.branchMovedMeanwhile("feat/x")) { try Repository(world.repo, git: racing).landFix(from: clone) }
        #expect(try git.run(["for-each-ref", "refs/aiterm"], in: world.repo).isEmpty)
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

    // MARK: Hooks

    /// A repo whose hooks write a marker; `proves` runs a command that fires both, to show they work.
    private func installHooks() throws -> (markers: String, proves: () throws -> Void) {
        let hooks = world.root + "/hooks", markers = world.root + "/markers"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: markers, withIntermediateDirectories: true)
        for name in ["post-merge", "reference-transaction"] {
            try "#!/bin/sh\necho ran >> '\(markers)/\(name)'\n".write(toFile: hooks + "/" + name, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks + "/" + name)
        }
        try git.run(["config", "core.hooksPath", hooks], in: world.repo)
        return (markers, { [git, world] in
            try git.run(["update-ref", "refs/aiterm/proof", "HEAD"], in: world.repo)
            try git.run(["checkout", "-q", "main"], in: world.repo)
            try git.run(["merge", "--ff-only", "-q", "feat/x"], in: world.repo)
        })
    }

    @Test(arguments: [true, false]) func noHookRunsWhileAFixLands(fastForward: Bool) throws {
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        let clone = try FixClone.make(for: request(branch: "feat/x"), git: git, root: world.root); defer { clone.remove() }
        if fastForward {
            try git.run(["rebase", "--abort"], in: clone.path)
            try world.commit("fix", file: "fix.txt", contents: "x\n", in: clone.path)
        } else {
            try "topic=both\n".write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
            try git.run(["add", "config.ts"], in: clone.path)
            try git.run(["-c", "core.editor=true", "rebase", "--continue"], in: clone.path)
        }
        let hooks = try installHooks()
        _ = try Repository(world.repo, git: git).landFix(from: clone)
        #expect(try world.sha("HEAD", in: world.repo) == clone.tip("feat/x"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: hooks.markers).isEmpty, "no hook ran")
        try hooks.proves()
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: hooks.markers)) == ["post-merge", "reference-transaction"], "the hooks do run when git is not told otherwise")
    }

    @Test func noHookRunsWhereTheBranchIsCheckedOutNowhere() throws {
        let clone = try resolvedClone(); defer { clone.remove() }
        let hooks = try installHooks()
        _ = try Repository(world.repo, git: git).landFix(from: clone)
        #expect(try FileManager.default.contentsOfDirectory(atPath: hooks.markers).isEmpty)
    }

    // MARK: A move that fails

    @Test func aTimeoutAfterTheBranchMovedKeepsTheBackupAndLands() throws {
        let old = try world.sha("feat/x", in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        let new = try clone.tip("feat/x")
        let flaky = TimingOutAfterGit(inner: git, command: "update-ref", ref: "refs/heads/feat/x") { git, dir in
            try git.run(["update-ref", "refs/heads/feat/x", new], in: dir)
        }
        let landing = try Repository(world.repo, git: flaky).landFix(from: clone)
        #expect(flaky.fired)
        #expect(landing.new == (try clone.tip("feat/x")))
        #expect(try world.sha("refs/aiterm/backup/feat/x", in: world.repo) == old)
    }

    @Test func aTimeoutThatMovedNothingPutsTheEarlierBackupBack() throws {
        let earlier = try world.sha("main", in: world.repo)
        try git.run(["update-ref", "refs/aiterm/backup/feat/x", earlier], in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        let flaky = TimingOutAfterGit(inner: git, command: "update-ref", ref: "refs/heads/feat/x") { _, _ in }
        #expect(throws: FixRefusal.self) { try Repository(world.repo, git: flaky).landFix(from: clone) }
        #expect(flaky.fired)
        #expect(try world.sha("refs/aiterm/backup/feat/x", in: world.repo) == earlier)
    }

    @Test func aTimeoutAfterSomeoneElseMovedTheBranchKeepsTheBackup() throws {
        let old = try world.sha("feat/x", in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        let elsewhere = try world.sha("main", in: world.repo)
        let flaky = TimingOutAfterGit(inner: git, command: "update-ref", ref: "refs/heads/feat/x") { git, dir in
            try git.run(["update-ref", "refs/heads/feat/x", elsewhere], in: dir)
        }
        #expect(throws: FixRefusal.landingFailed("feat/x", "git timed out and the branch has moved, so it was left alone. Its old tip is kept as aiterm/backup/feat/x.")) {
            try Repository(world.repo, git: flaky).landFix(from: clone)
        }
        #expect(try world.sha("refs/aiterm/backup/feat/x", in: world.repo) == old)
    }

    // MARK: Files git ignores, and branches mid-operation

    private func ignoreAndWriteEnv() throws {
        try ".env\n".write(toFile: world.repo + "/.git/info/exclude", atomically: true, encoding: .utf8)
        try "mine\n".write(toFile: world.repo + "/.env", atomically: true, encoding: .utf8)
    }

    @Test(arguments: [true, false]) func anIgnoredFileTheFixTracksIsKeptAndTheLandingRefused(fastForward: Bool) throws {
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        let clone = try FixClone.make(for: request(branch: "feat/x"), git: git, root: world.root); defer { clone.remove() }
        if fastForward {
            try git.run(["rebase", "--abort"], in: clone.path)
        } else {
            try "topic=both\n".write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
            try git.run(["add", "config.ts"], in: clone.path)
            try git.run(["-c", "core.editor=true", "rebase", "--continue"], in: clone.path)
        }
        try "theirs\n".write(toFile: clone.path + "/.env", atomically: true, encoding: .utf8)
        try git.run(["add", "-f", ".env"], in: clone.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "env"], in: clone.path)
        try ignoreAndWriteEnv()
        let old = try world.sha("HEAD", in: world.repo)
        #expect(throws: FixRefusal.wouldOverwriteIgnored([".env"])) { try Repository(world.repo, git: git).landFix(from: clone) }
        #expect(try String(contentsOfFile: world.repo + "/.env", encoding: .utf8) == "mine\n")
        #expect(try world.sha("HEAD", in: world.repo) == old)
        #expect(try git.run(["for-each-ref", "refs/aiterm"], in: world.repo).isEmpty)
    }

    /// The ignored file `a` and a fix that adds `a/b`: `reset --keep` would swap the file for a folder.
    @Test(arguments: [true, false]) func anIgnoredFileWhereTheFixAddsAFolderIsKeptAndTheLandingRefused(fastForward: Bool) throws {
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        let clone = try FixClone.make(for: request(branch: "feat/x"), git: git, root: world.root); defer { clone.remove() }
        if fastForward {
            try git.run(["rebase", "--abort"], in: clone.path)
        } else {
            try "topic=both\n".write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
            try git.run(["add", "config.ts"], in: clone.path)
            try git.run(["-c", "core.editor=true", "rebase", "--continue"], in: clone.path)
        }
        try FileManager.default.createDirectory(atPath: clone.path + "/a", withIntermediateDirectories: true)
        try "new\n".write(toFile: clone.path + "/a/b", atomically: true, encoding: .utf8)
        try git.run(["add", "a/b"], in: clone.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "a/b"], in: clone.path)
        try "a\n".write(toFile: world.repo + "/.git/info/exclude", atomically: true, encoding: .utf8)
        try "mine\n".write(toFile: world.repo + "/a", atomically: true, encoding: .utf8)
        let old = try world.sha("HEAD", in: world.repo)
        #expect(throws: FixRefusal.wouldOverwriteIgnored(["a"])) { try Repository(world.repo, git: git).landFix(from: clone) }
        #expect(try String(contentsOfFile: world.repo + "/a", encoding: .utf8) == "mine\n")
        #expect(try world.sha("HEAD", in: world.repo) == old)
        #expect(try git.run(["for-each-ref", "refs/aiterm"], in: world.repo).isEmpty)
    }

    /// The runner trims what git prints; a name that starts with a space must survive it.
    @Test(arguments: [true, false]) func aNameThatStartsWithASpaceIsStillFound(fastForward: Bool) throws {
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        let clone = try FixClone.make(for: request(branch: "feat/x"), git: git, root: world.root); defer { clone.remove() }
        if fastForward { try git.run(["rebase", "--abort"], in: clone.path) }
        else {
            try "topic=both\n".write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
            try git.run(["add", "config.ts"], in: clone.path)
            try git.run(["-c", "core.editor=true", "rebase", "--continue"], in: clone.path)
        }
        try "theirs\n".write(toFile: clone.path + "/ lead.env", atomically: true, encoding: .utf8)
        try git.run(["add", "-f", " lead.env"], in: clone.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "lead"], in: clone.path)
        try " lead.env\n".write(toFile: world.repo + "/.git/info/exclude", atomically: true, encoding: .utf8)
        try "mine\n".write(toFile: world.repo + "/ lead.env", atomically: true, encoding: .utf8)
        #expect(try git.run(["status", "--porcelain", "--ignored"], in: world.repo).contains("lead.env"), "the fixture: git ignores it")
        #expect(throws: FixRefusal.wouldOverwriteIgnored([" lead.env"])) { try Repository(world.repo, git: git).landFix(from: clone) }
        #expect(try String(contentsOfFile: world.repo + "/ lead.env", encoding: .utf8) == "mine\n")
    }

    /// The backup's own write times out after git wrote it.
    @Test(arguments: [true, false]) func aBackupWriteThatTimesOutLeavesTheEarlierBackupAsItWas(hasEarlier: Bool) throws {
        let earlier = try world.sha("main", in: world.repo)
        if hasEarlier { try git.run(["update-ref", "refs/aiterm/backup/feat/x", earlier], in: world.repo) }
        let old = try world.sha("feat/x", in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        let flaky = TimingOutAfterGit(inner: git, command: "update-ref", ref: "refs/aiterm/backup/feat/x", count: 3) { git, dir in
            try git.run(["update-ref", "refs/aiterm/backup/feat/x", old], in: dir)
        }
        #expect(throws: FixRefusal.self) { try Repository(world.repo, git: flaky).landFix(from: clone) }
        #expect(flaky.fired)
        #expect(try git.run(["for-each-ref", "--format=%(objectname)", "refs/aiterm/backup"], in: world.repo) == (hasEarlier ? earlier : ""))
        #expect(try world.sha("feat/x", in: world.repo) == old)
    }

    /// The branch cannot be read after a failed move: nobody knows what ran, so the backup stays.
    @Test func aMoveThatFailsAndCannotBeReReadKeepsTheBackup() throws {
        let old = try world.sha("feat/x", in: world.repo)
        let earlier = try world.sha("main", in: world.repo)
        try git.run(["update-ref", "refs/aiterm/backup/feat/x", earlier], in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        let flaky = TimingOutAfterGit(inner: git, command: "update-ref", ref: "refs/heads/feat/x", unreadableAfterwards: true) { _, _ in }
        #expect(throws: FixRefusal.self) { try Repository(world.repo, git: flaky).landFix(from: clone) }
        #expect(flaky.fired)
        #expect(try world.sha("refs/aiterm/backup/feat/x", in: world.repo) == old)
    }

    @Test func aBranchMidRebaseInALinkedWorktreeIsRefusedAndNotMoved() throws {
        let clone = try resolvedClone(); defer { clone.remove() }
        let linked = world.root + "/linked"
        try git.run(["worktree", "add", "-q", linked, "feat/x"], in: world.repo)
        _ = try? git.run(["rebase", "origin/feat/x"], in: linked)
        #expect(try git.run(["worktree", "list", "--porcelain"], in: world.repo).contains("detached"), "the fixture: git lists it as detached")
        let tip = try world.sha("refs/heads/feat/x", in: world.repo)
        #expect(throws: FixRefusal.branchInOperation("feat/x")) { try Repository(world.repo, git: git).landFix(from: clone) }
        #expect(try world.sha("refs/heads/feat/x", in: world.repo) == tip)
        #expect(try git.run(["for-each-ref", "refs/aiterm"], in: world.repo).isEmpty)
    }

    @Test func aBranchCheckedOutInALinkedWorktreeLandsThereAndKeepsItsUntrackedFiles() throws {
        let linked = world.root + "/linked"
        try git.run(["worktree", "add", "-q", linked, "feat/x"], in: world.repo)
        try "keep me\n".write(toFile: linked + "/untracked.txt", atomically: true, encoding: .utf8)
        let clone = try resolvedClone(); defer { clone.remove() }
        _ = try Repository(world.repo, git: git).landFix(from: clone)
        #expect(try world.sha("HEAD", in: linked) == clone.tip("feat/x"))
        #expect(try String(contentsOfFile: linked + "/config.ts", encoding: .utf8) == "topic=both\n")
        #expect(try String(contentsOfFile: linked + "/untracked.txt", encoding: .utf8) == "keep me\n")
    }

    @Test func aStagedOnlyChangeIsRefused() throws {
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        try "staged\n".write(toFile: world.repo + "/staged.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "staged.txt"], in: world.repo)
        let top = try git.run(["rev-parse", "--show-toplevel"], in: world.repo)
        #expect(throws: FixRefusal.checkoutHasChanges(top)) { try Repository(world.repo, git: git).landFix(from: clone) }
        #expect(try git.run(["for-each-ref", "refs/aiterm"], in: world.repo).isEmpty)
    }

    @Test(arguments: ["sequencer", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"])
    func anOperationInProgressInTheCheckoutIsRefused(state: String) throws {
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        let clone = try resolvedClone(); defer { clone.remove() }
        let path = world.repo + "/.git/" + state
        if state == "sequencer" { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        else { try (try world.sha("main", in: world.repo) + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        let tip = try world.sha("HEAD", in: world.repo)
        #expect(throws: FixRefusal.branchInOperation("feat/x")) { try Repository(world.repo, git: git).landFix(from: clone) }
        #expect(try world.sha("HEAD", in: world.repo) == tip)
        #expect(try git.run(["for-each-ref", "refs/aiterm"], in: world.repo).isEmpty)
    }

    @Test func everyLandingFailureHasItsOwnSentence() {
        #expect(FixRefusal.landingFailed("feat/x", "no space left").errorDescription == "Couldn’t move “feat/x”: no space left")
    }

    @Test func theWorkflowLandsAFixAndReportsItsOldAndNewTips() async throws {
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
        let command = args.starts(with: ["-c", "core.hooksPath=/dev/null"]) ? Array(args.dropFirst(2)) : args
        if command.first == "update-ref", command.count == 4, command[1] == branch, !didMove.withLock({ let was = $0; $0 = true; return was }) {
            let tip = try inner.run(["rev-parse", branch], in: dir)
            let moved = try inner.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit-tree", "-p", tip, "-m", "meanwhile", tip + "^{tree}"], in: dir)
            try inner.run(["update-ref", branch, moved], in: dir)
        }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}

/// Git whose first `command` on `ref` runs `effect` (a move that did or did not happen) and then
/// times out, as git killed at its deadline does.
private final class TimingOutAfterGit: GitRunning {
    private let inner: any GitRunning, command: String, ref: String, count: Int, unreadable: Bool
    private let hit = Mutex(false)
    let effect: @Sendable (any GitRunning, String) throws -> Void
    var fired: Bool { hit.withLock { $0 } }

    init(inner: any GitRunning, command: String, ref: String, count: Int = 4, unreadableAfterwards: Bool = false, effect: @escaping @Sendable (any GitRunning, String) throws -> Void) {
        self.inner = inner; self.command = command; self.ref = ref; self.count = count; self.unreadable = unreadableAfterwards; self.effect = effect
    }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        let cmd = args.starts(with: ["-c", "core.hooksPath=/dev/null"]) ? Array(args.dropFirst(2)) : args
        if unreadable, fired, cmd.contains(ref + "^{commit}") {
            throw GitError(args: args, code: 15, stderr: "git rev-parse timed out after \(timeout) s", timedOut: true)
        }
        if cmd.first == command, cmd.count == count, cmd[1] == ref, !hit.withLock({ let was = $0; $0 = true; return was }) {
            try effect(inner, dir)
            throw GitError(args: args, code: 15, stderr: "git \(command) timed out after \(timeout) s", timedOut: true)
        }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}
