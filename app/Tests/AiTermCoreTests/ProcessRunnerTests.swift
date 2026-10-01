import Darwin
import Foundation
import Testing
@testable import AiTermCore

@Suite struct ProcessRunnerTests {
    /// Well past a pipe's ~64 KB buffer on *both* streams: a runner that read one to EOF before
    /// the other would leave the child blocked writing, and itself blocked reading, forever.
    @Test func bothPipesAreDrainedAtOnce() throws {
        let script = "i=0; while [ $i -lt 4000 ]; do echo 'stdout line padded to make it long enough'; echo 'stderr line padded to make it long enough' >&2; i=$((i+1)); done"
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], timeout: 20)
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout.utf8.count > 128 * 1024)
        #expect(result.stderr.utf8.count > 128 * 1024)
    }

    /// A child that reads its input gets EOF at once instead of waiting on the app.
    @Test func standardInputIsClosed() throws {
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), [], timeout: 5)
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    /// Killing the child does not close its pipes when a grandchild holds them too — an rc file's
    /// `eval "$(tool init)"`, `ssh` under git — so the deadline must not wait for their EOF.
    /// What was read by then is still returned.
    @Test func aTimeoutReturnsWhileAGrandchildHoldsThePipes() throws {
        let started = Date(), timeout: TimeInterval = 0.5
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 30 & echo $!; sleep 60"], timeout: timeout)
        defer { Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map { _ = kill($0, SIGKILL) } }
        // The deadline, then at most `drainGrace` for the pipes, then slack for a loaded machine:
        // the grandchild holds them for thirty seconds, so the bound still tells the two apart.
        #expect(Date().timeIntervalSince(started) < timeout + ProcessRunner.drainGrace + 1.5)
        #expect(result.timedOut)
        #expect(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    }

    /// `terminate()` signals the child's whole process group, so the grandchild above dies with it;
    /// one that ignores SIGTERM does not, and the SIGKILL that follows reaches only the child.
    @Test func aTimeoutReturnsWhileAGrandchildIgnoringTerminateHoldsThePipes() throws {
        let started = Date()
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                           ["-c", "echo $$; (trap '' TERM; exec sleep 30) & sleep 60"], timeout: 0.2)
        defer { Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map { _ = killpg($0, SIGKILL) } }
        // Slack for the grandchild's pipes: `drainGrace` is the deliberate wait, plus room for the
        // rest of the run around it, rather than a bare `< 2` that was flaky at ~0.6s of margin.
        #expect(Date().timeIntervalSince(started) < ProcessRunner.drainGrace + 1.5)
        #expect(result.timedOut)
        #expect(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    }

    /// A child that finished is not waited on for the grandchild it left on its pipes, with or
    /// without a deadline — `ssh`'s ControlPersist master does this to every `git fetch`.
    @Test func aChildThatExitedIsNotWaitedOnForItsGrandchild() throws {
        for timeout: TimeInterval? in [10, nil] {
            let started = Date()
            let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$; sleep 30 &"], timeout: timeout)
            defer { Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map { _ = killpg($0, SIGKILL) } }
            // Slack as above: waiting on the grandchild would take its thirty seconds.
            #expect(Date().timeIntervalSince(started) < ProcessRunner.drainGrace + 1.5)
            #expect(!result.timedOut)
            #expect(result.status == 0)
            #expect(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
        }
    }

    /// A child that inherits `__CFBundleIdentifier` or `XPC_*` checks in with LaunchServices as
    /// AiTerm — that once gave the app a second Dock icon — so the default environment drops them.
    /// This process has them whenever it was started from a terminal app, as the tests are.
    @Test func theDefaultEnvironmentHasNoLaunchIdentity() throws {
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/env"), [], timeout: 5)
        #expect(launchIdentityKeys(in: result.stdout).isEmpty)
        #expect(result.stdout.contains("\nHOME=") || result.stdout.hasPrefix("HOME="))
    }

    @Test func aFailingChildReportsItsStatusAndStderr() throws {
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo nope >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stderr == "nope\n")
    }

    @Test func aMissingExecutableThrows() {
        #expect(throws: (any Error).self) {
            try ProcessRunner.run(URL(fileURLWithPath: "/definitely/not/here"), [])
        }
    }
}

/// The keys in `env`'s output that would make a child check in as AiTerm.
func launchIdentityKeys(in envOutput: String) -> [String] {
    envOutput.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) }
        .filter { $0 == "__CFBundleIdentifier" || $0.hasPrefix("XPC_") || $0.hasPrefix("__XPC_") }
}
