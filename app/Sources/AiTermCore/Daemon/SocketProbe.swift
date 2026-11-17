import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Answers "is a daemon listening on this Unix socket right now?" — a bare `connect()`, with no
/// request sent and no reader thread started, so it is cheap enough to run on a timer.
public enum SocketProbe {
    public static func isLive(path: String) -> Bool {
        connected(to: path) { _ in true } ?? false
    }

    /// The pid of the process listening on the socket, or `nil` when nothing accepts there. The
    /// kernel reports it for the connection itself (`LOCAL_PEERPID`), so it names whoever holds the
    /// socket now, whatever its command line says.
    public static func listenerPid(path: String) -> pid_t? {
        connected(to: path) { s in
            var pid: pid_t = 0
            var length = socklen_t(MemoryLayout<pid_t>.size)
            return getsockopt(s, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : nil
        }
    }

    /// Runs `body` on a socket connected to `path`, closed when it returns; `nil` when none connects.
    private static func connected<T>(to path: String, _ body: (Int32) -> T?) -> T? {
        guard let address = try? UnixSocketAddress(path: path) else { return nil }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { Darwin.close(s) }
        guard address.withSockaddr({ Darwin.connect(s, $0, $1) }) == 0 else { return nil }
        return body(s)
    }
}
