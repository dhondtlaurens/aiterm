import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct VerifySandboxTests {
    @Test func writesInsideTheCloneAndNowhereElse() async throws {
        let dir = try GitFixture.folder("verify-")
        // Under the home folder, not the temporary directory: the profile allows the latter.
        let outside = NSHomeDirectory() + "/Library/Caches/aiterm-verify-outside-" + UUID().uuidString + ".txt"
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try await VerifySandbox.run("touch inside.txt", in: dir, timeout: .seconds(20))
        #expect(FileManager.default.fileExists(atPath: dir + "/inside.txt"))
        await #expect(throws: FixRefusal.self) { try await VerifySandbox.run("touch '\(outside)'", in: dir, timeout: .seconds(20)) }
        #expect(!FileManager.default.fileExists(atPath: outside))
    }

    @Test func hasNoNetwork() async throws {
        let dir = try GitFixture.folder("verify-net-")
        await #expect(throws: FixRefusal.verifyFailed("curl -sS --max-time 5 https://example.com", status: 6)) {
            try await VerifySandbox.run("curl -sS --max-time 5 https://example.com", in: dir, timeout: .seconds(20))
        }
    }

    /// A positive control for `hasNoNetwork`, which passes offline too: here it is the sandbox that
    /// refuses a loopback connection (EPERM, exit 42), not a closed port (ECONNREFUSED, exit 0).
    @Test func theSandboxItselfRefusesALoopbackConnection() async throws {
        let dir = try GitFixture.folder("verify-loopback-")
        try """
        import socket, sys
        try:
            socket.create_connection(("127.0.0.1", 9), 2)
        except PermissionError:
            sys.exit(42)
        except OSError:
            sys.exit(0)
        """.write(toFile: dir + "/probe.py", atomically: true, encoding: .utf8)
        await #expect(throws: FixRefusal.verifyFailed("python3 probe.py", status: 42)) {
            try await VerifySandbox.run("python3 probe.py", in: dir, timeout: .seconds(20))
        }
    }

    /// `open` asks LaunchServices to start the app, which would then run unconfined.
    @Test func cannotStartAnAppThroughLaunchServices() async throws {
        let dir = try GitFixture.folder("verify-open-")
        defer { _ = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/pkill"), ["-x", "Calculator"]) }
        await #expect(throws: FixRefusal.self) {
            try await VerifySandbox.run("open -g -j -b com.apple.Calculator", in: dir, timeout: .seconds(20))
        }
    }

    /// What a verify command is for keeps working under the login shell.
    @Test func gitAndNodeStillRun() async throws {
        let dir = try GitFixture.folder("verify-tools-")
        try await VerifySandbox.run("git --version && node --version", in: dir, timeout: .seconds(20))
    }

    /// The profile is a string; a path with a quote must not break out of it.
    @Test func aQuoteInThePathIsEscaped() {
        let profile = VerifySandbox.profile(writableRoot: #"/tmp/a "b"/c"#)
        #expect(profile.contains(#"(subpath "/tmp/a \"b\"/c")"#))
    }
}
