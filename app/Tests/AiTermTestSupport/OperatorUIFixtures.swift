import Foundation
import AiTermCore

/// Operators, operations and the tasks they drive, for the sidebar's, the sheets' and the overview's
/// tests — built here, in one place, so a change to the operator types' initialisers is one edit.
/// The example is the design's: "Newsletter signup", run by "Senior engineer" over pluto-cms and
/// pluto-web.
enum OperatorUIFixtures {
    static let epoch = Date(timeIntervalSince1970: 0)

    static let senior = OperatorPersona(
        name: "Senior engineer", handle: "senior", model: "claude-opus-5-5", effort: "high",
        secondOpinion: SecondOpinion(level: .healthyDoubt, agent: .codex, model: "gpt-6-astra", effort: "medium"),
        autonomy: .routine, alwaysAsk: [], limits: OperatorLimits(),
        persona: "You are a senior frontend engineer on Nuxt and Storyblok projects.", lessons: [])

    static func persona(_ name: String, handle: String, autonomy: Autonomy = .routine,
                        level: SecondOpinionLevel = .healthyDoubt, lessons: [String] = []) -> OperatorPersona {
        var persona = senior
        persona.name = name; persona.handle = handle; persona.autonomy = autonomy
        persona.secondOpinion.level = level; persona.lessons = lessons
        return persona
    }

    static func run(id: UUID = UUID(), name: String = "Newsletter signup", persona: OperatorPersona = senior,
                    state: OperatorRunState = .active, planRevision: Int = 1, approvedRevision: Int? = 1,
                    doneWhen: String? = "a commit per item, tests green — I review and push",
                    questions: [OperatorQuestion] = [], decisions: [OperatorDecision] = [],
                    lessons: [ProposedLesson] = [], windowId: String? = "operator-window",
                    projectIds: [UUID] = []) -> OperatorRun {
        OperatorRun(id: id, name: name, persona: persona, projectIds: projectIds,
                    brief: "PLUTO-231 newsletter signup block in Storyblok",
                    doneWhen: doneWhen, state: state, intent: nil, planRevision: planRevision,
                    approvedRevision: approvedRevision, questions: questions, decisions: decisions, lessons: lessons,
                    operatorConversation: nil, operatorWindowId: windowId, operatorSessionId: nil, createdAt: epoch)
    }

    static func operated(run: UUID, key: String, state: OperatedState, end: TaskEnd = .commit,
                         dependsOn: [TaskDependency] = [], stackedOn: UUID? = nil, revision: Int = 1,
                         sha: String? = nil, takenOver: Bool = false, blockedReason: String? = nil,
                         flags: Set<OperatedFlag> = []) -> OperatedTask {
        OperatedTask(runId: run, key: key, state: state, end: end, brief: "Do \(key).", dependsOn: dependsOn,
                     stackedOn: stackedOn, revision: revision,
                     acceptance: sha.map { TaskAcceptance(resultSHA: $0, prerequisiteSHAs: [], checkOutput: "tests green",
                                                          note: nil, at: epoch) },
                     publication: nil, takenOver: takenOver, ownership: 0, launch: nil, retriesUsed: 0, runtimeUsed: 0,
                     blockedReason: blockedReason, flags: flags)
    }

    static func task(_ title: String, id: UUID = UUID(), jira: String? = nil, agent: AgentKind = .claude,
                     project: UUID, windowId: String? = nil, operated: OperatedTask?) -> TaskItem {
        var task = TaskItem(id: id, projectId: project, title: title, branch: "feat/\(id.uuidString.prefix(8))",
                            worktreePath: "/r/.worktrees/\(id.uuidString.prefix(8))", baseBranch: "main",
                            jira: jira.map { JiraRef(key: $0, summary: title, url: "https://jira.example/browse/\($0)") },
                            agent: agent, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: epoch, windowId: windowId)
        task.operated = operated
        return task
    }

    static func project(_ name: String) -> Project {
        Project(id: UUID(), name: name, path: "/r/\(name)", provider: .gitlab, remoteUrl: nil, addedAt: epoch, collapsed: false)
    }

    static func question(_ text: String, id: String = UUID().uuidString, task: UUID? = nil) -> OperatorQuestion {
        OperatorQuestion(id: id, text: text, task: task, askedAt: epoch, resolution: nil)
    }
}
