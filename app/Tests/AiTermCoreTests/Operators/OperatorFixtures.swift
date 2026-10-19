import Foundation
@testable import AiTermCore

/// The profile, broadcasts and tasks the Operators suites build on: one project, one run, and
/// tasks made by key, so a test reads as the plan it sets up.
enum OperatorFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static let projectId = UUID(uuidString: "0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9")!
    static let runId = UUID(uuidString: "1EB4C0DE-0000-0000-0000-0000000000AA")!

    /// The profile a broadcast froze: Claude on Opus, every slice off, the Oracle as given.
    static func profile(oracle: Bool = true, instructions: String = "Ask before adding a field a ticket doesn't mention.") -> OperatorProfile {
        var oracleSetting = OracleSetting.standard
        oracleSetting.isOn = oracle
        return OperatorProfile(model: "claude-opus-5-5", reasoning: "high", oracle: oracleSetting, instructions: instructions)
    }

    static func project(id: UUID = projectId, path: String = "/tmp/shop") -> Project {
        Project(id: id, name: "Shop", path: path, provider: .git, remoteUrl: nil, addedAt: epoch, collapsed: false)
    }

    static func run(id: UUID = runId, state: OperatorRunState = .active, oracle: Bool = true,
                    planRevision: Int = 1) -> OperatorRun {
        OperatorRun(id: id, name: "Sprint 42", profile: profile(oracle: oracle), projectIds: [projectId],
                    prompt: "Implement the sprint.", done: "a commit per item, tests green", state: state,
                    planRevision: planRevision, createdAt: epoch)
    }

    static func operated(_ key: String, _ state: OperatedState = .queued, run: UUID = runId, revision: Int = 1,
                         end: TaskEnd = .commit, dependsOn: [TaskDependency] = [], launched: Bool? = nil) -> OperatedTask {
        let started = launched ?? ![.planned, .queued].contains(state)
        return OperatedTask(runId: run, key: key, state: state, end: end, brief: "Do \(key)", dependsOn: dependsOn,
                            stackedOn: dependsOn.first { $0.kind == .code }?.task, revision: revision,
                            launch: started ? LaunchAttempt(number: 1, requestedAt: epoch) : nil)
    }

    static func task(_ key: String, _ state: OperatedState = .queued, id: UUID = UUID(), run: UUID = runId,
                     revision: Int = 1, end: TaskEnd = .commit, dependsOn: [TaskDependency] = [],
                     launched: Bool? = nil, project: UUID = projectId) -> TaskItem {
        TaskItem(id: id, projectId: project, title: key, branch: "feat/\(key.lowercased())",
                 worktreePath: "/tmp/shop/.worktrees/\(key.lowercased())", baseBranch: "main", jira: nil,
                 agent: .claude, model: "opus", reasoning: "high", firstPrompt: "Do \(key)", appendTicket: false,
                 createdAt: epoch, windowId: nil,
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
