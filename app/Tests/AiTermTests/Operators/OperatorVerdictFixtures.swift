import Foundation
import Synchronization
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// P5's worktree and review tab, independent of the other slices' test fixtures.
@MainActor enum OperatorVerdictFixtures {
    static func make(agent: AgentKind = .codex, brief: String = "Operator's extra instructions.",
                     git: (any GitRunning)? = nil) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let checkoutGit = GitRunner.hermetic()
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-verdict-"))
        var run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        run.taskSettings = TaskSettings(review: "Check correctness with /review.", end: .commit)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working)
        task = try TaskCreator.checkOutWorker(task, project: project, start: "main", git: checkoutGit).task
        task.windowId = "w1"
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date(), openedAt: Date())
        task.operated?.extraTabs = [ExtraTab(key: "review", agent: agent, model: "review-model", reasoning: "high",
            modelReason: "Review", brief: brief, launch: LaunchAttempt(number: 1, requestedAt: Date()), role: .review),
            ExtraTab(key: "work", agent: .codex, model: "worker", reasoning: nil, modelReason: "Work", brief: "Work",
            launch: LaunchAttempt(number: 1, requestedAt: Date()))]
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]),
                                      git: git ?? checkoutGit)
        world.show([OperatorServiceFixtures.session("op", window: "wop", tag: run.id),
                    OperatorServiceFixtures.session("s1", tag: task.id, state: .working)])
        return (world, run, task)
    }
}

/// Holds the real commit read off the main thread. A main-thread read fails rather than hanging the test runner.
final class HeldVerdictGit: GitRunning {
    private let gate = Mutex((waiting: 0, open: false))
    var waiting: Int { gate.withLock { $0.waiting } }
    func open() { gate.withLock { $0.open = true } }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if args.first == "rev-parse", args.contains("--end-of-options") {
            guard !Thread.isMainThread else { throw GitError(args: args, code: 1, stderr: "git ran on the main thread") }
            gate.withLock { $0.waiting += 1 }
            while !gate.withLock({ $0.open }) { Thread.sleep(forTimeInterval: 0.002) }
        }
        return try GitRunner.hermetic().run(args, in: dir, timeout: timeout, environment: environment)
    }
}
