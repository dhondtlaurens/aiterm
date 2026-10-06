import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The test helper hands a socket over only once a client can connect to it.
@MainActor struct PythonSocketServerTests {
    /// The socket file appears at `bind`; a connect before `listen` is refused. A script that takes
    /// its time between the two is the window a test's first connect once fell into.
    @Test func startReturnsOnceTheScriptListensNotOnceItBinds() async throws {
        let server = try await PythonSocketServer.start(script: """
import socket,sys,time
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
time.sleep(0.5)
s.listen()
time.sleep(30)
""")
        defer { server.stop() }

        #expect(SocketProbe.isLive(path: server.path))
    }

    /// A script that listened and ended at once did listen: its end can come before its line is
    /// read, and is not taken for a script that never got there.
    @Test func aScriptThatListensAndEndsAtOnceStillStarted() async throws {
        let server = try await PythonSocketServer.start(script: """
import socket,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]);s.listen()
""")
        server.stop()
    }

    /// One that ends without listening is refused as soon as it has ended, not at the deadline.
    @Test func aScriptThatEndsWithoutListeningIsRefused() async {
        await #expect(throws: PythonSocketServer.DidNotListen.self) {
            try await PythonSocketServer.start(script: "import sys")
        }
    }
}
