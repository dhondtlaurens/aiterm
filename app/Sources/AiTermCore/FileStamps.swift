import Foundation
import Darwin

/// File versions shared by persistence, catalogues and git caches: inode, modification time and
/// size distinguish atomic replacements and edits in place. A missing file has no stamp; appearing
/// or disappearing therefore invalidates an aggregate just like a rewrite.
struct FileStamps: Equatable, Sendable {
    /// What a rewrite changes. The date alone misses a second rewrite within the same tick of a
    /// filesystem that keeps whole seconds; git writes a ref to a lock file and renames it into
    /// place, so the new file also has a new inode, and usually a new size.
    struct Stamp: Equatable, Sendable { let modified: Date, inode: UInt64, size: UInt64 }

    let files: [String]
    private let stamps: [Stamp?]

    init(_ files: [String]) {
        self.files = files
        stamps = files.map(Self.stamp)
    }

    /// Stamps taken one at a time, each just before its file was read: for a walk that learns which
    /// files its answer depends on only as it reads them (`SkillCatalog`).
    init(files: [String], stamps: [Stamp?]) {
        self.files = files
        self.stamps = stamps
    }

    /// Whether every file is as it was when these stamps were taken.
    var areCurrent: Bool { self == FileStamps(files) }

    /// Whether not one of the files exists: the directory they are in is gone, or never was.
    var noneExist: Bool { stamps.allSatisfy { $0 == nil } }

    static func stamp(_ path: String) -> Stamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        // Subtract the epoch before adding nanoseconds, preserving Foundation's Date precision.
        let seconds = Double(info.st_mtimespec.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate
        let modified = Date(timeIntervalSinceReferenceDate: seconds + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return Stamp(modified: modified, inode: UInt64(info.st_ino), size: UInt64(info.st_size))
    }

    /// One line of a `rev-parse --git-path` answer, made absolute: git answers with an absolute
    /// path from inside a linked worktree and a relative one from an ordinary checkout.
    static func absolute(_ answer: String, in directory: String) -> String {
        answer.hasPrefix("/") ? answer : directory + "/" + answer
    }
}
