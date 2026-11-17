import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct WorkerGuardLaunchTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var probe: URL { root.appendingPathComponent("app/.build/debug/AiTermWorkerGuardProbe") }

    @Test func aRealPushChainsTheProjectsHookAndPreservesExistingGitEnvironment() throws {
        let f = try Fixture()
        let script = """
        #!/bin/sh
        /usr/bin/printf '%s' "$GIT_CONFIG_COUNT" > \(AgentCommand.shellQuote(f.folder.appendingPathComponent("count").path))
        git config --get gc.auto > \(AgentCommand.shellQuote(f.folder.appendingPathComponent("existing").path))
        git push origin HEAD
        """
        let result = try f.run(script)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(try f.git.run(["rev-parse", "refs/heads/feat/pay-1"], in: f.origin) == f.sha)
        #expect(try String(contentsOf: f.folder.appendingPathComponent("count"), encoding: .utf8) == "3")
        #expect(try String(contentsOf: f.folder.appendingPathComponent("existing"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        let line = try String(contentsOf: f.folder.appendingPathComponent("project-input"), encoding: .utf8)
        #expect(line.contains(f.sha) && line.contains("refs/heads/feat/pay-1"))
    }
    @Test(arguments: ["git push --no-verify origin HEAD", "git push --force-with-lease origin HEAD", "git push origin HEAD:main"])
    func theLaunchEnvironmentRefusesBypasses(command: String) throws {
        let f = try Fixture()
        let before = try f.git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: f.origin)
        let result = try f.run("#!/bin/sh\n" + command + "\n")
        #expect(result.status != 0)
        #expect(try f.git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: f.origin) == before)
        #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("project-input").path))
    }
    @Test func theHostsProtectionAndTheProjectsOwnRefusalBothPreventAPush() throws {
        let protected = try Fixture(protected: true)
        #expect(try protected.run("#!/bin/sh\ngit push origin HEAD\n").status != 0)
        #expect(!FileManager.default.fileExists(atPath: protected.folder.appendingPathComponent("project-input").path))
        let refused = try Fixture(hookExit: 7)
        #expect(try refused.run("#!/bin/sh\ngit push origin HEAD\n").status != 0)
        #expect(FileManager.default.fileExists(atPath: refused.folder.appendingPathComponent("project-input").path))
        #expect(try refused.git.ask(["rev-parse", "--verify", "refs/heads/feat/pay-1"], in: refused.origin, none: [128]) == nil)
    }

    @Test func aStaleLaunchCannotRestoreAuthorityAfterTakeOver() throws {
        let home = try ScratchFolder.make("aiterm-guard-authority-")
        defer { try? FileManager.default.removeItem(at: home) }
        var scope = WorkerGuard.Scope(task: UUID(), worktree: home.path, branch: "task", remote: "origin", allowsPush: true)
        scope.ownership = 1
        _ = try WorkerGuardLaunch.prepare(scope: scope, home: home, executable: Self.probe)
        scope.ownership = 0
        #expect(throws: (any Error).self) { try WorkerGuardLaunch.prepare(scope: scope, home: home, executable: Self.probe) }
        #expect(WorkerGuardLaunch.recordedScope(task: scope.task, home: home)?.ownership == 1)
    }

    private struct Fixture {
        let folder: URL, config: URL, path: String, origin: String, sha: String
        let git = GitRunner.hermetic()
        let launch: WorkerGuardLaunch.Prepared
        init(protected: Bool = false, hookExit: Int = 0) throws {
            folder = try ScratchFolder.make("aiterm-guard-launch-")
            let repo = try GitFixture.withOrigin(branch: "feat/pay-1")
            path = repo.path; origin = repo.origin; sha = repo.sha
            config = folder.appendingPathComponent("facts.json")
            try JSONEncoder().encode(JSONValue.object(["defaultBranch": "main", "protected": .bool(protected)])).write(to: config)
            let hook = "#!/bin/sh\n/bin/cat > " + AgentCommand.shellQuote(folder.appendingPathComponent("project-input").path) + "\nexit \(hookExit)\n"
            let hookPath = path + "/.git/hooks/pre-push"
            try Data(hook.utf8).write(to: URL(fileURLWithPath: hookPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hookPath)
            launch = try WorkerGuardLaunch.prepare(scope: .init(task: UUID(), worktree: path, branch: "feat/pay-1", remote: origin, allowsPush: true),
                                                   home: folder, executable: WorkerGuardLaunchTests.probe)
        }
        func run(_ script: String) throws -> ProcessOutput {
            let fake = folder.appendingPathComponent("agent.sh")
            try Data(script.utf8).write(to: fake)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            let command = try launch.wrap(AgentCommand.shellQuote(fake.path), agent: .codex)
            var environment = ProcessRunner.inheritedEnvironment.filter { !$0.key.hasPrefix("GIT_") }
            environment.merge(HermeticGit.environment) { _, own in own }
            environment["AITERM_GUARD_PROBE_FACTS"] = config.path
            return try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", command], environment: environment,
                                         in: URL(fileURLWithPath: path), timeout: 30)
        }
    }
}
