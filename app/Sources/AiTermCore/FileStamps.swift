import Foundation
import Darwin

/// File versions shared by persistence, catalogues and git caches: inode, modification time and
/// size distinguish atomic replacements and edits in place. A missing file has no stamp; appearing
/// or disappearing therefore invalidates an aggregate just like a rewrite.
struct FileStamps: Equatable, Sendable {
    /// What a rewrite of a file changes: the modification time to the nanosecond, the size, and the
    /// inode, which a file replaced rather than edited has a new one of — git writes a ref to a lock
    /// file and renames it into place. Two stamps are equal when those are: the version persistence,
    /// catalogues and git caches compare. The change time is kept too, for a reader that must also
    /// catch a rewrite that puts the old modification time back (`touch -r`, an unpacked archive),
    /// which still moves it and no one can set (`isSameWrite`); a `chmod` moves it as well, which is
    /// why the version leaves it aside. The one stamp of a file, for every reader.
    struct Stamp: Equatable, Sendable {
        /// Both times in nanoseconds since the epoch.
        let modified: Int, changed: Int, size: UInt64, inode: UInt64

        static func == (a: Stamp, b: Stamp) -> Bool { a.modified == b.modified && a.size == b.size && a.inode == b.inode }

        /// The same version, and not touched since either: the change time agrees too.
        func isSameWrite(as other: Stamp) -> Bool { self == other && changed == other.changed }

        init(_ info: stat) {
            modified = info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec
            changed = info.st_ctimespec.tv_sec * 1_000_000_000 + info.st_ctimespec.tv_nsec
            size = UInt64(info.st_size); inode = UInt64(info.st_ino)
        }
    }

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
        return Stamp(info)
    }

    /// One line of a `rev-parse --git-path` answer, made absolute: git answers with an absolute
    /// path from inside a linked worktree and a relative one from an ordinary checkout.
    static func absolute(_ answer: String, in directory: String) -> String {
        answer.hasPrefix("/") ? answer : directory + "/" + answer
    }
}
