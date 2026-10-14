import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct AgentProcessTests {
    /// A script that starts a grandchild sleeping forever, writes its pid, then sleeps itself.
    private func forkingScript() throws -> (script: String, pidFile: String) {
        let dir = try GitFixture.folder("agentprocess-")
        let pidFile = dir + "/grandchild.pid"
        let script = dir + "/agent.sh"
        try "#!/bin/sh\n/bin/sleep 600 &\necho $! > '\(pidFile)'\necho started\n/bin/sleep 600\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        return (script, pidFile)
    }

    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func pid(in file: String) -> pid_t? {
        (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    @Test func runsInTheGivenDirectoryAndReturnsOutput() async throws {
        let dir = try GitFixture.folder("agentprocess-cwd-")
        let out = try await AgentProcess.run("/bin/pwd", [], environment: [:], in: dir, timeout: .seconds(10))
        #expect(out.status == 0)
        // `pwd` says where it really is: /private/var/…, where the fixture's folder says /var/….
        let real = realpath(dir, nil).map { String(cString: $0) }
        #expect(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == real)
    }

    @Test func aTimeoutKillsTheWholeGroup() async throws {
        let (script, pidFile) = try forkingScript()
        let out = try await AgentProcess.run("/bin/sh", [script], environment: [:], in: "/", timeout: .milliseconds(800))
        #expect(out.timedOut)
        let grandchild = try #require(pid(in: pidFile))
        #expect(!alive(grandchild), "the grandchild went with the group")
    }

    @Test func cancellingKillsTheWholeGroupBeforeReturning() async throws {
        let (script, pidFile) = try forkingScript()
        let task = Task { try await AgentProcess.run("/bin/sh", [script], environment: [:], in: "/", timeout: .seconds(60)) }
        await eventually(describing: "the script's grandchild pid") { pid(in: pidFile) != nil }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let grandchild = try #require(pid(in: pidFile))
        #expect(!alive(grandchild))
    }

    @Test func theTerminalsIdentityIsNotPassedOn() async throws {
        setenv("ITERM_SESSION_ID", "w0t0p0:SPIKE", 1)
        defer { unsetenv("ITERM_SESSION_ID") }
        let out = try await AgentProcess.run("/usr/bin/env", [], environment: [:], in: "/", timeout: .seconds(10))
        #expect(!out.stdout.contains("ITERM_SESSION_ID"))
    }

    @Test func outputPastTheLimitIsCut() async throws {
        let out = try await AgentProcess.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero | tr '\\0' x"],
                                             environment: [:], in: "/", timeout: .seconds(20), outputLimit: 1_000_000)
        #expect(out.stdout.utf8.count == 1_000_000)
    }

    @Test func manyLongRunsHoldNoPoolThread() async throws {
        // 64 children sleeping 1 s at once finish in well under 64 s: none parks a cooperative thread.
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
            for _ in 0..<64 { group.addTask { try await AgentProcess.run("/bin/sleep", ["1"], environment: [:], in: "/", timeout: .seconds(30)) } }
            for try await out in group { #expect(out.status == 0) }
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func aGroupThatIgnoresTermIsKilledAfterTheGrace() async throws {
        let dir = try GitFixture.folder("agentprocess-term-")
        let pidFile = dir + "/grandchild.pid", script = dir + "/agent.sh"
        try "trap '' TERM\n/bin/sleep 600 &\necho $! > '\(pidFile)'\nwhile :; do /bin/sleep 1; done\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        let task = Task { try await AgentProcess.run("/bin/sh", [script], environment: [:], in: "/", timeout: .seconds(60)) }
        await eventually(describing: "the script's grandchild pid") { pid(in: pidFile) != nil }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let grandchild = try #require(pid(in: pidFile))
        #expect(!alive(grandchild), "SIGKILL reached what ignored SIGTERM")
    }

    @Test func aChildThatExitsAtOnceIsNotHeldByItsTimeout() async throws {
        let start = ContinuousClock.now
        let out = try await AgentProcess.run("/usr/bin/true", [], environment: [:], in: "/", timeout: .seconds(600))
        #expect(out.status == 0 && !out.timedOut)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aTaskCancelledBeforeItStartsLeavesNothingRunning() async throws {
        let task = Task {
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(1)) }
            return try await AgentProcess.run("/bin/sleep", ["600"], environment: [:], in: "/", timeout: .seconds(600))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
