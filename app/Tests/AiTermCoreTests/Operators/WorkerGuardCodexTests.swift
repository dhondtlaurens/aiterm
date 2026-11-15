import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking, .enabled(if: ProcessInfo.processInfo.environment["AITERM_CODEX_GUARD_PROBE"] == "1"))
struct WorkerGuardCodexTests {
    @Test(arguments: [false, true]) func realCodexRetainsTheGuardWhenItsSandboxIsBypassed(unsafe: Bool) throws {
        let folder = try ScratchFolder.make("aiterm-codex-guard-")
        let repo = try GitFixture.withOrigin(branch: "feat/pay-1")
        let scope = WorkerGuard.Scope(task: UUID(), worktree: repo.path, branch: "feat/pay-1", remote: repo.origin, allowsPush: true)
        let guardLaunch = try WorkerGuardLaunch.prepare(scope: scope, home: folder, executable: WorkerGuardLaunchTests.probe)
        let agent = folder.appendingPathComponent("codex-agent.sh")
        let command = try guardLaunch.wrap(AgentCommand.shellQuote(agent.path), agent: .codex)
        let facts = folder.appendingPathComponent("facts.json")
        try Data(#"{"defaultBranch":"main","protected":false}"#.utf8).write(to: facts)
        let root = WorkerGuardLaunchTests.root
        var environment = ProcessRunner.inheritedEnvironment.filter { !$0.key.hasPrefix("GIT_") }
        environment.merge(HermeticGit.environment) { _, own in own }
        environment["AITERM_GUARD_PROBE_FACTS"] = facts.path
        let result = try ProcessRunner.run(root.appendingPathComponent("daemon/.venv/bin/python"),
            [root.appendingPathComponent("daemon/tools/worker_guard_check.py").path, "--launcher", command,
             "--agent", agent.path, "--cwd", repo.path, "--command", unsafe ? "git push --no-verify origin HEAD" : "git push origin HEAD"],
            environment: environment, in: folder, timeout: 90)
        #expect(result.status == 0, "\(result.stdout)\n\(result.stderr)")
        let tip = try GitRunner.hermetic().ask(["rev-parse", "--verify", "refs/heads/feat/pay-1"], in: repo.origin, none: [128])
        #expect(tip == (unsafe ? nil : repo.sha), "\(result.stdout)")
        if unsafe { #expect(result.stdout.contains("skip the push hook"), "\(result.stdout)") }
    }
}
