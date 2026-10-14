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

    /// Running: neither gone nor dying. A killed process is not gone at once, and on a loaded host
    /// it can take seconds: it is first "working on exiting" (P_WEXIT), then a zombie until its
    /// parent (launchd, for an orphan) reaps it. `kill(pid, 0)` succeeds throughout, but such a
    /// process runs nothing more.
    private func alive(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return Int32(info.kp_proc.p_stat) != SZOMB && info.kp_proc.p_flag & P_WEXIT == 0
    }

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

    @Test func aJobLeftInTheBackgroundDoesNotOutliveANormalExit() async throws {
        let dir = try GitFixture.folder("agentprocess-bg-")
        let pidFile = dir + "/grandchild.pid", script = dir + "/agent.sh"
        try "/bin/sleep 600 &\necho $! > '\(pidFile)'\nexit 0\n".write(toFile: script, atomically: true, encoding: .utf8)
        let out = try await AgentProcess.run("/bin/sh", [script], environment: [:], in: "/", timeout: .seconds(60))
        #expect(out.status == 0 && !out.timedOut)
        let grandchild = try #require(pid(in: pidFile))
        #expect(!alive(grandchild), "the background job went with the run")
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

/// Not `.blocking`: that trait gives every task a thread of its own, which would hide a run that
/// parks one.
@Suite struct AgentProcessPoolTests {
    /// Runs jobs one at a time on a single thread: a stand-in for a cooperative pool of width one,
    /// which nothing else in the test run shares. A job that blocks holds all of it.
    private final class OneThread: TaskExecutor {
        private let queue = DispatchQueue(label: "AgentProcessPoolTests.OneThread")
        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job), executor = asUnownedTaskExecutor()
            queue.async { job.runSynchronously(on: executor) }
        }
    }

    @Test func manyLongRunsHoldNoPoolThread() async throws {
        // Eight children of one second each, all driven from one thread. A run that parked it until
        // its child ended would make them take eight seconds one after the other; with none parked
        // they overlap and take one. Not the shared pool: the whole-suite run keeps that busy with
        // other tests' work for seconds at a time, which no bound here could tell from parking.
        let executor = OneThread()
        let start = ContinuousClock.now
        try await withTaskExecutorPreference(executor) {
            try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
                for _ in 0..<8 { group.addTask { try await AgentProcess.run("/bin/sleep", ["1"], environment: [:], in: "/", timeout: .seconds(60)) } }
                for try await out in group { #expect(out.status == 0) }
            }
        }
        let took = ContinuousClock.now - start
        #expect(took < .seconds(4), "eight overlapping one-second runs took \(took): a run holds the thread it is driven from")
    }
}
