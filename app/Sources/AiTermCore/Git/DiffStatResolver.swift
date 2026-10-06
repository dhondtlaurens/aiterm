import Foundation

/// Lines a checkout adds and removes against the branch it started from.
public struct DiffStat: Equatable, Sendable {
    public var added: Int, removed: Int
    public init(added: Int, removed: Int) { self.added = added; self.removed = removed }
    public var isEmpty: Bool { added == 0 && removed == 0 }
}

/// Measures a task's worktree against its base branch: everything since the two diverged —
/// commits, uncommitted edits and untracked files alike, because an agent's work is on the branch
/// long before anyone commits it. Ignored and binary files do not count.
///
/// Unlike ``BranchResolver`` there is no one file git rewrites when a diff changes — any edit in
/// the tree does — so an answer is kept for `ttl` seconds instead, which is what stops the
/// two-second checkout monitor from running `git diff` over every worktree on every pass. The
/// merge-base the diff starts from *is* tied to files, the refs it joins, so it is kept until one
/// of them moves: an expired answer costs `diff --numstat` and `ls-files`, not the two or three
/// `merge-base` calls that find where to start. And an untracked file is counted once: what its
/// lines came to is kept against the file's `lstat`, so an expired answer reads only the files that
/// changed, not everything an agent's fixture folder holds.
///
/// A git that runs out of time is not an answer: the last known diff stands, and the worktree is
/// left alone for `failureBackoff` seconds, so a dead mount costs its deadline once in a while
/// rather than on every pass.
///
/// Thread-safe, and meant to be called off the main actor: every miss runs git.
///
/// Unchecked because `entries` and `mergeBases` are `var`s: both are only touched with `lock` held.
public final class DiffStatResolver: @unchecked Sendable {
    private struct Entry { var value: DiffStat?; var at: Date }
    /// What an untracked file counted as, and the `lstat` of the file it was counted from.
    private struct Counted { var stamp: Stamp; var lines: Int? }
    /// What a rewrite of a file changes: the modification time to the nanosecond, the size, the
    /// inode, which a file replaced rather than edited has a new one of, and the change time, which
    /// a rewrite that puts the old modification time back (`touch -r`, an unpacked archive) still
    /// moves and no one can set.
    private struct Stamp: Equatable {
        /// Both times in nanoseconds since the epoch.
        var modified: Int, changed: Int, size: Int, inode: UInt64

        init(_ info: stat) {
            modified = info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec
            changed = info.st_ctimespec.tv_sec * 1_000_000_000 + info.st_ctimespec.tv_nsec
            size = Int(info.st_size); inode = UInt64(info.st_ino)
        }
    }
    /// A merge-base, `nil` when the base could not be found, and the refs it was computed from, as
    /// they stood just before.
    private struct MergeBase { var refs: FileStamps; var commit: String? }

    /// How much of the untracked files is read to count their lines. A folder that escaped
    /// `.gitignore` — a `node_modules`, a build — can hold more than the whole task; past either
    /// limit the rest goes uncounted, so the badge is a floor rather than a two-second stall.
    struct UntrackedCap: Equatable {
        var files: Int, bytes: Int
        static let standard = UntrackedCap(files: 2_000, bytes: 20 << 20)
    }

    private let git: any GitRunning
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private let cap: UntrackedCap
    private let failureBackoff: TimeInterval
    /// Reads an untracked file to count its lines: ``contents(of:size:)``, which a test wraps to
    /// count what is read.
    private let contents: @Sendable (_ path: String, _ size: Int) -> Data?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var mergeBases: [String: MergeBase] = [:]
    /// Per checkout, the files the last pass counted, by path.
    private var counted: [String: [String: Counted]] = [:]
    /// When git last ran out of time on a checkout.
    private var timeouts: [String: TimedOut] = [:]

    /// Untracked files bigger than this are skipped rather than read: a line count is not worth a
    /// stray dump or build artifact that escaped `.gitignore`.
    static let untrackedByteLimit = 1 << 20

    public convenience init(git: any GitRunning, now: @escaping @Sendable () -> Date = Date.init, ttl: TimeInterval = 5) {
        self.init(git: git, now: now, ttl: ttl, untrackedCap: .standard)
    }

    init(git: any GitRunning, now: @escaping @Sendable () -> Date = Date.init, ttl: TimeInterval = 5, untrackedCap: UntrackedCap,
         failureBackoff: TimeInterval = TimedOut.backoff,
         contents: @escaping @Sendable (_ path: String, _ size: Int) -> Data? = DiffStatResolver.contents(of:size:)) {
        self.git = git; self.now = now; self.ttl = ttl; self.cap = untrackedCap; self.failureBackoff = failureBackoff
        self.contents = contents
    }

