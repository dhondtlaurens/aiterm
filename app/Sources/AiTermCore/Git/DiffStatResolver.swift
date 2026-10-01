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
/// `merge-base` calls that find where to start.
///
/// Thread-safe, and meant to be called off the main actor: every miss runs git.
///
/// Unchecked because `entries` and `mergeBases` are `var`s: both are only touched with `lock` held.
public final class DiffStatResolver: @unchecked Sendable {
    private struct Entry { var value: DiffStat?; var at: Date }
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

    private let git: GitRunner
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private let cap: UntrackedCap
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var mergeBases: [String: MergeBase] = [:]

    /// Untracked files bigger than this are skipped rather than read: a line count is not worth a
    /// stray dump or build artifact that escaped `.gitignore`.
    static let untrackedByteLimit = 1 << 20

    public convenience init(git: GitRunner = GitRunner(), now: @escaping @Sendable () -> Date = Date.init, ttl: TimeInterval = 5) {
        self.init(git: git, now: now, ttl: ttl, untrackedCap: .standard)
    }

    init(git: GitRunner = GitRunner(), now: @escaping @Sendable () -> Date = Date.init, ttl: TimeInterval = 5, untrackedCap: UntrackedCap) {
        self.git = git; self.now = now; self.ttl = ttl; self.cap = untrackedCap
    }

    /// The diff of `worktree` against `base`, or `nil` when there is no base, it cannot be found
    /// locally or as `origin/<base>`, or `worktree` is not a checkout.
    public func diff(for worktree: String, base: String) -> DiffStat? {
        guard !worktree.isEmpty, !base.isEmpty else { return nil }
        let key = Self.key(worktree, base)
        lock.lock()
        if let entry = entries[key], now().timeIntervalSince(entry.at) < ttl { lock.unlock(); return entry.value }
        lock.unlock()
        let value = read(worktree, base: base, key: key)
        lock.lock(); entries[key] = Entry(value: value, at: now()); lock.unlock()
        return value
    }

    /// One pass over the tasks whose worktree is on disk; a task with no answer is simply absent.
    /// What is kept for a task no longer among `tasks` is dropped.
    public func diffs(for tasks: [TaskItem], skipping missing: Set<UUID> = []) -> [UUID: DiffStat] {
        let live = Set(tasks.map { Self.key($0.worktreePath, $0.baseBranch) })
        lock.lock()
        for key in entries.keys where !live.contains(key) { entries[key] = nil }
        for key in mergeBases.keys where !live.contains(key) { mergeBases[key] = nil }
        lock.unlock()
        var out: [UUID: DiffStat] = [:]
        for task in tasks where !missing.contains(task.id) {
            if let diff = diff(for: task.worktreePath, base: task.baseBranch) { out[task.id] = diff }
        }
        return out
    }

    private static func key(_ worktree: String, _ base: String) -> String { worktree + "\u{0}" + base }

    private func read(_ worktree: String, base: String, key: String) -> DiffStat? {
        guard let from = mergeBase(worktree, base: base, key: key),
              let numstat = try? git.run(["diff", "--numstat", from], in: worktree) else { return nil }
        var stat = DiffStat(added: 0, removed: 0)
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            // A binary file reports `-` for both counts; `Int` refuses it, which is the skip.
            guard fields.count == 3, let added = Int(fields[0]), let removed = Int(fields[1]) else { continue }
            stat.added += added; stat.removed += removed
        }
        stat.added += untrackedLines(worktree)
        return stat
    }

    /// The cached merge-base while its refs are unchanged, else a fresh one. The refs are stamped
    /// before git is asked, so a ref that moves while it answers is caught on the next pass.
    private func mergeBase(_ worktree: String, base: String, key: String) -> String? {
        lock.lock(); let cached = mergeBases[key]; lock.unlock()
        if let cached, cached.refs.areCurrent { return cached.commit }
        guard let files = Self.refFiles(worktree, base: base, git: git) else { return nil }
        let refs = FileStamps(files)
        let commit = Self.findMergeBase(worktree, base: base, git: git)
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
    private static func refFiles(_ worktree: String, base: String, git: GitRunner) -> [String]? {
        let names = ["HEAD", "packed-refs", "refs/heads/" + base, "refs/remotes/origin/" + base, "reftable/tables.list"]
        guard let answer = try? git.run(["rev-parse", "--symbolic-full-name", "HEAD"] + names.flatMap { ["--git-path", $0] },
                                        in: worktree) else { return nil }
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
    private static func findMergeBase(_ worktree: String, base: String, git: GitRunner) -> String? {
        let found = [base, "origin/" + base].compactMap { ref in
            (try? git.run(["merge-base", ref, "HEAD"], in: worktree)).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let first = found.first else { return nil }
        guard found.count == 2, found[0] != found[1] else { return first }
        let localIsOlder = (try? git.run(["merge-base", "--is-ancestor", found[0], found[1]], in: worktree)) != nil
        return localIsOlder ? found[1] : found[0]
    }

    /// Lines in the untracked, non-ignored files, counted the way `git diff` would once they are
    /// added: every newline, plus a final line that lacks one. A NUL byte marks a file as binary,
    /// which `git diff` would not count either. Stops at `cap`.
    private func untrackedLines(_ worktree: String) -> Int {
        guard let listing = try? git.run(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree) else { return 0 }
        var total = 0, bytes = 0
        // Bounded, so a folder that escaped `.gitignore` is not split into every path it holds only
        // for all those past the cap to be dropped.
        for path in listing.split(separator: "\0", maxSplits: cap.files).prefix(cap.files) {
            let url = URL(fileURLWithPath: worktree).appendingPathComponent(String(path))
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.untrackedByteLimit else { continue }
            guard bytes + size <= cap.bytes else { break }
            bytes += size
            guard let data = try? Data(contentsOf: url), let lines = Self.lineCount(data) else { continue }
            total += lines
        }
        return total
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
