import Foundation
import Testing
@testable import AiTermCore

@Suite struct GitRunnerTests {
    /// A stand-in for git: a script whose body is `script`, in a directory of its own.
    private func fakeGit(_ script: String) throws -> (git: GitRunner, directory: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("git-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("git")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (GitRunner(git: url.path), directory.path)
    }

    /// A credential helper or `ssh` that git starts must not check in with LaunchServices as AiTerm.
    @Test func gitIsRunWithoutTheLaunchIdentity() throws {
        let (git, directory) = try fakeGit("/usr/bin/env")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let env = try git.run(["status"], in: directory)
        #expect(launchIdentityKeys(in: env).isEmpty)
        #expect(env.contains("GIT_TERMINAL_PROMPT=0"))
    }

    /// The runner's own environment goes on every command, and a call's goes on that one only.
    @Test func environmentIsSetForEveryCommandAndACallsForThatOne() throws {
        let (plain, directory) = try fakeGit("/usr/bin/env")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let git = GitRunner(git: plain.git, environment: ["AITERM_RUNNER": "1"])
        let everyCommand = try git.run(["status"], in: directory)
        #expect(everyCommand.contains("AITERM_RUNNER=1") && !everyCommand.contains("AITERM_CALL="))
        let oneCall = try git.run(["status"], in: directory, timeout: GitRunner.localTimeout, environment: ["AITERM_CALL": "1"])
        #expect(oneCall.contains("AITERM_RUNNER=1") && oneCall.contains("AITERM_CALL=1"))
    }

    /// git asking a remote that never answers, or an `ssh` waiting on a passphrase no one can
    /// type, must not hold a background thread forever. The timeout fails the command, in words
    /// a toast can show as they are.
    @Test func aHungGitTimesOutWithAReadableReason() throws {
        let (git, directory) = try fakeGit("exec sleep 30")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let started = Date()
        #expect { try git.run(["fetch", "--quiet", "origin"], in: directory, timeout: 0.5) } throws: { error in
            GitError.reason(of: error) == "git fetch timed out after 0.5 s"
        }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect { try git.run(["-c", "user.name=t", "worktree", "add", "x"], in: directory, timeout: 0.2) } throws: { error in
            GitError.reason(of: error) == "git worktree add timed out after 0.2 s"
        }
    }

    /// A remote is asked with the remote deadline, and a transfer that has stalled is abandoned
    /// by git itself rather than left to run into it.
    @Test func aRemoteCommandGetsTheRemoteDeadlineAndGivesUpOnAStall() throws {
        let git = RecordingGitRunner()
        let (fake, directory) = try fakeGit("echo \"$@\"")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try git.runRemote(["fetch", "origin"], in: directory)
        #expect(git.calls.map(\.timeout) == [GitRunner.remoteTimeout])
        #expect(git.calls.first?.args == ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=10", "fetch", "origin"])
        #expect(try fake.runRemote(["ls-remote", "origin"], in: directory)
                == "-C \(directory) -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 ls-remote origin")
        #expect(GitRunner.localTimeout == 10 && GitRunner.remoteTimeout == 30)
    }
}

/// A `GitRunner` that records what it was asked to run, and with what deadline, and runs nothing.
///
/// Unchecked because `_calls` is mutable, and held under `lock`; `forwards` is set before any run.
final class RecordingGitRunner: GitRunner, @unchecked Sendable {
    struct Call: Equatable { var args: [String]; var timeout: TimeInterval }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    /// Runs every call for real, after recording it, when set.
    var forwards = false

    override func run(_ args: [String], in dir: String, timeout: TimeInterval = GitRunner.localTimeout) throws -> String {
        lock.withLock { _calls.append(Call(args: args, timeout: timeout)) }
        return forwards ? try super.run(args, in: dir, timeout: timeout) : ""
    }
}
