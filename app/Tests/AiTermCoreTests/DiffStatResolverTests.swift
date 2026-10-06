import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

struct DiffStatResolverTests {
    private let git = GitRunner.hermetic()

    /// A repo on `main` with one tracked file of three lines, and a task worktree off it.
    private func makeRepo(refFormat: String = "files") throws -> (repo: String, worktree: String) {
        let repo = try GitFixture.makeRepo(prefix: "diff-", refFormat: refFormat, git: git)
        try write("one\ntwo\nthree\n", to: repo + "/a.txt")
        try git.run(["add", "."], in: repo)
        try git.run(["commit", "-q", "-m", "add a.txt"], in: repo)
        let worktree = repo + "/.worktrees/feat"
        try git.run(["worktree", "add", "-q", "-b", "feat/x", worktree], in: repo)
        return (repo, worktree)
    }

    private func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func commit(_ message: String, in dir: String) throws {
        try git.run(["add", "-A"], in: dir)
        try git.run(["commit", "-q", "-m", message], in: dir)
    }

    @Test func aFreshWorktreeHasNoDiff() throws {
        let (_, worktree) = try makeRepo()
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
    }

    @Test func countsCommittedWorkAgainstTheBase() throws {
        let (_, worktree) = try makeRepo()
        try write("one\nTWO\nthree\nfour\n", to: worktree + "/a.txt")
        try commit("edit", in: worktree)
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 1))
    }

    @Test func countsUncommittedEditsToo() throws {
        let (_, worktree) = try makeRepo()
        try write("one\nthree\n", to: worktree + "/a.txt")
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 1))
    }

    @Test func countsUntrackedFilesAsAdditions() throws {
        // An agent's new file is work on the branch before anyone runs `git add`.
        let (_, worktree) = try makeRepo()
        try write("x\ny\n", to: worktree + "/new.txt")
        try write("no trailing newline", to: worktree + "/partial.txt")
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "main") == DiffStat(added: 3, removed: 0))
    }

    /// Once added, git counts a symlink as one line, its target path. The count must not follow it:
    /// a link to a long file would count that file, and one to a large file would get past the
    /// size caps, which look at the link itself.
    @Test func anUntrackedSymlinkIsOneLineWhateverItPointsAt() throws {
        let (_, worktree) = try makeRepo()
        let target = worktree + "-target.txt"
        defer { try? FileManager.default.removeItem(atPath: target) }
        try write("a\nb\nc\nd\n", to: target)
        try FileManager.default.createSymbolicLink(atPath: worktree + "/link", withDestinationPath: target)
        try FileManager.default.createSymbolicLink(atPath: worktree + "/dangling", withDestinationPath: worktree + "/nothing")
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
    }

    /// A link to a device never ends: reading through it stalled the whole checkout monitor. Only a
    /// regular file is read, and a link is the one line git counts it as.
    @Test func anUntrackedLinkToADeviceIsNeitherReadNorWaitedFor() throws {
        let (_, worktree) = try makeRepo()
        try FileManager.default.createSymbolicLink(atPath: worktree + "/zero", withDestinationPath: "/dev/zero")
        try write("x\n", to: worktree + "/new.txt")
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
    }

    /// `git ls-files --others` never lists a FIFO, so the listing cannot hand one over; this is the
    /// defence for one that takes a listed file's place between the `lstat` and the open, which
    /// would otherwise wait for a writer. It is opened without blocking and then refused.
    @Test func aFifoThatTookAFilesPlaceIsNotRead() throws {
        let folder = try GitFixture.folder("fifo-")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #expect(mkfifo(folder + "/pipe", 0o600) == 0)
        #expect(DiffStatResolver.contents(of: folder + "/pipe", size: 4) == nil)
    }

    /// The caps were checked against the size `lstat` saw: a file that has grown since is skipped
    /// rather than read in full, however far it grew.
    @Test func aFileThatGrewSinceItWasMeasuredIsNotRead() throws {
        let folder = try GitFixture.folder("grown-")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try write("a\nb\n", to: folder + "/f")
        #expect(DiffStatResolver.contents(of: folder + "/f", size: 4) == Data("a\nb\n".utf8))
        #expect(DiffStatResolver.contents(of: folder + "/f", size: 3) == nil, "one byte past the size is the whole answer")
        #expect(DiffStatResolver.contents(of: folder + "/f", size: 0) == nil)
        try write("", to: folder + "/empty")
        #expect(DiffStatResolver.contents(of: folder + "/empty", size: 0) == nil)
    }

    @Test func ignoredAndBinaryFilesDoNotCount() throws {
        let (_, worktree) = try makeRepo()
        try write("ignored.log\n", to: worktree + "/.gitignore")
        try write("a\nb\nc\n", to: worktree + "/ignored.log")
        try Data([0x00, 0x01, 0x0A, 0x02]).write(to: URL(fileURLWithPath: worktree + "/blob.bin"))
        // `.gitignore` itself is one untracked line.
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0))
    }

    @Test func measuresFromTheMergeBaseNotTheBaseTip() throws {
        // Work landing on main after the task branched is not the task's diff.
        let (repo, worktree) = try makeRepo()
        try write("one\ntwo\nthree\nmain only\n", to: repo + "/a.txt")
        try commit("main moves on", in: repo)
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
    }

    @Test func fallsBackToTheRemoteBranchWhenTheBaseIsNotLocal() throws {
        // A review's base is the MR target, which may exist only as `origin/<target>`.
        let (repo, worktree) = try makeRepo()
        try git.run(["update-ref", "refs/remotes/origin/develop", "HEAD"], in: repo)
        try write("extra\n", to: worktree + "/b.txt")
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "develop") == DiffStat(added: 1, removed: 0))
    }

    @Test func aStaleLocalBaseYieldsToTheLaterRemoteOne() throws {
        // The task rebased onto `origin/main`, whose new commit local `main` never pulled. That
        // commit is upstream's work, not the task's.
        let (_, worktree) = try makeRepo()
        try write("upstream\n", to: worktree + "/up.txt")
        try commit("upstream", in: worktree)
        try git.run(["update-ref", "refs/remotes/origin/main", "HEAD"], in: worktree)
        try write("mine\nmine\n", to: worktree + "/mine.txt")
        try commit("task", in: worktree)
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
    }

    @Test func noBaseOrNoRepositoryIsNoAnswer() throws {
        let (_, worktree) = try makeRepo()
        let resolver = DiffStatResolver(git: .hermetic())
        #expect(resolver.diff(for: worktree, base: "") == nil)
        #expect(resolver.diff(for: worktree, base: "no-such-branch") == nil)
        #expect(resolver.diff(for: "/definitely/not/here", base: "main") == nil)
    }

    @Test func answersFromTheCacheUntilItExpires() throws {
        let clock = TestClock()
        let (_, worktree) = try makeRepo()
        let resolver = DiffStatResolver(git: .hermetic(), now: { clock.now }, ttl: 5)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
        try write("new\n", to: worktree + "/c.txt")
        clock.advance(by: 4)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
        clock.advance(by: 2)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0))
    }

    /// Once the cached diff expires, only `diff --numstat` and `ls-files` run again: the
    /// merge-base is kept until one of the refs it was computed from moves.
    @Test func aMergeBaseIsReusedUntilARefItComesFromMoves() throws {
        let clock = TestClock()
        let (repo, worktree) = try makeRepo()
        let recording = RecordingGitRunner(forwardingTo: .hermetic()), commands = Commands(recording)
        let resolver = DiffStatResolver(git: recording, now: { clock.now }, ttl: 5)
        func expired() -> DiffStat? { commands.reset(); clock.advance(by: 6); return resolver.diff(for: worktree, base: "main") }
        try write("mine\nmine\n", to: worktree + "/mine.txt")
        try commit("task", in: worktree)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))

        #expect(expired() == DiffStat(added: 2, removed: 0))
        #expect(commands.since == ["diff", "ls-files"])

        try write("one\ntwo\nthree\nmain only\n", to: repo + "/a.txt")
        try commit("main moves on", in: repo)
        #expect(expired() == DiffStat(added: 2, removed: 0))
        #expect(commands.since.contains("merge-base"), "the base branch moved")
        #expect(expired() == DiffStat(added: 2, removed: 0))
        #expect(commands.since == ["diff", "ls-files"])

        try git.run(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repo)
        #expect(expired() == DiffStat(added: 2, removed: 0))
        #expect(commands.since.contains("merge-base"), "origin/<base> appeared")

        // Merging main moves only the branch HEAD points at — the HEAD file is untouched — and
        // makes main's commit the merge-base. The old one would count main's line as the task's.
        try git.run(["merge", "-q", "--no-edit", "main"], in: worktree)
        #expect(expired() == DiffStat(added: 2, removed: 0))
        #expect(commands.since.contains("merge-base"), "the task's own branch moved")

        try git.run(["pack-refs", "--all"], in: repo)
        #expect(expired() == DiffStat(added: 2, removed: 0))
        #expect(commands.since.contains("merge-base"), "the refs moved into packed-refs")

        // Checking out a branch from the first commit: the kept merge-base, main's tip, would
        // count main's line and the task's two as removed.
        let root = try git.run(["rev-list", "--max-parents=0", "HEAD"], in: repo)
        try git.run(["checkout", "-q", "-b", "old", root], in: worktree)
        #expect(expired() == DiffStat(added: 0, removed: 0))
        #expect(commands.since.contains("merge-base"), "HEAD moved to another branch")
        try write("late\n", to: worktree + "/late.txt")
        try commit("late", in: worktree)
        #expect(expired() == DiffStat(added: 1, removed: 0))

        // Rebasing onto main makes main's tip the merge-base again; the first commit would count
        // main's own line as the task's.
        try git.run(["rebase", "-q", "main"], in: worktree)
        #expect(expired() == DiffStat(added: 1, removed: 0))
        #expect(commands.since.contains("merge-base"), "the rebase rewrote HEAD")
    }

    /// A reftable repository keeps no ref in a file of its own: every update adds a table and
    /// rewrites the stack's list — the worktree's own for its HEAD, the shared one for branches.
    @Test func aReftableMergeBaseIsRecomputedWhenARefMoves() throws {
        let clock = TestClock()
        let (repo, worktree) = try makeRepo(refFormat: "reftable")
        let recording = RecordingGitRunner(forwardingTo: .hermetic()), commands = Commands(recording)
        let resolver = DiffStatResolver(git: recording, now: { clock.now }, ttl: 5)
        func expired() -> DiffStat? { commands.reset(); clock.advance(by: 6); return resolver.diff(for: worktree, base: "main") }
        try write("mine\nmine\n", to: worktree + "/mine.txt")
        try commit("task", in: worktree)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
        #expect(expired() == DiffStat(added: 2, removed: 0))
        #expect(commands.since == ["diff", "ls-files"])

        try write("one\ntwo\nthree\nmain only\n", to: repo + "/a.txt")
        try commit("main moves on", in: repo)
        try git.run(["merge", "-q", "--no-edit", "main"], in: worktree)
        #expect(expired() == DiffStat(added: 2, removed: 0), "main's line is not the task's")
        #expect(commands.since.contains("merge-base"), "the refs moved")

        let root = try git.run(["rev-list", "--max-parents=0", "HEAD"], in: repo)
        try git.run(["checkout", "-q", "-b", "old", root], in: worktree)
        #expect(expired() == DiffStat(added: 0, removed: 0))
        #expect(commands.since.contains("merge-base"), "HEAD moved to another branch")
    }

    /// Git renames a new ref file into place, so a rewrite shows as a new inode even where the
    /// filesystem's clock has not ticked.
    @Test func aFileReplacedWithinTheSameSecondIsAChange() throws {
        let dir = NSTemporaryDirectory() + "stamp-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ref = dir + "/main", lock = dir + "/main.lock"
        // Whole seconds, as a filesystem with one-second timestamps records both writes.
        let date = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        try write("aaaa\n", to: ref)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: ref)
        let stamps = FileStamps([ref, dir + "/absent"])
        #expect(stamps.areCurrent)
        try write("bbbb\n", to: lock)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: lock)
        #expect(rename(lock, ref) == 0)
        #expect(try FileManager.default.attributesOfItem(atPath: ref)[.modificationDate] as? Date == date)
        #expect(!stamps.areCurrent)
    }

    @Test func untrackedCountingStopsAtItsCaps() throws {
        #expect(DiffStatResolver.UntrackedCap.standard == DiffStatResolver.UntrackedCap(files: 2_000, bytes: 20 << 20))
        let (_, worktree) = try makeRepo()
        for name in ["a", "b", "c", "d", "e"] { try write("x\ny\n", to: worktree + "/\(name).new") }
        #expect(DiffStatResolver(git: .hermetic()).diff(for: worktree, base: "main") == DiffStat(added: 10, removed: 0))
        #expect(DiffStatResolver(git: .hermetic(), untrackedCap: .init(files: 3, bytes: 1 << 20)).diff(for: worktree, base: "main")
                == DiffStat(added: 6, removed: 0))
        // Four bytes a file: two fit in ten, the third would not.
        #expect(DiffStatResolver(git: .hermetic(), untrackedCap: .init(files: 100, bytes: 10)).diff(for: worktree, base: "main")
                == DiffStat(added: 4, removed: 0))
    }

    @Test func linesAreCountedAsGitDiffWouldCountThem() {
        #expect(DiffStatResolver.lineCount(Data("a\nb\n".utf8)) == 2)
        #expect(DiffStatResolver.lineCount(Data("a\nb".utf8)) == 2)
        #expect(DiffStatResolver.lineCount(Data("\n\n\n".utf8)) == 3)
        #expect(DiffStatResolver.lineCount(Data()) == nil)
        #expect(DiffStatResolver.lineCount(Data([0x61, 0x00, 0x0A])) == nil)
    }

    /// Sets a file's modification time, to the nanosecond.
    private func setModified(_ path: String, to time: timespec) {
        var info = stat()
        #expect(lstat(path, &info) == 0)
        var times = [info.st_atimespec, time]
        #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)
    }

    /// Counts the untracked files the resolver reads, reading them as it would.
    private final class Reads: Sendable {
        private let count = Mutex(0)
        var total: Int { count.withLock { $0 } }
        func read(_ path: String, size: Int) -> Data? {
            count.withLock { $0 += 1 }
            return DiffStatResolver.contents(of: path, size: size)
        }
    }

    /// An untracked file is counted once: what its lines came to is kept against its `lstat`, and
    /// it is read again only when that changes — its modification time, its size, or its change
    /// time, which a `chmod` moves and which a rewrite that put the old modification time back
    /// cannot help moving.
    @Test func anUntrackedFileIsReadAgainOnlyWhenItsStatChanges() throws {
        let clock = TestClock(), reads = Reads()
        let (_, worktree) = try makeRepo()
        let file = worktree + "/new.txt"
        try write("a\nb\n", to: file)
        let resolver = DiffStatResolver(git: .hermetic(), now: { clock.now }, ttl: 5, untrackedCap: .standard, contents: reads.read)
        func expired() -> DiffStat? { clock.advance(by: 6); return resolver.diff(for: worktree, base: "main") }
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
        #expect(reads.total == 1)
        #expect(expired() == DiffStat(added: 2, removed: 0))
        #expect(reads.total == 1, "the same stat, so the count that was kept")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        #expect(expired() == DiffStat(added: 2, removed: 0))
        #expect(reads.total == 2, "a new change time is read again")
        var before = stat()
        #expect(lstat(file, &before) == 0)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try handle.write(contentsOf: Data("a\n\n\n".utf8))
        try handle.close()
        setModified(file, to: before.st_mtimespec)
        #expect(expired() == DiffStat(added: 3, removed: 0), "rewritten at the size and modification time it had")
        #expect(reads.total == 3)
        setModified(file, to: timespec(tv_sec: before.st_mtimespec.tv_sec + 2, tv_nsec: before.st_mtimespec.tv_nsec))
        #expect(expired() == DiffStat(added: 3, removed: 0))
        #expect(reads.total == 4, "a new modification time is read again")
        try write("a\n\n\n\n\n", to: file)
        #expect(expired() == DiffStat(added: 5, removed: 0), "and so is a new size")
        #expect(reads.total == 5)
    }

    /// The caps stop the count in the same place whether the files were read or remembered.
    @Test func theCapsApplyToRememberedFilesToo() throws {
        let clock = TestClock()
        let (_, worktree) = try makeRepo()
        for name in ["a", "b", "c", "d", "e"] { try write("x\ny\n", to: worktree + "/\(name).new") }
        let resolver = DiffStatResolver(git: .hermetic(), now: { clock.now }, ttl: 5, untrackedCap: .init(files: 100, bytes: 10))
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 4, removed: 0))
        clock.advance(by: 6)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 4, removed: 0))
    }

    /// A file that is not listed any more is forgotten, and counted afresh if it comes back.
    @Test func aFileThatLeftTheListingIsCountedAgainWhenItReturns() throws {
        let clock = TestClock()
        let (_, worktree) = try makeRepo()
        let file = worktree + "/new.txt"
        try write("a\nb\n", to: file)
        var before = stat()
        #expect(lstat(file, &before) == 0)
        let resolver = DiffStatResolver(git: .hermetic(), now: { clock.now }, ttl: 5)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
        clock.advance(by: 6)
        try FileManager.default.removeItem(atPath: file)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
        // Back with the size and time it had, and a count of its own: it was forgotten, not remembered.
        try write("a\n\n\n", to: file)
        setModified(file, to: before.st_mtimespec)
        clock.advance(by: 6)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 3, removed: 0))
    }

    /// Git running out of time says nothing about the diff: the last one stands rather than the badge
    /// going blank for a ttl, and the checkout is left alone for the backoff instead of costing its
    /// deadline on every pass.
    @Test func aGitThatRanOutOfTimeLeavesTheLastDiffAndIsLeftAlone() throws {
        let clock = TestClock()
        let (_, worktree) = try makeRepo()
        try write("x\n", to: worktree + "/new.txt")
        let flaky = FlakyGitRunner(), resolver = DiffStatResolver(git: flaky, now: { clock.now }, ttl: 5)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0))
        try write("y\nz\n", to: worktree + "/more.txt")
        flaky.failing = true
        clock.advance(by: 6)
        let calls = flaky.calls
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0), "the last known diff stands")
        #expect(flaky.calls > calls)
        let asked = flaky.calls
        flaky.failing = false
        clock.advance(by: 6)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0))
        #expect(flaky.calls == asked, "within the backoff git is not asked")
        clock.advance(by: TimedOut.backoff)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 3, removed: 0), "and after it, it is")
    }

    /// With no diff known yet a timeout is no answer either: nothing is stored, so the first ask
    /// after the backoff finds the diff.
    @Test func aFirstTimeoutIsNotKeptAsNoDiff() throws {
        let clock = TestClock()
        let (_, worktree) = try makeRepo()
        let flaky = FlakyGitRunner(), resolver = DiffStatResolver(git: flaky, now: { clock.now }, ttl: 5)
        flaky.failing = true
        #expect(resolver.diff(for: worktree, base: "main") == nil)
        flaky.failing = false
        clock.advance(by: TimedOut.backoff)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
    }

    /// A merge-base that timed out is not the merge-base: kept as "none" it would hide the diff until
    /// one of the refs moved.
    @Test func aMergeBaseThatTimedOutIsNotKept() throws {
        let clock = TestClock()
        let (_, worktree) = try makeRepo()
        let runner = TimesOut(command: "merge-base"), resolver = DiffStatResolver(git: runner, now: { clock.now }, ttl: 5)
        runner.failing = true
        #expect(resolver.diff(for: worktree, base: "main") == nil)
        runner.failing = false
        clock.advance(by: TimedOut.backoff)
        #expect(resolver.diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
    }

    /// A pass over the tasks drops what it holds for any task no longer among them.
    @Test func forgetsTasksThatAreNoLongerPassedIn() throws {
        let (repo, first) = try makeRepo()
        let second = repo + "/.worktrees/other"
        try git.run(["worktree", "add", "-q", "-b", "feat/y", second], in: repo)
        func task(_ path: String) -> TaskItem {
            TaskItem(id: UUID(), projectId: UUID(), title: "t", branch: "b", worktreePath: path, baseBranch: "main",
                     jira: nil, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                     createdAt: Date(), windowId: nil)
        }
        let a = task(first), b = task(second)
        let recording = RecordingGitRunner(forwardingTo: .hermetic()), commands = Commands(recording)
        let resolver = DiffStatResolver(git: recording, now: { Date(timeIntervalSince1970: 0) }, ttl: 5)
        #expect(resolver.diffs(for: [a, b]).count == 2)
        _ = resolver.diffs(for: [a])
        commands.reset()
        _ = resolver.diffs(for: [a])
        #expect(commands.since.isEmpty, "a task still passed in keeps its answer")
        _ = resolver.diffs(for: [b])
        #expect(commands.since.contains("merge-base"), "a task left out was forgotten")
    }
}

/// The git commands `runner` ran since the last `reset` — each one's first word.
private final class Commands {
    private let runner: RecordingGitRunner
    private var mark = 0
    init(_ runner: RecordingGitRunner) { self.runner = runner }
    func reset() { mark = runner.calls.count }
    var since: [String] { runner.calls.dropFirst(mark).map { $0.args.first ?? "" } }
}

/// A git whose one kind of command times out while `failing` is set, and runs for real otherwise.
private final class TimesOut: GitRunning {
    private let command: String
    private let inner: any GitRunning = GitRunner.hermetic()
    private let state = Mutex(false)
    init(command: String) { self.command = command }

    var failing: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if args.first == command, failing { throw GitError(args: args, code: 15, stderr: "git \(command) timed out after \(timeout) s", timedOut: true) }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}
