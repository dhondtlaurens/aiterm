import Foundation
import Synchronization

/// The cache behind ``BranchResolver``, ``RemoteResolver`` and ``DefaultBranchResolver``, cheap
/// enough to be asked for every tab and every project on every refresh pass.
///
/// A directory is resolved once and then re-validated by `stat`ing the files git itself rewrites —
/// `HEAD` for the branch, `config` for the remote, the refs a default branch is read from — which is
/// exactly what a `git checkout` or a `git remote add` in a terminal touches, so either shows up with
/// no polling and no watcher. When none of the watched files can be read any more, the checkout
/// moved or went away, so it is probed again rather than answered from the cache. Directories that
/// are not repositories are remembered too, for `negativeTTL` seconds, so a stray tab in `$HOME`
/// does not shell out forever.
///
/// Thread-safe, and meant to be called off the main actor: every miss runs git.
final class WatchedFileCache<Value: Sendable>: Sendable {
    enum Answer { case notARepository, found(Value) }

    /// `stamps` is `nil` for a directory that is not a repository.
    private struct Entry { var stamps: FileStamps?; var value: Value?; var probedAt: Date }

    private let now: @Sendable () -> Date
    private let negativeTTL: TimeInterval
    private let entries = Mutex<[String: Entry]>([:])

    init(now: @escaping @Sendable () -> Date, negativeTTL: TimeInterval) {
        self.now = now; self.negativeTTL = negativeTTL
    }

    /// `locate` names the files to watch in `directory`, or `nil` when it is not a repository; `read`
    /// produces the value from the directory and those files, on a miss and whenever one of them has
    /// changed. The files are stamped before `read` runs, so one that changes while it does is read
    /// again next time. The lock is held throughout, so neither runs twice for one directory at once.
    ///
    /// Either throws when git could not be asked — a timeout, say — which is not an answer and is
    /// never stored: the entry is left as it was, so the next call asks again. Meanwhile the value
    /// already known, if there is one, stands; with none, the error is thrown on to the caller.
    func answer(for directory: String, locate: (String) throws -> [String]?,
                read: (_ directory: String, _ files: [String]) throws -> Value) throws -> Answer {
        try entries.withLock { entries in
            do { return try lookup(directory, in: &entries, locate: locate, read: read) }
            catch {
                if let known = entries[directory]?.value { return .found(known) }
                throw error
            }
        }
    }

    private func lookup(_ directory: String, in entries: inout [String: Entry], locate: (String) throws -> [String]?,
                        read: (String, [String]) throws -> Value) throws -> Answer {
        guard let entry = entries[directory] else { return try resolve(directory, in: &entries, locate: locate, read: read) }
        guard let stamps = entry.stamps, let cached = entry.value else {
            // Known not to be a repository; re-probe once in a while in case it became one.
            return now().timeIntervalSince(entry.probedAt) < negativeTTL
                ? .notARepository : try resolve(directory, in: &entries, locate: locate, read: read)
        }
        let current = FileStamps(stamps.files)
        guard !current.noneExist else { return try resolve(directory, in: &entries, locate: locate, read: read) }
        guard current != stamps else { return .found(cached) }
        // A watched file moved: the checkout changed, but the repository it belongs to did not.
        let value = try read(directory, stamps.files)
        entries[directory] = Entry(stamps: current, value: value, probedAt: now())
        return .found(value)
    }

    private func resolve(_ directory: String, in entries: inout [String: Entry], locate: (String) throws -> [String]?,
                         read: (String, [String]) throws -> Value) throws -> Answer {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
              let files = try locate(directory) else {
            entries[directory] = Entry(stamps: nil, value: nil, probedAt: now())
            return .notARepository
        }
        let stamps = FileStamps(files)
        let value = try read(directory, files)
        entries[directory] = Entry(stamps: stamps, value: value, probedAt: now())
        return .found(value)
    }

    /// `rev-parse --git-path` answers with an absolute path from inside a linked worktree and a
    /// relative one from an ordinary checkout — the same split `Worktrees.excludeFile` handles.
    /// `nil` when `directory` is not a repository (git's `fatal:`, status 128); thrown when git
    /// could not be asked, which is not that.
    static func gitPath(_ name: String, in directory: String, git: any GitRunning) throws -> String? {
        guard let answer = try git.ask(["rev-parse", "--git-path", name], in: directory, none: [128]), !answer.isEmpty else { return nil }
        return FileStamps.absolute(answer, in: directory)
    }
}

/// The ``WatchedFileCache`` check over several files at once, for an answer that depends on more
/// than one — a merge-base on both refs it joins. Each file is stamped in order, `nil` for one
/// that does not exist: a ref kept only in `packed-refs`, or a branch with no remote, is a state
/// like any other, and its file appearing is a change like any other.
struct FileStamps: Equatable {
    /// What a rewrite changes. The date alone misses a second rewrite within the same tick of a
    /// filesystem that keeps whole seconds; git writes a ref to a lock file and renames it into
    /// place, so the new file also has a new inode, and usually a new size.
    struct Stamp: Equatable { let modified: Date, inode: UInt64, size: UInt64 }

    let files: [String]
    private let stamps: [Stamp?]

    init(_ files: [String]) {
        self.files = files
        stamps = files.map(Self.stamp)
    }

    /// Whether every file is as it was when these stamps were taken.
    var areCurrent: Bool { self == FileStamps(files) }

    /// Whether not one of the files exists: the directory they are in is gone, or never was.
    var noneExist: Bool { stamps.allSatisfy { $0 == nil } }

    static func stamp(_ path: String) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        return Stamp(modified: modified, inode: inode, size: size)
    }

    /// One line of a `rev-parse --git-path` answer, made absolute: git answers with an absolute
    /// path from inside a linked worktree and a relative one from an ordinary checkout.
    static func absolute(_ answer: String, in directory: String) -> String {
        answer.hasPrefix("/") ? answer : directory + "/" + answer
    }
}
