import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A git that holds every read of the repository's branches until `open()`, and answers them with `branches`.
/// `waiting` counts the reads held, so a test acts once every call it started is parked on git.
final class HeldBranchesGit: GitRunning {
    private let gate = Mutex((waiting: 0, open: false))
    private let branches: [String]
    var waiting: Int { gate.withLock { $0.waiting } }
    init(branches: [String] = []) { self.branches = branches }
    func open() { gate.withLock { $0.open = true } }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        guard args.first == "for-each-ref", args.contains("refs/heads") else { throw GitError(args: args, code: 128, stderr: "not a repository") }
        gate.withLock { $0.waiting += 1 }
        while !gate.withLock({ $0.open }) { Thread.sleep(forTimeInterval: 0.002) }
        return branches.map { "refs/heads/" + $0 }.joined(separator: "\n")
    }
}

/// `create_task` reads the repository's branches off the main actor; whatever happens meanwhile, a key
/// makes one task and no two tasks share a branch.
@MainActor @Suite struct OperatorBranchRaceTests {
    let project = OperatorServiceFixtures.project()

    func makeWorld(_ git: HeldBranchesGit) throws -> (OperatorWorld, OperatorRun) {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]), git: git) { $0.milestone = .m1 }
        world.link.attached = false
        return (world, run)
    }

    func create(_ world: OperatorWorld, _ run: OperatorRun, _ key: String, ticket: String = "PLUTO-231") -> Task<ToolAnswer, Never> {
        Task {
            await world.call(run.id, "create_task", ["key": .string(key), "title": "Gift card", "brief": "Build it.", "project": "Shop",
                                                      "ticket": .string(ticket), "agent": "codex", "model": "gpt-6-astra",
                                                      "modelReason": "Codex for the API."])
        }
    }

    @Test func twoOverlappingCallsWithOneKeyMakeOneTask() async throws {
        let git = HeldBranchesGit()
        let (world, run) = try makeWorld(git)
        let first = create(world, run, "PLUTO-231/api"), second = create(world, run, "PLUTO-231/api")
        #expect(await eventually(describing: "both calls to be reading the branches") { git.waiting == 2 })
        git.open()
        let answers = [await first.value, await second.value]
        #expect(world.state.tasks.count == 1)
        #expect(answers.compactMap { $0.value?["created"]?.boolValue }.sorted { !$0 && $1 } == [false, true])
        #expect(Set(answers.compactMap { $0.value?["task"]?.stringValue }) == [world.state.tasks[0].id.uuidString])
    }

    @Test func twoOverlappingCallsForOneTicketGetTwoBranches() async throws {
        let git = HeldBranchesGit(branches: ["main", "feat/pluto-231-gift-card"])
        let (world, run) = try makeWorld(git)
        let api = create(world, run, "PLUTO-231/api"), ui = create(world, run, "PLUTO-231/ui")
        #expect(await eventually(describing: "both calls to be reading the branches") { git.waiting == 2 })
        git.open()
        _ = await (api.value, ui.value)
        // The repository has the first name; the two tasks share neither it nor each other's.
        #expect(Set(world.state.tasks.map(\.branch)) == ["feat/pluto-231-gift-card-2", "feat/pluto-231-gift-card-3"])
        #expect(world.state.tasks.count == 2)
    }

    /// A Pause or an End that lands while the branches are read: the call says which, and makes no task.
    @Test(arguments: [(OperatorRunState.paused, "The person paused this broadcast. Wait until they resume it."),
                      (.stopped, "This broadcast has ended; its tools no longer act.")])
    func aPauseOrAnEndWhileTheBranchesAreReadStopsTheTask(_ change: OperatorRunState, _ refusal: String) async throws {
        let git = HeldBranchesGit()
        let (world, run) = try makeWorld(git)
        let call = create(world, run, "PLUTO-231/api")
        #expect(await eventually(describing: "the call to be reading the branches") { git.waiting == 1 })
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.intent = change; $0.state = change } }
        git.open()
        #expect(await call.value.message == refusal)
        #expect(world.state.tasks.isEmpty)
    }
}
