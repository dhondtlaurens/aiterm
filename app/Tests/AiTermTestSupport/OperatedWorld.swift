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
        project = Project(id: UUID(), name: "acme-web", path: projectPath, provider: .gitlab,
                          remoteUrl: remoteUrl, addedAt: createdAt, collapsed: false)
        state.append(project: project)
    }

    /// The profile its broadcasts froze: the Oracle off, so nothing is challenged, and the Merge slice on, so a
    /// merge end merges.
    static let profile = OperatorProfile(model: "claude-opus-5-5", reasoning: "high", slices: Slices(merge: true),
                                         oracle: OracleSetting(isOn: false, agent: .codex, model: "gpt-6-astra", reasoning: "medium"),
                                         instructions: "You keep changes small.")

    /// A new broadcast in `runState`, made `age` seconds after `createdAt`, its slices frozen as `slices`; its id.
    @discardableResult
    mutating func addRun(_ runState: OperatorRunState = .active, age: TimeInterval = 0, slices: Slices = Self.profile.slices) -> UUID {
        var profile = Self.profile
        profile.slices = slices
        let run = OperatorRun(id: UUID(), name: "Sprint 42", profile: profile, projectIds: [project.id],
                              prompt: "Implement the sprint.", state: runState,
                              planRevision: 1, createdAt: createdAt.addingTimeInterval(age))
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
        var task = TaskItem(id: id, projectId: project.id, title: key, branch: branchName,
                            worktreePath: project.path + "/.worktrees/" + BranchNaming.worktreeSlug(branch: branchName),
                            baseBranch: "main", jira: nil, agent: .claude, model: "claude-opus-5-5", reasoning: nil,
                            firstPrompt: "Do \(key).", appendTicket: false, createdAt: createdAt, windowId: nil)
        let acceptance = acceptedSHA.map {
            TaskAcceptance(resultSHA: $0, prerequisiteSHAs: [], checkOutput: "12 passed", note: nil, at: createdAt)
        }
        let launched = ![.planned, .queued].contains(taskState)
        task.operated = OperatedTask(runId: run, key: key, state: taskState, end: end, brief: "Do \(key).",
                                     dependsOn: dependsOn, stackedOn: dependsOn.first { $0.kind == .code }?.task,
                                     revision: 1, acceptance: acceptance,
                                     launch: launched ? LaunchAttempt(number: 1, requestedAt: createdAt) : nil)
        state.tasks.append(task)
        return id
    }

    func operated(_ id: UUID) -> OperatedTask? { state.tasks.first { $0.id == id }?.operated }
}
