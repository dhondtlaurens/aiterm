import Foundation
import AiTermCore

/// An `AppState` holding a project, broadcasts and the tasks operators made in them, for the tests
/// of parts F and G — slots, stalls, publication. The one place those tests build part C's types,
/// with C's initialisers (`OperatorModels.swift`).
struct OperatedWorld {
    var state = AppState()
    let project: Project
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    init(projectPath: String = "/tmp/operated-world", remoteUrl: String = "git@git.example.net:web/acme-web.git") {
        project = .make(name: "acme-web", path: projectPath, provider: .gitlab, remoteUrl: remoteUrl, addedAt: createdAt)
        state.append(project: project)
    }

    /// The profile its broadcasts froze: the Oracle off, so nothing is challenged, and the Merge slice on, so a
    /// merge end merges.
    static let profile = OperatorProfile(model: "claude-opus-5-5", reasoning: "high", slices: Slices(merge: true),
                                         oracle: OracleSetting(isOn: false, agent: .codex, model: "gpt-6-astra", reasoning: "medium"),
                                         instructions: "You keep changes small.")

    /// A structured broadcast in `runState`, made `age` seconds after `createdAt`, with frozen slices.
    @discardableResult
    mutating func addRun(_ runState: OperatorRunState = .active, age: TimeInterval = 0, slices: Slices = Self.profile.slices,
                         agents: [AgentChoice] = OperatorUIFixtures.agents, taskSettings: TaskSettings = TaskSettings(review: nil, end: .commit, closeWhenDone: false), goal: BroadcastGoal? = nil) -> UUID {
        var profile = Self.profile
        profile.slices = slices
        let run = OperatorRun.make(profile: profile, projects: [project.id], state: runState,
                                   createdAt: createdAt.addingTimeInterval(age), agents: agents, taskSettings: taskSettings, goal: goal)
        state.runs.append(run)
        return run.id
    }

    /// A task an operator made in `run`, keyed and titled `key`; its id. A `code` dependency makes it
    /// stacked on that parent. A task past `queued` has been launched once.
    @discardableResult
    mutating func addTask(_ key: String, run: UUID, state taskState: OperatedState = .queued, end: TaskEnd = .commit,
                          dependsOn: [TaskDependency] = [], branch: String? = nil, acceptedSHA: String? = nil) -> UUID {
        let id = UUID()
        let branchName = branch ?? "feat/" + BranchNaming.slug(key)
        let acceptance = acceptedSHA.map {
            TaskAcceptance(resultSHA: $0, prerequisiteSHAs: [], checkOutput: "12 passed", note: nil, at: createdAt)
        }
        let operated = OperatedTask.make(run: run, key: key, state: taskState, end: end, dependsOn: dependsOn,
                                         acceptance: acceptance, launched: ![.planned, .queued].contains(taskState),
                                         launchedAt: createdAt)
        state.tasks.append(.make(id: id, project: project.id, title: key, branch: branchName,
                                 worktreePath: project.path + "/.worktrees/" + BranchNaming.worktreeSlug(branch: branchName),
                                 model: "claude-opus-5-5", firstPrompt: "Do \(key).", createdAt: createdAt, operated: operated))
        return id
    }

    func operated(_ id: UUID) -> OperatedTask? { state.tasks.first { $0.id == id }?.operated }
}
