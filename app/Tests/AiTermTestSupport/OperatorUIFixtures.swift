import Foundation
@testable import AiTermCore

/// The Operator's broadcasts and the tasks they drive, for the sidebar's, the sheets' and the board's
/// tests — built here, in one place, so a change to the operator types' initialisers is one edit.
/// The example is the design's: "Newsletter signup" over pluto-cms and pluto-web.
enum OperatorUIFixtures {
    static let epoch = Date(timeIntervalSince1970: 0)

    /// The profile the design's broadcast froze: Claude on Opus, every slice off, the standard Oracle.
    static let profile = OperatorProfile(model: "claude-opus-5-5", reasoning: "high",
                                         instructions: "You are a senior frontend engineer on Nuxt and Storyblok projects.")

    static func run(id: UUID = UUID(), name: String = "Newsletter signup", profile: OperatorProfile = profile,
                    state: OperatorRunState = .active, planRevision: Int = 1,
                    questions: [OperatorQuestion] = [], decisions: [OperatorDecision] = [],
                    windowId: String? = "operator-window", projectIds: [UUID] = [], agents: [AgentChoice] = OperatorUIFixtures.agents,
                    taskSettings: TaskSettings = TaskSettings(review: nil, end: .commit, closeWhenDone: false), goal: BroadcastGoal? = nil) -> OperatorRun {
        .make(id: id, name: name, profile: profile, projects: projectIds,
              prompt: "PLUTO-231 newsletter signup block in Storyblok", state: state, planRevision: planRevision,
              questions: questions, decisions: decisions, windowId: windowId, createdAt: epoch,
              agents: agents, taskSettings: taskSettings, goal: goal)
    }

    /// The design's broadcast set up with Agents, Task and Done: Opus 5.5 on High and gpt-6-astra on Medium, each task
    /// reviewed and ending at a draft MR, closed at the end, and a goal with two extra rounds.
    static let agents = Build.agents
    static let taskSettings = TaskSettings(review: "An adversarial review with /code-review. It passes with no Critical or "
                                           + "Important findings. After 3 rounds of fixes, ask me.", end: .draftMR)
    static let goal = BroadcastGoal(text: "The newsletter signup works end to end on staging.", extraRounds: 2)

    /// A review tab's verdict on `sha`, in `round` of three.
    static func verdict(_ sha: String = "4f2a91c", tab: String = "review", passed: Bool, round: Int = 1, critical: Int = 0,
                        important: Int = 0, minor: Int = 0) -> ReviewVerdict {
        ReviewVerdict(tab: tab, sha: sha, passed: passed, round: round, rounds: 3, critical: critical, important: important,
                      minor: minor, summary: passed ? "Nothing blocking." : "Findings to fix.", at: epoch)
    }

    /// The record `task` leaves once closed at the broadcast's end, its card's line as `result`.
    static func finished(_ task: TaskItem, result: String, branchDeleted: Bool = false) -> FinishedTaskRecord {
        let operated = task.operated
        return FinishedTaskRecord(task: task.id, key: operated?.key ?? task.title, title: task.title, ticket: task.jira?.key,
                                  project: task.projectId, agent: task.agent, model: task.model, reasoning: task.reasoning,
                                  end: operated?.end ?? .commit, state: operated?.state ?? .accepted,
                                  acceptedSHA: operated?.acceptance?.resultSHA, branch: task.branch,
                                  mergeRequestURL: operated?.publication?.mergeRequestURL, mergedSHA: operated?.publication?.mergedSHA,
                                  result: result, branchDeleted: branchDeleted, at: epoch)
    }

    static func operated(run: UUID, key: String, state: OperatedState, end: TaskEnd = .commit,
                         dependsOn: [TaskDependency] = [], stackedOn: UUID? = nil, revision: Int = 1,
                         sha: String? = nil, takenOver: Bool = false, blockedReason: String? = nil,
                         flags: Set<OperatedFlag> = []) -> OperatedTask {
        var operated = OperatedTask.make(run: run, key: key, state: state, end: end, dependsOn: dependsOn, revision: revision,
                                         acceptance: sha.map { TaskAcceptance(resultSHA: $0, prerequisiteSHAs: [], checkOutput: "tests green",
                                                                              note: nil, at: epoch) },
                                         takenOver: takenOver, blockedReason: blockedReason, flags: flags)
        // As given, not taken from a `code` dependency: the design's cards stack tasks the plan does not list.
        operated.stackedOn = stackedOn
        return operated
    }

    static func task(_ title: String, id: UUID = UUID(), jira: String? = nil, agent: AgentKind = .claude,
                     project: UUID, windowId: String? = nil, operated: OperatedTask?) -> TaskItem {
        .make(id: id, project: project, title: title, branch: "feat/\(id.uuidString.prefix(8))",
              worktreePath: "/r/.worktrees/\(id.uuidString.prefix(8))",
              jira: jira.map { JiraRef(key: $0, summary: title, url: "https://jira.example/browse/\($0)") },
              agent: agent, createdAt: epoch, windowId: windowId, operated: operated)
    }

    static func project(_ name: String) -> Project {
        .make(name: name, path: "/r/\(name)", provider: .gitlab, addedAt: epoch)
    }

    static func question(_ text: String, id: String = UUID().uuidString, task: UUID? = nil, tab: String? = nil) -> OperatorQuestion {
        OperatorQuestion(id: id, text: text, task: task, askedAt: epoch, resolution: nil, tab: tab)
    }

    /// An extra worker tab the Operator opened (`open_tab`), seen once unless `opened` is false.
    static func extraTab(_ key: String, agent: AgentKind = .codex, opened: Bool = true) -> ExtraTab {
        ExtraTab(key: key, agent: agent, model: "m", reasoning: nil, modelReason: "Tests.", brief: "Do \(key).",
                 launch: LaunchAttempt(number: 1, requestedAt: epoch, openedAt: opened ? epoch : nil))
    }

    /// One of `task`'s tabs as iTerm2 lists it: its first worker with no `key`, an extra tab with one.
    static func tab(_ id: String, of task: TaskItem, _ state: SessionState, index: Int = 0, key: String? = nil,
                    agent: SessionAgent = .claude, active: Bool = false) -> SessionInfo {
        .make(id, window: "w-\(task.id)", tabIndex: index, task: task.id, agent: agent, state: state, tabKey: key, active: active)
    }
}