    /// The diff of `worktree` against `base`, or `nil` when there is no base, it cannot be found
    /// locally or as `origin/<base>`, or `worktree` is not a checkout.
    public func diff(for worktree: String, base: String) -> DiffStat? {
        guard !worktree.isEmpty, !base.isEmpty else { return nil }
        let key = Self.key(worktree, base)
        lock.lock()
        let known = entries[key]
        if let known, now().timeIntervalSince(known.at) < ttl { lock.unlock(); return known.value }
        if let timeout = timeouts[key], timeout.isPending(now: now(), backoff: failureBackoff) { lock.unlock(); return known?.value }
        lock.unlock()
        do {
            let value = try read(worktree, base: base, key: key)
            lock.lock(); entries[key] = Entry(value: value, at: now()); timeouts[key] = nil; lock.unlock()
            return value
        } catch {
            // Git ran out of time, which is no answer: the diff last known stands, and is not
            // asked about again until the backoff is over.
            lock.lock(); timeouts[key] = TimedOut(error, at: now()); lock.unlock()
            return known?.value
        }
    }

    /// One pass over the tasks whose worktree is on disk; a task with no answer is simply absent.
    /// What is kept for a task no longer among `tasks` is dropped.
    public func diffs(for tasks: [TaskItem], skipping missing: Set<UUID> = []) -> [UUID: DiffStat] {
        let live = Set(tasks.map { Self.key($0.worktreePath, $0.baseBranch) })
        lock.lock()
        for key in entries.keys where !live.contains(key) { entries[key] = nil }
        for key in mergeBases.keys where !live.contains(key) { mergeBases[key] = nil }
        for key in counted.keys where !live.contains(key) { counted[key] = nil }
        for key in timeouts.keys where !live.contains(key) { timeouts[key] = nil }
        lock.unlock()
        var out: [UUID: DiffStat] = [:]
        for task in tasks where !missing.contains(task.id) {
            if let diff = diff(for: task.worktreePath, base: task.baseBranch) { out[task.id] = diff }
        }
        return out
    }

    private static func key(_ worktree: String, _ base: String) -> String { worktree + "\u{0}" + base }

