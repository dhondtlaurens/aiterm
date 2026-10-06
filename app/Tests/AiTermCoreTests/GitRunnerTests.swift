import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct GitRunnerTests {
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

    /// The app matches git's own wording in stderr (`modified or untracked files`, `not fully
    /// merged`), so git's messages are English whatever locale the person, the runner or a call asks
    /// for — as the C library resolves it, which is what gettext asks.
    @Test func gitAlwaysSpeaksEnglish() throws {
        let (plain, directory) = try fakeGit("/usr/bin/env | /usr/bin/grep -E '^(LC_|LANG)'; /usr/bin/locale")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let dutch = ["LC_ALL": "nl_NL.UTF-8", "LANGUAGE": "nl", "LC_MESSAGES": "fr_FR.UTF-8"]
        let git = GitRunner(git: plain.git, environment: dutch)
        for output in [try git.run(["status"], in: directory),
                       try git.run(["status"], in: directory, timeout: GitRunner.localTimeout, environment: dutch)] {
            let lines = output.split(separator: "\n")
            #expect(lines.contains("LC_MESSAGES=C"))
            #expect(lines.contains(#"LC_MESSAGES="C""#))
            #expect(!lines.contains("LC_ALL=nl_NL.UTF-8") && !lines.contains("LANGUAGE=nl"))
            #expect(!lines.contains { $0.contains("fr_FR") })
        }
    }

    /// Only the messages are forced. An `LC_ALL` is dropped — it would override the character type
    /// the hooks, filters and credential helpers git starts read — and its value kept as that
    /// character type unless there is one already; `LANGUAGE` is dropped, which gettext ignores
    /// once `LC_MESSAGES` is `C`.
    @Test func onlyGitsMessagesAreForcedToEnglish() {
        let moved = GitRunner.englishMessages(["LC_ALL": "nl_NL.UTF-8", "LANGUAGE": "nl", "LC_MESSAGES": "fr_FR.UTF-8", "LANG": "nl_BE.UTF-8"])
        #expect(moved == ["LC_CTYPE": "nl_NL.UTF-8", "LC_MESSAGES": "C", "LANG": "nl_BE.UTF-8"])
        let own = GitRunner.englishMessages(["LC_ALL": "nl_NL.UTF-8", "LC_CTYPE": "en_US.UTF-8"])
        #expect(own == ["LC_CTYPE": "en_US.UTF-8", "LC_MESSAGES": "C"])
        #expect(GitRunner.englishMessages(["LC_CTYPE": "C.UTF-8"]) == ["LC_CTYPE": "C.UTF-8", "LC_MESSAGES": "C"])
        #expect(GitRunner.englishMessages([:]) == ["LC_MESSAGES": "C"])
    }

    /// A test that counts or fails git sees every command, however it was asked: the one with an
    /// environment of its own — `rebaseDefaultBranch`'s scratch `worktree add` — and `runRemote` and
    /// `ask` included. They all end in the one requirement, so none escapes a conformer.
    @Test func everyWayOfAskingEndsInTheOneRequirement() throws {
        let recording = RecordingGitRunner()
        try recording.run(["status"], in: "/")
        _ = try recording.run(["status"], in: "/", timeout: 3, environment: ["GIT_LFS_SKIP_SMUDGE": "1"])
        try recording.runRemote(["fetch"], in: "/")
        #expect(try recording.ask(["rev-parse"], in: "/", none: [1]) == "")
        #expect(recording.calls.map(\.args) == [["status"], ["status"], GitRunner.stallGuard + ["fetch"], ["rev-parse"]])
        #expect(recording.calls.map(\.timeout) == [GitRunner.localTimeout, 3, GitRunner.remoteTimeout, GitRunner.localTimeout])
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

    /// Production passes on everything it inherits. A runner told to ignore some of it — the tests'
    /// — drops those, and still sets its own and a call's, which were not inherited.
    @Test func aRunnerPassesOnWhatItInheritsExceptWhatItIgnores() {
        let inherited = ["GIT_SSH_COMMAND": "ssh -i key", "PATH": "/usr/bin", "LC_ALL": "C"]
        #expect(GitRunner().commandEnvironment(inheriting: inherited, extra: [:])["GIT_SSH_COMMAND"] == "ssh -i key")
        let strict = GitRunner(environment: ["GIT_OWN": "1"], ignoringInherited: { $0.hasPrefix("GIT_") })
        let env = strict.commandEnvironment(inheriting: inherited, extra: ["GIT_CALL": "1"])
        #expect(env["GIT_SSH_COMMAND"] == nil)
        #expect(env["GIT_OWN"] == "1" && env["GIT_CALL"] == "1" && env["PATH"] == "/usr/bin")
        #expect(env["GIT_OPTIONAL_LOCKS"] == "0" && env["GIT_TERMINAL_PROMPT"] == "0" && env["LC_MESSAGES"] == "C")
    }

    /// git asking a remote that never answers, or an `ssh` waiting on a passphrase no one can
    /// type, must not hold a background thread forever. The timeout fails the command, in words
    /// a toast can show as they are.
    @Test func aHungGitTimesOutWithAReadableReason() throws {
        let (git, directory) = try fakeGit("exec sleep 30")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let started = Date()
        #expect { try git.run(["fetch", "--quiet", "origin"], in: directory, timeout: 0.5) } throws: { error in
            GitError.reason(of: error) == "git fetch timed out after 0.5 s" && (error as? GitError)?.timedOut == true
        }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect { try git.run(["-c", "user.name=t", "worktree", "add", "x"], in: directory, timeout: 0.2) } throws: { error in
            GitError.reason(of: error) == "git worktree add timed out after 0.2 s"
        }
    }

    /// A git killed at its deadline has not answered, whatever status it was left with — one that
    /// is also git's "no" included.
    @Test func aQuestionThatTimedOutIsThrownWhateverItsStatus() {
        let git = TimingOutGitRunner(["rev-parse"], code: 1)
        #expect(throws: GitError.self) { try git.ask(["rev-parse", "--verify", "--quiet", "HEAD"], in: "/", none: [1]) }
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
