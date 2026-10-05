import Foundation
import Testing
@testable import AiTermCore

struct DiffStatResolverTests {
    private let git = GitRunner()

    /// A repo on `main` with one tracked file of three lines, and a task worktree off it.
    private func makeRepo(refFormat: String = "files") throws -> (repo: String, worktree: String) {
        let dir = NSTemporaryDirectory() + "diff-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        try git.run(["init", "--initial-branch=main", "--ref-format=" + refFormat, "-q", repo], in: "/")
        try git.run(["config", "user.email", "t@example.com"], in: repo)
        try git.run(["config", "user.name", "T"], in: repo)
        try write("one\ntwo\nthree\n", to: repo + "/a.txt")
        try git.run(["add", "."], in: repo)
        try git.run(["commit", "-q", "-m", "init"], in: repo)
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
        #expect(DiffStatResolver().diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
    }

    @Test func countsCommittedWorkAgainstTheBase() throws {
        let (_, worktree) = try makeRepo()
        try write("one\nTWO\nthree\nfour\n", to: worktree + "/a.txt")
        try commit("edit", in: worktree)
        #expect(DiffStatResolver().diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 1))
    }

    @Test func countsUncommittedEditsToo() throws {
        let (_, worktree) = try makeRepo()
        try write("one\nthree\n", to: worktree + "/a.txt")
        #expect(DiffStatResolver().diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 1))
    }

    @Test func countsUntrackedFilesAsAdditions() throws {
        // An agent's new file is work on the branch before anyone runs `git add`.
        let (_, worktree) = try makeRepo()
        try write("x\ny\n", to: worktree + "/new.txt")
        try write("no trailing newline", to: worktree + "/partial.txt")
        #expect(DiffStatResolver().diff(for: worktree, base: "main") == DiffStat(added: 3, removed: 0))
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
        #expect(DiffStatResolver().diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
    }

    /// A link to a device never ends and a FIFO waits for a writer: reading either stalled the
    /// whole checkout monitor. Only a regular file is read.
    @Test func anUntrackedDeviceOrFifoIsNeitherReadNorWaitedFor() throws {
        let (_, worktree) = try makeRepo()
        try FileManager.default.createSymbolicLink(atPath: worktree + "/zero", withDestinationPath: "/dev/zero")
        #expect(mkfifo(worktree + "/pipe", 0o600) == 0)
        try write("x\n", to: worktree + "/new.txt")
        #expect(DiffStatResolver().diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
    }

    @Test func ignoredAndBinaryFilesDoNotCount() throws {
        let (_, worktree) = try makeRepo()
        try write("ignored.log\n", to: worktree + "/.gitignore")
        try write("a\nb\nc\n", to: worktree + "/ignored.log")
        try Data([0x00, 0x01, 0x0A, 0x02]).write(to: URL(fileURLWithPath: worktree + "/blob.bin"))
        // `.gitignore` itself is one untracked line.
        #expect(DiffStatResolver().diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0))
    }

    @Test func measuresFromTheMergeBaseNotTheBaseTip() throws {
        // Work landing on main after the task branched is not the task's diff.
        let (repo, worktree) = try makeRepo()
        try write("one\ntwo\nthree\nmain only\n", to: repo + "/a.txt")
        try commit("main moves on", in: repo)
        #expect(DiffStatResolver().diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
    }

    @Test func fallsBackToTheRemoteBranchWhenTheBaseIsNotLocal() throws {
        // A review's base is the MR target, which may exist only as `origin/<target>`.
        let (repo, worktree) = try makeRepo()
        try git.run(["update-ref", "refs/remotes/origin/develop", "HEAD"], in: repo)
        try write("extra\n", to: worktree + "/b.txt")
        #expect(DiffStatResolver().diff(for: worktree, base: "develop") == DiffStat(added: 1, removed: 0))
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
        #expect(DiffStatResolver().diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
    }

    @Test func noBaseOrNoRepositoryIsNoAnswer() throws {
        let (_, worktree) = try makeRepo()
        let resolver = DiffStatResolver()
        #expect(resolver.diff(for: worktree, base: "") == nil)
        #expect(resolver.diff(for: worktree, base: "no-such-branch") == nil)
        #expect(resolver.diff(for: "/definitely/not/here", base: "main") == nil)
    }

    @Test func answersFromTheCacheUntilItExpires() throws {
        let clock = TestClock()
        let (_, worktree) = try makeRepo()
        let resolver = DiffStatResolver(now: { clock.now }, ttl: 5)
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
        let recording = RecordingGitRunner(), commands = Commands(recording)
        recording.forwards = true
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
        let recording = RecordingGitRunner(), commands = Commands(recording)
        recording.forwards = true
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
        #expect(DiffStatResolver().diff(for: worktree, base: "main") == DiffStat(added: 10, removed: 0))
        #expect(DiffStatResolver(untrackedCap: .init(files: 3, bytes: 1 << 20)).diff(for: worktree, base: "main")
                == DiffStat(added: 6, removed: 0))
        // Four bytes a file: two fit in ten, the third would not.
        #expect(DiffStatResolver(untrackedCap: .init(files: 100, bytes: 10)).diff(for: worktree, base: "main")
                == DiffStat(added: 4, removed: 0))
    }

    @Test func linesAreCountedAsGitDiffWouldCountThem() {
        #expect(DiffStatResolver.lineCount(Data("a\nb\n".utf8)) == 2)
        #expect(DiffStatResolver.lineCount(Data("a\nb".utf8)) == 2)
        #expect(DiffStatResolver.lineCount(Data("\n\n\n".utf8)) == 3)
        #expect(DiffStatResolver.lineCount(Data()) == nil)
        #expect(DiffStatResolver.lineCount(Data([0x61, 0x00, 0x0A])) == nil)
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
        let recording = RecordingGitRunner(), commands = Commands(recording)
        recording.forwards = true
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
