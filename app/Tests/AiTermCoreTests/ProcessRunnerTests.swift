import Darwin
import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct ProcessRunnerTests {
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
        // The grandchild's pid, said once it runs: that is when the run shows something.
        let run = try runUntilStarted("sleep 30 & echo $!; sleep 60", timeout: 0.5,
                                      started: { Int32($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) != nil },
                                      cleanUp: { Int32($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map { _ = kill($0, SIGKILL) } })
        // The deadline, then at most `drainGrace` for the pipes, then slack for a loaded machine:
        // the grandchild holds them for thirty seconds, so the bound still tells the two apart.
        #expect(run.took < run.timeout + ProcessRunner.drainGrace + 1.5)
        #expect(run.result.timedOut)
    }

    /// `terminate()` signals the child's whole process group, so the grandchild above dies with it;
    /// one that ignores SIGTERM does not, and the SIGKILL that follows reaches only the child.
    @Test func aTimeoutReturnsWhileAGrandchildIgnoringTerminateHoldsThePipes() throws {
        // The child's pid, then the grandchild's word that it ignores SIGTERM.
        let run = try runUntilStarted("echo $$; (trap '' TERM; echo trapped; exec sleep 30) & sleep 60", timeout: 0.2,
                                      started: { $0.stdout.contains("trapped") },
                                      cleanUp: { output in
                                          output.stdout.split(separator: "\n").first.flatMap { Int32($0) }.map { _ = killpg($0, SIGKILL) }
                                      })
        // Slack for the grandchild's pipes: `drainGrace` is the deliberate wait, plus room for the
        // rest of the run around it, rather than a bare `< 2` that was flaky at ~0.6s of margin.
        #expect(run.took < run.timeout + ProcessRunner.drainGrace + 1.5)
        #expect(run.result.timedOut)
    }

    /// `script` run by `/bin/sh` with `timeout`, and run again with twice the time while its
    /// output does not show it `started` what the test is about: on a loaded machine a deadline
    /// this short can stop `/bin/sh` before that, and such a run shows nothing either way. What
    /// each run left behind is cleaned up; `took` is the wall time of the run returned.
    private func runUntilStarted(_ script: String, timeout initial: TimeInterval,
                                 started: (ProcessOutput) -> Bool, cleanUp: (ProcessOutput) -> Void,
                                 sourceLocation: SourceLocation = #_sourceLocation)
        throws -> (result: ProcessOutput, timeout: TimeInterval, took: TimeInterval) {
        var timeout = initial
        while true {
            let began = Date()
            let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], timeout: timeout)
            let took = Date().timeIntervalSince(began)
            cleanUp(result)
            if started(result) { return (result, timeout, took) }
            try #require(timeout < TestDeadline.seconds, "the script never got started before its deadline", sourceLocation: sourceLocation)
            timeout *= 2
        }
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
