import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// What makes a fixture's git the same on every machine: nothing of the developer's configuration
/// reaches it, and it commits as an identity of its own.
@Suite(.blocking) struct HermeticGitTests {
    private func scratch() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hermetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    /// `git config --list` is what a `commit.gpgSign`, a `core.hooksPath` or an `init.templateDir`
    /// would show up in: the global, system and XDG files are all out of reach, and the home git
    /// would read them from is empty.
    @Test func gitReadsNoConfigurationOfTheDevelopers() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(try GitRunner.hermetic().run(["config", "--list", "--show-origin"], in: directory) == "")
    }

    @Test func gitCommitsAsTheTestsIdentity() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let git = GitRunner.hermetic()
        try git.run(["init", "-q", "-b", "main"], in: directory)
        try git.run(["commit", "--allow-empty", "-m", "init"], in: directory)
        #expect(try git.run(["log", "-1", "--format=%an <%ae>, %cn <%ce>"], in: directory)
                == "AiTerm Tests <tests@aiterm.invalid>, AiTerm Tests <tests@aiterm.invalid>")
    }

    /// A suite run from a git hook inherits the hook's `GIT_DIR`, `GIT_INDEX_FILE`, config
    /// parameters and so on, each of which would send a fixture's commands to the hook's repository
    /// or give them its configuration. None reaches the tests' git; what the runner sets itself does.
    @Test func gitHooksVariablesDoNotReachTheTestsGit() {
        let hook = ["GIT_DIR": "/hook/.git", "GIT_WORK_TREE": "/hook", "GIT_INDEX_FILE": "/hook/.git/index.lock",
                    "GIT_CONFIG_PARAMETERS": "'core.hooksPath=/x'", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "commit.gpgsign",
                    "GIT_CONFIG_VALUE_0": "true", "GIT_TEMPLATE_DIR": "/hook/templates", "PATH": "/usr/bin:/bin"]
        let env = GitRunner.hermetic().commandEnvironment(inheriting: hook, extra: [:])
        for name in hook.keys where name.hasPrefix("GIT_") { #expect(env[name] == nil, "\(name) is inherited") }
        #expect(env["GIT_CONFIG_GLOBAL"] == "/dev/null" && env["GIT_AUTHOR_NAME"] == "AiTerm Tests")
        #expect(env["PATH"] == "/usr/bin:/bin")
    }
}
