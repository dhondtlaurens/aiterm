import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// Each installed fixer on a real conflict: Look proposes, Apply resolves in the clone, the checks
/// pass, landing moves the branch. Uses quota and the vendor's API, so it runs only with
/// `AITERM_LIVE_FIXER=1`.
///
/// A real model may decline (`.none`), which fails the test on purpose: the conflict is trivial, so
/// a decline is a finding, not noise.
@Suite(.blocking, .enabled(if: ProcessInfo.processInfo.environment["AITERM_LIVE_FIXER"] == "1"))
struct FixLiveTests {
    @Test(arguments: FixerAgent.allCases)
    func resolvesARealConflict(_ agent: FixerAgent) async throws {
        guard let cli = HarnessCommandRunner.live.locate(agent.agent.harness.executable) else {
            try Test.cancel("\(agent.agent.harness.executable) is not installed, so \(agent) was not checked.")   // never returns: the case shows as cancelled
        }
        let git = GitRunner.hermetic()
        let world = try ConflictWorld(git: git); defer { world.removeAll() }
        let project = Project(id: UUID(), name: "live", path: world.repo, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let pipeline = FixPipeline.live(git: git, workflow: TaskWorkflow(git: git), project: project,
                                        model: { _ in (ModelSettings.load(for: agent.agent)?.model ?? "", nil) }, locate: { _ in cli })
        let request = FixRequest(title: "Couldn’t create the review.", reason: "Rebasing hit a conflict.", detail: nil,
                                 projectPath: world.repo, branch: "feat/x", recreateRebase: true, retry: .createReview)
        let before = try world.sha("feat/x", in: world.repo)
        do {
            let clone = try await pipeline.prepare(request); defer { clone.remove() }
            print("LIVE \(agent): clone at \(clone.path)")
            let clock = ContinuousClock()
            let lookStart = clock.now
            let (look, session) = try await pipeline.look(agent, clone, request)
            print("LIVE \(agent): look took \(clock.now - lookStart)")
            guard case .fix(let proposal) = look else { Issue.record("\(agent): no fix: \(look)"); return }
            print("LIVE \(agent): headline “\(proposal.headline)”")
            let applyStart = clock.now
            let checked = try await pipeline.apply(agent, clone, proposal, session)
            print("LIVE \(agent): apply took \(clock.now - applyStart)")
            // No straggler: a tool process that left the agent's process group escaped its sweep.
            // The clone's path is unique, so any process naming it is this run's.
            let stragglers = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-fl", clone.path], timeout: 10)
            #expect(stragglers.status == 1 && stragglers.stdout.isEmpty,
                    "\(agent) left processes running after Apply: \(stragglers.stdout)")
            let landing = try await pipeline.land(clone, checked)
            let repo = world.repo
            #expect(try world.sha("refs/heads/feat/x", in: repo) == landing.new, "the branch moved to the fix")
            #expect(landing.old == before, "the old tip is the one from before the run")
            #expect(try world.sha("refs/aiterm/backup/feat/x", in: repo) == landing.old, "the backup keeps the old tip")
            #expect(landing.new != landing.old)
            let config = try git.run(["show", landing.new + ":config.ts"], in: repo)
            #expect(!config.isEmpty, "config.ts has content")
            for marker in ["<<<<<<<", "=======", ">>>>>>>"] { #expect(!config.contains(marker), "config.ts holds no \(marker)") }
            let origin = try world.sha("refs/remotes/origin/feat/x", in: repo)
            _ = try git.run(["merge-base", "--is-ancestor", origin, landing.new], in: repo)   // throws unless it is
            for dir in ["rebase-merge", "rebase-apply"] {
                #expect(!FileManager.default.fileExists(atPath: repo + "/.git/" + dir), "no \(dir) left in the project")
            }
        } catch let refusal as FixRefusal {
            Issue.record("\(agent): \(refusal.errorDescription ?? "\(refusal)")")
        }
    }
}
