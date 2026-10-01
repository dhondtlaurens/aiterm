import Darwin
import Foundation
import Synchronization
import Testing
@testable import AiTermCore

@Suite struct HarnessProcessTests {
    @Test func liveRunnerReapsAChildThatIgnoresTerminate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; exec /usr/bin/tail -f /dev/null"
        let result = try HarnessCommandRunner.live.run("/bin/sh", ["-c", script], [:], 0.1)

        #expect(result.timedOut)
        let contents = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(contents))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    /// An agent CLI that opens a browser for sign-in must not do it as AiTerm.
    @Test func liveRunnerPassesNoLaunchIdentity() throws {
        let result = try HarnessCommandRunner.live.run("/usr/bin/env", [], [:], 5)
        #expect(launchIdentityKeys(in: result.stdout).isEmpty)
    }

    /// PI is an npm script (`#!/usr/bin/env node`), and an app opened from the Dock inherits
    /// launchd's `PATH`, which has no Homebrew in it. The interpreter an npm CLI needs sits in
    /// the same `bin` as the CLI, so the runner puts that directory on the child's `PATH`.
    @Test func liveRunnerFindsAnInterpreterNextToTheExecutable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let interpreter = "fake-node-\(UUID().uuidString.prefix(8))"
        let files = [interpreter: "#!/bin/sh\necho interpreted\n", "tool": "#!/usr/bin/env \(interpreter)\n"]
        for (name, contents) in files {
            let url = directory.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let result = try HarnessCommandRunner.live.run(directory.appendingPathComponent("tool").path, [],
                                                       ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], 5)

        #expect(result.status == 0)
        #expect(result.stdout == "interpreted\n")
    }

    /// Locating a CLI is a login shell, most of a second: Settings used to run nine on opening.
    /// A found path is kept while it is still an executable, and forgotten after an install.
    @Test func locationsAreCachedWhileExecutableAndForgottenOnRequest() {
        let lookups = LockedCounter(), executable = LockedFlag(true)
        let runner = HarnessCommandRunner.caching(find: { name in lookups.increment(); return "/bin/\(name)" },
                                                  isExecutable: { _ in executable.value },
                                                  run: { _, _, _, _ in ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false) })
        #expect(runner.locate("pi") == "/bin/pi")
        #expect(runner.locate("pi") == "/bin/pi")
        #expect(lookups.value == 1)

        executable.value = false
        #expect(runner.locate("pi") == "/bin/pi", "a path that is no longer executable is looked up again")
        #expect(lookups.value == 2)

        executable.value = true
        runner.forgetLocations()
        _ = runner.locate("pi")
        #expect(lookups.value == 3)
    }

    /// A missing CLI is not remembered: installed from a terminal, it must show up on the next probe.
    @Test func aMissingCLIIsLookedUpEveryTime() {
        let lookups = LockedCounter()
        let runner = HarnessCommandRunner.caching(find: { _ in lookups.increment(); return nil },
                                                  isExecutable: { _ in true },
                                                  run: { _, _, _, _ in ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false) })
        #expect(runner.locate("pi") == nil)
        #expect(runner.locate("pi") == nil)
        #expect(lookups.value == 2)
    }

    @Test func installingACLIForgetsTheCachedLocations() throws {
        let forgotten = LockedCounter()
        let runner = HarnessCommandRunner(locate: { _ in nil },
                                          run: { _, _, _, _ in ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false) },
                                          forgetLocations: { forgotten.increment() })
        try CLIInstaller.install(.pi, runner: runner)
        #expect(forgotten.value == 1)
    }
}

private final class LockedCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

private final class LockedFlag: Sendable {
    private let flag: Mutex<Bool>
    init(_ flag: Bool) { self.flag = Mutex(flag) }
    var value: Bool {
        get { flag.withLock { $0 } }
        set { flag.withLock { $0 = newValue } }
    }
}
