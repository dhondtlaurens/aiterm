import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// What makes a fixture's git the same on every machine: nothing of the developer's configuration
/// reaches it, and it commits as an identity of its own.
@Suite struct HermeticGitTests {
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
}
