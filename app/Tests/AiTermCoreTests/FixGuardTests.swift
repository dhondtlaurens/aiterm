import Testing
import Foundation
import Synchronization
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) final class FixGuardTests {
    let git = GitRunner.hermetic()
    let world: ConflictWorld
    let clone: FixClone

    init() throws {
        world = try ConflictWorld(git: .hermetic())
        clone = try FixClone.make(for: FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "feat/x",
                                                   recreateRebase: true, retry: .createReview), git: .hermetic(), root: world.root)
        // A second branch in the clone, so “moved another branch” has one to move.
        try git.run(["branch", "-f", "main", "origin/feat/x"], in: clone.path)
    }
    deinit { clone.remove(); world.removeAll() }

    /// The tips as the pipeline reads them before Apply.
    private var before: [String: String] { (try? clone.branchTips()) ?? [:] }

    private func plan(branch: String = "feat/x", drops: [String] = []) -> FixProposal {
        FixProposal(headline: "h", why: "w", steps: ["s"], moves: [branch], drops: drops, verify: nil)
    }
    private func resolve(with contents: String) throws {
        try contents.write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
        try git.run(["add", "config.ts"], in: clone.path)
        try git.run(["-c", "core.editor=true", "rebase", "--continue"], in: clone.path)
    }

    @Test func aRebaseLeftStoppedIsRefused() {
        #expect(throws: FixRefusal.operationInProgress) { try FixGuard.check(clone, proposal: plan(), before: before) }
    }

    @Test func leftoverMarkersAreRefused() throws {
        let start = before
        try resolve(with: "<<<<<<< HEAD\ntopic=theirs\n=======\ntopic=mine\n>>>>>>> mine\n")
        #expect(throws: FixRefusal.conflictMarkers(["config.ts"])) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func aCleanResolutionKeepingTheCommitPasses() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try FixGuard.check(clone, proposal: plan(), before: start)
    }

    /// Spec §7.2: the local commit replaced by origin's without saying so.
    @Test func anUndeclaredDropIsRefused() throws {
        let start = before
        try git.run(["rebase", "--abort"], in: clone.path)
        try git.run(["reset", "-q", "--hard", "origin/feat/x"], in: clone.path)
        let mine = try world.sha("feat/x", in: world.repo)
        #expect(throws: FixRefusal.droppedCommit("feat/x", sha: mine)) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func aDeclaredDropPasses() throws {
        let start = before
        try git.run(["rebase", "--abort"], in: clone.path)
        try git.run(["reset", "-q", "--hard", "origin/feat/x"], in: clone.path)
        try FixGuard.check(clone, proposal: plan(drops: [try world.sha("feat/x", in: world.repo)]), before: start)
    }

    /// By content first: a reworded commit has a new sha and subject but the same patch.
    @Test func aCommitKeptByItsPatchPasses() throws {
        let start = before
        try git.run(["rebase", "--abort"], in: clone.path)
        try git.run(["commit", "-q", "--amend", "-m", "reworded"], in: clone.path)
        try FixGuard.check(clone, proposal: plan(), before: start)
    }

    @Test func movingAnotherBranchIsRefused() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try git.run(["branch", "-f", "main", "HEAD"], in: clone.path)
        #expect(throws: FixRefusal.movedOtherBranch("main")) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func uncommittedChangesAreRefused() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try "extra\n".write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
        #expect(throws: FixRefusal.uncommittedChanges) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    // MARK: the branch that lands

    /// Landing moves refs only, so the branch's own tip is read, wherever HEAD is.
    @Test func markersCommittedOnTheBranchAreRefusedWhereverHeadIs() throws {
        let start = before
        try resolve(with: "<<<<<<< HEAD\ntopic=theirs\n=======\ntopic=mine\n>>>>>>> mine\n")
        try git.run(["checkout", "-q", "main"], in: clone.path)
        #expect(throws: FixRefusal.conflictMarkers(["config.ts"])) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func aCleanBranchPassesWithHeadElsewhere() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try git.run(["checkout", "-q", "main"], in: clone.path)
        try FixGuard.check(clone, proposal: plan(), before: start)
    }

    @Test func aPathWithColonsIsNamedWhole() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try "<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> z\n".write(toFile: clone.path + "/a:b.ts", atomically: true, encoding: .utf8)
        try git.run(["add", "a:b.ts"], in: clone.path)
        try git.run(["commit", "-q", "-m", "more"], in: clone.path)
        #expect(throws: FixRefusal.conflictMarkers(["a:b.ts"])) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func otherStoppedOperationsAreRefused() throws {
        try git.run(["rebase", "--abort"], in: clone.path)
        for state in ["REVERT_HEAD", "BISECT_LOG", "sequencer"] {
            let path = clone.path + "/.git/" + state
            try Data().write(to: URL(fileURLWithPath: path))
            #expect(throws: FixRefusal.operationInProgress) { try FixGuard.check(clone, proposal: plan(), before: before) }
            try FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: markers that are not the agent's

    /// A line origin already had — an RST underline — is `=======` to `diff --check`, but not the fix's doing.
    @Test func aMarkerLookalikeFromOriginIsNotTheFixes() throws {
        let (world, clone) = try second { world in
            try world.commit("docs", file: "doc.rst", contents: "Title\n=======\n", in: world.other)
            try self.git.run(["push", "-q", "origin", "feat/x"], in: world.other)
            try self.git.run(["fetch", "-q", "origin"], in: world.repo)
        }
        defer { clone.remove(); world.removeAll() }
        let start = (try? clone.branchTips()) ?? [:]
        try "topic=both\n".write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
        try git.run(["add", "config.ts"], in: clone.path)
        try git.run(["-c", "core.editor=true", "rebase", "--continue"], in: clone.path)
        try FixGuard.check(clone, proposal: plan(), before: start)
    }

    // MARK: lost commits

    /// A commit of origin's with the lost commit's identity is not a twin: origin has it already.
    @Test func anOriginCommitWithTheSameIdentityDoesNotVouch() throws {
        let (world, clone) = try second { world in
            let date = try self.git.run(["log", "-1", "--format=%at", "feat/x"], in: world.repo) + " +0000"
            try "x\n".write(toFile: world.other + "/other.txt", atomically: true, encoding: .utf8)
            try self.git.run(["add", "other.txt"], in: world.other)
            try self.git.run(["commit", "-q", "-m", "mine"], in: world.other, timeout: GitRunner.localTimeout,
                             environment: ["GIT_AUTHOR_DATE": date])
            try self.git.run(["push", "-q", "origin", "feat/x"], in: world.other)
            try self.git.run(["fetch", "-q", "origin"], in: world.repo)
        }
        defer { clone.remove(); world.removeAll() }
        let start = (try? clone.branchTips()) ?? [:]
        try git.run(["rebase", "--abort"], in: clone.path)
        try git.run(["reset", "-q", "--hard", "origin/feat/x"], in: clone.path)
        let mine = try world.sha("feat/x", in: world.repo)
        #expect(throws: FixRefusal.droppedCommit("feat/x", sha: mine)) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func tooManyLocalOnlyCommitsAreRefused() throws {
        let start = before
        try resolve(with: "topic=both\n")
        #expect(throws: FixRefusal.tooManyCommits("feat/x", count: 1)) { try FixGuard.check(clone, proposal: plan(), before: start, limit: 0) }
        try FixGuard.check(clone, proposal: plan(), before: start, limit: 1)
    }

    /// With no origin the history is not the count: only what the fix left out of the new tip is.
    @Test func aLocalOnlyBranchWithALongHistoryPassesACleanFix() throws {
        let (world, clone) = try localOnly(commits: 1, over: 5)
        defer { clone.remove(); world.removeAll() }
        let start = (try? clone.branchTips()) ?? [:]
        try git.run(["commit", "-q", "--amend", "-m", "reworded"], in: clone.path)
        try FixGuard.check(clone, proposal: plan(branch: "local/y"), before: start, limit: 3)
    }

    /// Two identical “wip” commits squashed into one: one twin, two commits to vouch for.
    @Test func oneTwinVouchesForOneCommit() throws {
        let (world, clone) = try localOnly(commits: 2, over: 1)
        defer { clone.remove(); world.removeAll() }
        let start = (try? clone.branchTips()) ?? [:]
        let wips = try git.run(["rev-list", "--reverse", "main..local/y"], in: clone.path).split(separator: "\n").map(String.init)
        try git.run(["reset", "-q", "--soft", "main"], in: clone.path)
        try git.run(["commit", "-q", "-m", "wip"], in: clone.path, timeout: GitRunner.localTimeout, environment: Self.wipDate)
        #expect(throws: FixRefusal.droppedCommit("local/y", sha: wips[1])) {
            try FixGuard.check(clone, proposal: plan(branch: "local/y"), before: start)
        }
    }

    // MARK: the clone's git settings

    /// C1: AiTerm's own `git status` would run a planted `core.fsmonitor` as the person, unsandboxed.
    @Test func aPlantedFsmonitorIsRefusedAndNeverRuns() throws {
        let start = before
        try resolve(with: "topic=both\n")
        let hook = world.root + "/plant.sh", marker = world.root + "/planted-ran"
        try "#!/bin/sh\ntouch '\(marker)'\n".write(toFile: hook, atomically: true, encoding: .utf8)
        chmod(hook, 0o755)
        try git.run(["config", "core.fsmonitor", hook], in: clone.path)
        #expect(throws: FixRefusal.settingsChanged) { try FixGuard.check(clone, proposal: plan(), before: start) }
        #expect(!FileManager.default.fileExists(atPath: marker), "the planted command never ran")
    }

    /// A `commondir` file sends git to another repository's config — and refs — which the bytes of
    /// `.git/config` alone would never show.
    @Test func aPlantedCommondirIsRefused() throws {
        let start = before
        try resolve(with: "topic=both\n")
        let elsewhere = world.root + "/elsewhere"
        try git.run(["init", "-q", elsewhere], in: world.root)
        try (elsewhere + "/.git\n").write(toFile: clone.path + "/.git/commondir", atomically: true, encoding: .utf8)
        #expect(throws: FixRefusal.settingsChanged) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    // MARK: the repository AiTerm's git reads

    /// A clean filter that leaves a marker when git runs it.
    private func plantedHook() throws -> (hook: String, marker: String) {
        let hook = world.root + "/plant.sh", marker = world.root + "/planted-ran"
        try "#!/bin/sh\ntouch '\(marker)'\ncat\n".write(toFile: hook, atomically: true, encoding: .utf8)
        chmod(hook, 0o755)
        return (hook, marker)
    }

    /// Wave 2: `.git/config` untouched, `.git` broken, and the clone's root laid out as a git
    /// directory whose config plants a clean filter. Git's discovery would take the root for a bare
    /// repository and run the filter on `status`; AiTerm's git names `.git` itself, so it fails closed.
    @Test func aRootLaidOutAsAGitDirectoryIsNeverReadAndItsFilterNeverRuns() throws {
        let start = before
        try resolve(with: "topic=both\n")
        let (hook, marker) = try plantedHook()
        let root = clone.path, files = FileManager.default
        try "garbage\n".write(toFile: root + "/.git/HEAD", atomically: true, encoding: .utf8)
        try files.createSymbolicLink(atPath: root + "/objects", withDestinationPath: root + "/.git/objects")
        try files.createSymbolicLink(atPath: root + "/refs", withDestinationPath: root + "/.git/refs")
        try files.copyItem(atPath: root + "/.git/index", toPath: root + "/index")
        try "ref: refs/heads/feat/x\n".write(toFile: root + "/HEAD", atomically: true, encoding: .utf8)
        try "[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = \(root)\n[filter \"x\"]\n\tclean = \(hook)\n"
            .write(toFile: root + "/config", atomically: true, encoding: .utf8)
        try files.createDirectory(atPath: root + "/info", withIntermediateDirectories: true)
        try "* filter=x\n".write(toFile: root + "/info/attributes", atomically: true, encoding: .utf8)
        // Newer than the index, so `status` cleans it again.
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: root + "/config.ts")
        #expect(throws: FixRefusal.self) { try FixGuard.check(clone, proposal: plan(), before: start) }
        #expect(!files.fileExists(atPath: marker), "the planted filter never ran")
    }

    /// A replace ref swaps what a commit holds for git — here the markers for a clean tree — so
    /// AiTerm's git reads the objects as they are.
    @Test func aReplaceRefCannotHideAConflictMarker() throws {
        let start = before
        try resolve(with: "<<<<<<< HEAD\ntopic=theirs\n=======\ntopic=mine\n>>>>>>> mine\n")
        let tip = try clone.tip("feat/x")
        try "topic=both\n".write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
        try git.run(["add", "config.ts"], in: clone.path)
        let tree = try git.run(["write-tree"], in: clone.path)
        let clean = try git.run(["commit-tree", tree, "-p", tip + "~1", "-m", "mine"], in: clone.path)
        try git.run(["reset", "-q", "--hard"], in: clone.path)
        try git.run(["replace", tip, clean], in: clone.path)
        #expect(throws: FixRefusal.conflictMarkers(["config.ts"])) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    /// Grafts — still honoured by git — give a commit other parents. Grafting the local commit
    /// under origin's would make the dropped commit look like origin's own.
    @Test func aGraftCannotHideADroppedCommit() throws {
        let start = before
        try git.run(["rebase", "--abort"], in: clone.path)
        try git.run(["reset", "-q", "--hard", "origin/feat/x"], in: clone.path)
        let mine = try world.sha("feat/x", in: world.repo)
        try "\(try clone.tip("feat/x")) \(mine)\n".write(toFile: clone.path + "/.git/info/grafts", atomically: true, encoding: .utf8)
        #expect(throws: FixRefusal.droppedCommit("feat/x", sha: mine)) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    /// A `shallow` file cuts history short, which can hide a commit from the lost-commit check.
    @Test func aPlantedShallowFileIsRefused() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try "\(clone.startTip)\n".write(toFile: clone.path + "/.git/shallow", atomically: true, encoding: .utf8)
        #expect(throws: FixRefusal.settingsChanged) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    /// The same bytes behind a symlink are not the clone's file.
    @Test func aConfigSwappedForASymlinkIsRefused() throws {
        let start = before
        try resolve(with: "topic=both\n")
        let copy = world.root + "/config-copy", config = clone.path + "/.git/config"
        try FileManager.default.copyItem(atPath: config, toPath: copy)
        try FileManager.default.removeItem(atPath: config)
        try FileManager.default.createSymbolicLink(atPath: config, withDestinationPath: copy)
        #expect(throws: FixRefusal.settingsChanged) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    /// A FIFO for a config would hang a plain read, which waits for a writer; it is refused at once.
    @Test func aConfigSwappedForAFifoIsRefusedWithoutHanging() throws {
        let config = clone.path + "/.git/config"
        try FileManager.default.removeItem(atPath: config)
        #expect(mkfifo(config, 0o644) == 0)
        let clone = clone
        let result = Mutex<FixRefusal?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do throws(FixRefusal) { try clone.checkSettings() } catch { result.withLock { $0 = error } }
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 5) == .success
        if !finished {
            // Hand the stuck reader a writer, so it returns and the thread ends.
            let writer = open(config, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            done.wait()
        }
        #expect(finished, "refused within 5 s, not left waiting on the FIFO")
        #expect(result.withLock { $0 } == .settingsChanged)
    }

    /// Wave 3: a populated submodule with a clean filter of its own. `status` would look inside it
    /// and run that filter unsandboxed; FixGuard's `status --ignore-submodules=all` never looks into
    /// a submodule's work tree. The committed `.gitmodules` says `ignore = none`, which outranks a
    /// `diff.ignoreSubmodules` setting, so only the explicit flag can be the guard.
    @Test func aPopulatedSubmoduleNeverRunsItsFilter() throws {
        let start = before
        try resolve(with: "topic=both\n")
        let (hook, marker) = try plantedHook()
        let sub = clone.path + "/sub", files = FileManager.default
        try git.run(["init", "-q", sub], in: clone.path)
        try "s\n".write(toFile: sub + "/s.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "s.txt"], in: sub)
        try git.run(["commit", "-q", "-m", "s"], in: sub)
        let config = try String(contentsOfFile: sub + "/.git/config", encoding: .utf8)
        try (config + "[filter \"x\"]\n\tclean = \(hook)\n").write(toFile: sub + "/.git/config", atomically: true, encoding: .utf8)
        try "* filter=x\n".write(toFile: sub + "/.git/info/attributes", atomically: true, encoding: .utf8)
        try "[submodule \"sub\"]\n\tpath = sub\n\turl = ./sub\n\tignore = none\n"
            .write(toFile: clone.path + "/.gitmodules", atomically: true, encoding: .utf8)
        try git.run(["add", "sub", ".gitmodules"], in: clone.path)   // `sub` as a gitlink
        try git.run(["commit", "-q", "-m", "sub"], in: clone.path)
        try? files.removeItem(atPath: marker)   // what setting it up ran is not AiTerm's
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: sub + "/s.txt")
        _ = try? FixGuard.check(clone, proposal: plan(), before: start)
        #expect(!files.fileExists(atPath: marker), "the submodule's filter never ran")
    }

    /// Another repository with a clean filter planted, for `.git` to be swapped for.
    private func plantedRepository() throws -> (gitDir: String, marker: String) {
        let (hook, marker) = try plantedHook()
        let other = world.root + "/planted"
        try git.run(["init", "-q", other], in: world.root)
        let config = try String(contentsOfFile: other + "/.git/config", encoding: .utf8)
        try (config + "[filter \"x\"]\n\tclean = \(hook)\n").write(toFile: other + "/.git/config", atomically: true, encoding: .utf8)
        try "* filter=x\n".write(toFile: other + "/.git/info/attributes", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: clone.path + "/config.ts")
        return (other + "/.git", marker)
    }

    @Test func aDotGitSwappedForAGitfileIsRefusedAndNeverRead() throws {
        let start = before
        try resolve(with: "topic=both\n")
        let (gitDir, marker) = try plantedRepository()
        try FileManager.default.moveItem(atPath: clone.path + "/.git", toPath: world.root + "/moved-git")
        try "gitdir: \(gitDir)\n".write(toFile: clone.path + "/.git", atomically: true, encoding: .utf8)
        #expect(throws: FixRefusal.settingsChanged) { try FixGuard.check(clone, proposal: plan(), before: start) }
        #expect(!FileManager.default.fileExists(atPath: marker), "the planted filter never ran")
    }

    @Test func aDotGitSwappedForASymlinkIsRefusedAndNeverRead() throws {
        let start = before
        try resolve(with: "topic=both\n")
        let (gitDir, marker) = try plantedRepository()
        try FileManager.default.moveItem(atPath: clone.path + "/.git", toPath: world.root + "/moved-git")
        try FileManager.default.createSymbolicLink(atPath: clone.path + "/.git", withDestinationPath: gitDir)
        #expect(throws: FixRefusal.settingsChanged) { try FixGuard.check(clone, proposal: plan(), before: start) }
        #expect(!FileManager.default.fileExists(atPath: marker), "the planted filter never ran")
    }

    /// The same settings behind a symlinked `.git` are still not the clone's own folder: only the
    /// directory check refuses this one.
    @Test func aDotGitSymlinkedToAnIdenticalCopyIsRefused() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try FileManager.default.moveItem(atPath: clone.path + "/.git", toPath: world.root + "/moved-git")
        try FileManager.default.createSymbolicLink(atPath: clone.path + "/.git", withDestinationPath: world.root + "/moved-git")
        #expect(throws: FixRefusal.settingsChanged) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    /// M3: git failing while checking a fix is a failed check, not a failed preparation.
    @Test func gitFailingDuringTheChecksSaysTheCheckFailed() throws {
        let failing = FixClone(path: clone.path, branch: clone.branch, startTip: clone.startTip, originTip: clone.originTip,
                               git: FailingGit(), settings: clone.settings)
        #expect(throws: FixRefusal.checkFailed("Couldn’t check the fix: Index file corrupt. Nothing was changed.")) {
            try FixGuard.check(failing, proposal: plan(), before: [:])
        }
    }

    // MARK: fixtures

    private static let wipDate = ["GIT_AUTHOR_DATE": "1700000000 +0000"]

    /// Another world and clone, after `prepare` has changed what origin holds.
    private func second(_ prepare: (ConflictWorld) throws -> Void) throws -> (ConflictWorld, FixClone) {
        let world = try ConflictWorld(git: .hermetic())
        try prepare(world)
        let clone = try FixClone.make(for: FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "feat/x",
                                                       recreateRebase: true, retry: .createReview), git: .hermetic(), root: world.root)
        return (world, clone)
    }

    /// A world whose `local/y` has `commits` commits named “wip” on top of `base` more commits of `main`,
    /// and no origin; its clone is on it.
    private func localOnly(commits: Int, over base: Int) throws -> (ConflictWorld, FixClone) {
        let world = try ConflictWorld(git: .hermetic())
        for i in 1...base { try world.commit("main \(i)", file: "m.txt", contents: "\(i)\n", in: world.repo) }
        try git.run(["checkout", "-q", "-b", "local/y"], in: world.repo)
        for i in 1...commits {
            try "\(i)\n".write(toFile: world.repo + "/w\(i).txt", atomically: true, encoding: .utf8)
            try git.run(["add", "."], in: world.repo)
            try git.run(["commit", "-q", "-m", "wip"], in: world.repo, timeout: GitRunner.localTimeout, environment: Self.wipDate)
        }
        try git.run(["checkout", "-q", "main"], in: world.repo)
        let clone = try FixClone.make(for: FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "local/y",
                                                       recreateRebase: false, retry: .createReview), git: .hermetic(), root: world.root)
        return (world, clone)
    }
}

/// Git that fails every command, as a corrupt index would.
private struct FailingGit: GitRunning {
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        throw GitError(args: args, code: 128, stderr: "fatal: index file corrupt")
    }
}
