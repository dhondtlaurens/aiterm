import Foundation
import Synchronization
import Darwin

/// Reads a pipe to EOF on a thread of its own, keeping the first `limit` bytes and dropping the
/// rest (still reading, so the child never blocks on a full pipe), and saying whether it dropped any.
final class PipeDrain: Sendable {
    private let data = Mutex(Data())
    private let dropped = Mutex(false)

    init(fd: Int32, limit: Int, onEnd: @escaping @Sendable () -> Void) {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                let kept = data.withLock { d in
                    let room = limit - d.count
                    if room > 0 { d.append(contentsOf: buffer[..<min(n, room)]) }
                    return max(0, min(n, room))
                }
                if kept < n { dropped.withLock { $0 = true } }
            }
            onEnd()
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func text() -> String { data.withLock { String(decoding: $0, as: UTF8.self) } }

    /// Whether anything past `limit` was read and dropped.
    var truncated: Bool { dropped.withLock { $0 } }
}