    /// Throws when git ran out of time; any other failure is `nil`, no answer.
    private func read(_ worktree: String, base: String, key: String) throws -> DiffStat? {
        guard let from = try mergeBase(worktree, base: base, key: key),
              let numstat = try Self.ask(["diff", "--numstat", from], in: worktree, git: git) else { return nil }
        var stat = DiffStat(added: 0, removed: 0)
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            // A binary file reports `-` for both counts; `Int` refuses it, which is the skip.
            guard fields.count == 3, let added = Int(fields[0]), let removed = Int(fields[1]) else { continue }
            stat.added += added; stat.removed += removed
        }
        stat.added += try untrackedLines(worktree, key: key)
        return stat
    }

    /// `git.run`, with `nil` for a command git failed — an unknown ref, a path outside a checkout —
    /// which is an answer, and a throw for one that ran out of time, which is not.
    private static func ask(_ args: [String], in directory: String, git: any GitRunning) throws -> String? {
        do { return try git.run(args, in: directory) }
        catch let error as GitError where error.timedOut { throw error }
        catch { return nil }
    }

    /// The cached merge-base while its refs are unchanged, else a fresh one. The refs are stamped
    /// before git is asked, so a ref that moves while it answers is caught on the next pass.
    private func mergeBase(_ worktree: String, base: String, key: String) throws -> String? {
        lock.lock(); let cached = mergeBases[key]; lock.unlock()
        if let cached, cached.refs.areCurrent { return cached.commit }
        guard let files = try Self.refFiles(worktree, base: base, git: git) else { return nil }
        let refs = FileStamps(files)
        let commit = try Self.findMergeBase(worktree, base: base, git: git)
        lock.lock(); mergeBases[key] = MergeBase(refs: refs, commit: commit); lock.unlock()
        return commit
    }

    /// Every file whose change can move the merge-base: `HEAD` (a checkout, a rebase), the branch
    /// it is on (a merge or reset there leaves `HEAD` alone), `<base>` and `origin/<base>`, and
    /// `packed-refs`, where any of those refs may live instead of its own file. A reftable
    /// repository keeps none of them in a file: every update rewrites a stack's `tables.list`
    /// instead — the checkout's own, which holds its HEAD, and the shared one beside
    /// `packed-refs`, which holds the branches. One git call, and `nil` when `worktree` is not a
    /// checkout with a commit.
    private static func refFiles(_ worktree: String, base: String, git: any GitRunning) throws -> [String]? {
        let names = ["HEAD", "packed-refs", "refs/heads/" + base, "refs/remotes/origin/" + base, "reftable/tables.list"]
        guard let answer = try ask(["rev-parse", "--symbolic-full-name", "HEAD"] + names.flatMap { ["--git-path", $0] },
                                   in: worktree, git: git) else { return nil }
        var lines = answer.split(separator: "\n").map(String.init)
        guard lines.count == names.count + 1 else { return nil }
        let head = lines.removeFirst()
        var files = lines.map { FileStamps.absolute($0, in: worktree) }
        // The shared directory, where `packed-refs` is: a branch's ref sits in it, as `<base>`'s
        // does, and so does the shared reftable stack. A detached HEAD is its own file.
        let shared = (files[1] as NSString).deletingLastPathComponent
        files.append(shared + "/reftable/tables.list")
        if head.hasPrefix("refs/") { files.append(shared + "/" + head) }
        return files
    }

    /// Where the checkout left `base`. A review's base is the MR's target, which may exist only as
    /// `origin/<target>`, and a local `main` that has not been pulled in weeks would count work
    /// already merged upstream as the task's own — so when both exist, the later of the two
    /// merge-bases wins.
    private static func findMergeBase(_ worktree: String, base: String, git: any GitRunning) throws -> String? {
        var found: [String] = []
        for ref in [base, "origin/" + base] {
            if let commit = try ask(["merge-base", ref, "HEAD"], in: worktree, git: git), !commit.isEmpty { found.append(commit) }
        }
        guard let first = found.first else { return nil }
        guard found.count == 2, found[0] != found[1] else { return first }
        let localIsOlder = try ask(["merge-base", "--is-ancestor", found[0], found[1]], in: worktree, git: git) != nil
        return localIsOlder ? found[1] : found[0]
    }

    /// Lines in the untracked, non-ignored files, counted the way `git diff` would once they are
    /// added: every newline, plus a final line that lacks one. A NUL byte marks a file as binary,
    /// which `git diff` would not count either, and a symlink is the one line it counts. Stops at `cap`.
    ///
    /// A file whose `lstat` is what it was when it was last counted is not read again: only the
    /// listing and an `lstat` per file are paid for on every pass. It still counts its size against
    /// the byte cap, so the cap stops the count in the same place whether the files were read or
    /// remembered. Files no longer listed are forgotten.
    private func untrackedLines(_ worktree: String, key: String) throws -> Int {
        guard let listing = try Self.ask(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree, git: git) else { return 0 }
        lock.lock(); let before = counted[key] ?? [:]; lock.unlock()
        var after: [String: Counted] = [:]
        var total = 0, bytes = 0
        defer { lock.lock(); counted[key] = after; lock.unlock() }
        // Bounded, so a folder that escaped `.gitignore` is not split into every path it holds only
        // for all those past the cap to be dropped.
        for name in listing.split(separator: "\0", maxSplits: cap.files).prefix(cap.files) {
            let path = String(name), file = worktree + "/" + path
            var info = stat()
            guard lstat(file, &info) == 0 else { continue }
            // Git counts a symlink as one line, its target's path, and never follows it: a link to a
            // large file would get past the caps, and one to a device would never end.
            if info.st_mode & S_IFMT == S_IFLNK { total += 1; continue }
            let size = Int(info.st_size)
            guard info.st_mode & S_IFMT == S_IFREG, size <= Self.untrackedByteLimit else { continue }
            guard bytes + size <= cap.bytes else { break }
            bytes += size
            let stamp = Stamp(info)
            // The stamp is from before the read, so a file that changes during it is read again next time.
            let result = before[path].flatMap { $0.stamp == stamp ? $0 : nil }
                ?? Counted(stamp: stamp, lines: contents(file, size).flatMap(Self.lineCount))
            after[path] = result
            total += result.lines ?? 0
        }
        return total
    }

    /// What a regular file of `size` bytes holds, read without following a link or waiting on a
    /// pipe: the path may have become either since `lstat` looked at it. A file that grew since is
    /// skipped (`nil`) rather than read in full — the caps were checked against `size`, and one
    /// more byte than that is enough to know.
    static func contents(of path: String, size: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try? file.read(upToCount: size + 1), data.count <= size else { return nil }
        return data
    }

    /// Newlines, plus one for a last line without its own; `nil` for an empty or binary file.
    static func lineCount(_ data: Data) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let start = raw.baseAddress, raw.count > 0, memchr(start, 0, raw.count) == nil else { return nil }
            let end = start + raw.count
            var cursor = start, newlines = 0
            while cursor < end, let hit = memchr(cursor, 0x0A, end - cursor) {
                newlines += 1
                cursor = UnsafeRawPointer(hit) + 1
            }
            return newlines + (raw[raw.count - 1] == 0x0A ? 0 : 1)
        }
    }
}
