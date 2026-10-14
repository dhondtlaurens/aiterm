import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// Each installed fixer on a real conflict: Look proposes, Apply resolves in the clone, the checks
/// pass, landing moves the branch. Uses quota and the vendor's API, so it runs only with
/// `AITERM_LIVE_FIXER=1`.
@Suite(.blocking, .enabled(if: ProcessInfo.processInfo.environment["AITERM_LIVE_FIXER"] == "1"))
struct FixLiveTests {
    @Test(arguments: FixerAgent.allCases)
    func resolvesARealConflict(_ agent: FixerAgent) async throws {
        guard let cli = HarnessCommandRunner.live.locate(agent.agent.harness.executable) else {
            print("LIVE \(agent): \(agent.agent.harness.executable) is not installed, skipped")
            return
        }
        let git = GitRunner.hermetic()
        let world = try ConflictWorld(git: .hermetic()); defer { world.removeAll() }
        let project = Project(id: UUID(), name: "live", path: world.repo, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let pipeline = FixPipeline.live(git: git, workflow: TaskWorkflow(git: git), project: project,
                                        model: { _ in (ModelSettings.load(for: agent.agent)?.model ?? "", nil) }, locate: { _ in cli })
        let request = FixRequest(title: "Couldn’t create the review.", reason: "Rebasing hit a conflict.", detail: nil,
                                 projectPath: world.repo, branch: "feat/x", recreateRebase: true, retry: .createReview)
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
            try await pipeline.apply(agent, clone, proposal, session)
            print("LIVE \(agent): apply took \(clock.now - applyStart)")
            let landing = try await pipeline.land(clone)
            #expect(landing.new != landing.old)
        } catch let refusal {
            Issue.record("\(agent): \(refusal.errorDescription ?? "\(refusal)")")
        }
    }
}
