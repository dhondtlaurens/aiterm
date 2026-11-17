import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A file AiTerm reads from a fix's clone, which the agent can write: only a regular file, never
/// through a symlink, never by waiting on a FIFO, and only up to a limit — the clone's settings
/// (`FixClone.settings(at:)`) and the Oracle's answer file.
enum RegularFile {
    enum Entry: Equatable { case absent, bytes(Data) }

    /// `.absent` when nothing is at `path`; the bytes of a regular file of at most `limit` bytes;
    /// nil for anything else there — a symlink, a FIFO, a folder, a larger file, or one that
    /// cannot be read.
    static func read(_ path: String, limit: Int) -> Entry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Again on what was opened: the file may have been swapped since the `lstat`.
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { return .bytes(data) }
            data.append(buffer, count: count)
            if data.count > limit { return nil }
        }
    }
}
