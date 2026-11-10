import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// The profile, broadcasts and tasks the Operators suites build on: one project, one run, and
/// tasks made by key, so a test reads as the plan it sets up.
enum OperatorFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static let projectId = UUID(uuidString: "0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9")!
    static let runId = UUID(uuidString: "1EB4C0DE-0000-0000-0000-0000000000AA")!

    /// The profile a broadcast froze: Claude on Opus, every slice off, the Oracle as given.
    static func profile(oracle: Bool = true, slices: Slices = .none,
                        instructions: String = "Ask before adding a field a ticket doesn't mention.") -> OperatorProfile {
        var oracleSetting = OracleSetting.standard
        oracleSetting.isOn = oracle
        return OperatorProfile(model: "claude-opus-5-5", reasoning: "high", slices: slices, oracle: oracleSetting, instructions: instructions)
    }

    static func project(id: UUID = projectId, path: String = "/tmp/shop") -> Project {
        .make(id: id, path: path, addedAt: epoch)
    }

    /// A current structured run with explicit Agents rows, task settings and an optional goal.
    static func run(id: UUID = runId, state: OperatorRunState = .active, oracle: Bool = true, slices: Slices = .none,
                    planRevision: Int = 1, agents: [AgentChoice] = OperatorFixtures.agents, taskSettings: TaskSettings = TaskSettings(review: nil, end: .commit, closeWhenDone: false),
                    goal: BroadcastGoal? = nil) -> OperatorRun {
        .make(id: id, profile: profile(oracle: oracle, slices: slices), projects: [projectId], state: state,
              planRevision: planRevision, createdAt: epoch, agents: agents, taskSettings: taskSettings, goal: goal)
    }

    /// The Agents rows of a run set up with them: Claude on Opus, Codex on Astra.
    static let agents = Build.agents
    static let taskSettings = TaskSettings(review: "An adversarial review with /code-review. After 3 rounds of fixes, ask me.",
                                           end: .draftMR)
    static let goal = BroadcastGoal(text: "Every page of the sprint ships.", extraRounds: 2)

    static func operated(_ key: String, _ state: OperatedState = .queued, run: UUID = runId, revision: Int = 1,
                         end: TaskEnd = .commit, dependsOn: [TaskDependency] = [], launched: Bool? = nil) -> OperatedTask {
        .make(run: run, key: key, state: state, end: end, brief: "Do \(key)", dependsOn: dependsOn, revision: revision,
              launched: launched ?? ![.planned, .queued].contains(state), launchedAt: epoch)
    }

    static func task(_ key: String, _ state: OperatedState = .queued, id: UUID = UUID(), run: UUID = runId,
                     revision: Int = 1, end: TaskEnd = .commit, dependsOn: [TaskDependency] = [],
                     launched: Bool? = nil, project: UUID = projectId) -> TaskItem {
        .make(id: id, project: project, title: key, branch: "feat/\(key.lowercased())",
              worktreePath: "/tmp/shop/.worktrees/\(key.lowercased())", model: "opus", reasoning: "high", firstPrompt: "Do \(key)",
              createdAt: epoch,
              operated: operated(key, state, run: run, revision: revision, end: end, dependsOn: dependsOn, launched: launched))
    }

    /// A workspace with the project, `run` and `tasks`.
    static func state(_ run: OperatorRun = run(), _ tasks: [TaskItem]) -> AppState {
        var state = AppState.empty
        state.append(project: project())
        state.runs = [run]
        state.tasks = tasks
        return state
    }

    static func acceptance(_ sha: String = "4f2a91c", check: String = "42 tests passed") -> TaskAcceptance {
        TaskAcceptance(resultSHA: sha, prerequisiteSHAs: [], checkOutput: check, note: nil, at: epoch)
    }
}
