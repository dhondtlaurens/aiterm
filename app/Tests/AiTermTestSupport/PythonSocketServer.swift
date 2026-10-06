// Debug only: these record issues through swift-testing, whose macros a plain release build of the
// package (the library is built with it, though only tests use it) does not have.
#if DEBUG
import Testing
import Foundation

/// A Unix-socket server a test writes in Python, for one that must behave differently from one
/// connection to the next, send events on its own, or hold a socket open while the test looks away:
/// what `FakeSocketServer`, which serves a single client from a handler, does not do.
///
/// The script is handed the socket path as `sys.argv[1]` and `arguments` after it, and binds and
/// listens itself. `start` returns once the socket exists, so a client that connects first does not
/// have to retry.
///
/// On the main actor because `Process` reports its end through the run loop of the thread that
/// launched it: `waitUntilExit` in `stop()` waits on the thread it is called from, and one launched
/// from a pool thread's run loop, which nobody turns, never wakes it.
@MainActor
final class PythonSocketServer {
    let path: String
    private let process = Process()

    private init(script: String, arguments: [String]) {
        // Short and in /tmp: a socket path is limited to about a hundred bytes.
        path = "/tmp/at-\(UUID().uuidString.prefix(8)).sock"
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, path] + arguments
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
    }

    static func start(script: String, arguments: [String] = []) async throws -> PythonSocketServer {
        let server = PythonSocketServer(script: script, arguments: arguments)
        try server.process.run()
        guard await eventually(describing: "the Python server to bind \(server.path)", { FileManager.default.fileExists(atPath: server.path) }) else {
            server.stop()
            throw DidNotBind(path: server.path)
        }
        return server
    }

    struct DidNotBind: Error { let path: String }

    var isRunning: Bool { process.isRunning }

    /// Ends the script and removes its socket. Safe to call twice.
    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: path)
    }
}
#endif
