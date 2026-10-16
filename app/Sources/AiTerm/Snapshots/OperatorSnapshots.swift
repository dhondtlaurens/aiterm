import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// The design's operation as the images draw it: "Senior engineer" running "Newsletter signup" over
/// pluto-cms and pluto-web — PLUTO-231's schema, PLUTO-232's homepage section building on it, the
/// /privacy footer link, the nuxt bump — beside a second operation, "Nuxt upgrade", whose plan waits,
/// and "Incident investigator" with none. Each scene is a controller of its own, at the snapshot clock;
/// the sidebar knows its operators only once `show` has put a workspace in, so a bare scene is the
/// OPERATORS heading with none beneath it.
@MainActor
struct OperatorScene {
    let controller = Fixture.emptyController()
    let cms = Project(id: UUID(), name: "pluto-cms", path: "/r/pluto-cms", provider: .gitlab, remoteUrl: nil,
                      addedAt: Snapshots.clock.now, collapsed: false)
    let web = Project(id: UUID(), name: "pluto-web", path: "/r/pluto-web", provider: .gitlab, remoteUrl: nil,
                      addedAt: Snapshots.clock.now, collapsed: false)
    let schema = UUID(), homepage = UUID(), footer = UUID(), bump = UUID(), upgrade = UUID()
    let signupId = UUID(), nuxtId = UUID()

    static let senior = OperatorPersona(
        name: "Senior engineer", handle: "senior", model: "claude-opus-5-5", effort: "high",
        secondOpinion: SecondOpinion(level: .healthyDoubt, agent: .codex, model: "gpt-6-astra", effort: "medium"),
        autonomy: .routine, alwaysAsk: [], limits: OperatorLimits(),
        persona: "You are a senior frontend engineer on Nuxt and Storyblok projects. You keep changes small and reviewable, match the code around you, and write a test where the project has them. You would rather ask than guess at product decisions.",
        lessons: [])
    static let investigator: OperatorPersona = {
        var persona = senior
        persona.name = "Incident investigator"; persona.handle = "investigator"; persona.autonomy = .handsOff
        return persona
    }()
    static let claudeModels = [AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "high"),
                               AgentModel(id: "claude-sonnet-5", label: "Sonnet 5", detail: nil, efforts: ["low", "medium"], defaultEffort: "medium")]
    static let codexModels = [AgentModel(id: "gpt-6-astra", label: "GPT-6-Astra", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "medium")]
    static let doneWhen = "a commit per item, tests green — I review and push"

    init() {
        controller.workspace.mutate { [cms, web] state in state.append(project: cms); state.append(project: web) }
    }

    func run(_ id: UUID, _ name: String, _ state: OperatorRunState, planRevision: Int = 1, approvedRevision: Int? = 1,
             questions: [OperatorQuestion] = [], decisions: [OperatorDecision] = [], lessons: [ProposedLesson] = []) -> OperatorRun {
        OperatorRun(id: id, name: name, persona: Self.senior, projectIds: [cms.id, web.id],
                    brief: "PLUTO-231 newsletter signup block in Storyblok",
                    doneWhen: Self.doneWhen, state: state, intent: nil, planRevision: planRevision, approvedRevision: approvedRevision,
                    questions: questions, decisions: decisions, lessons: lessons, operatorConversation: nil,
                    operatorWindowId: "operator-\(name)", operatorSessionId: nil, createdAt: Snapshots.clock.now)
    }

    /// A branch's tail from a title: lowercase words joined by hyphens, short enough for the row.
    static func slug(_ title: String) -> String {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(3)
        return words.joined(separator: "-")
    }

    func task(_ id: UUID, _ title: String, jira: String? = nil, agent: AgentKind = .claude, in project: Project, run: UUID,
              _ state: OperatedState, end: TaskEnd = .commit, stackedOn: UUID? = nil, sha: String? = nil,
              takenOver: Bool = false, reason: String? = nil, flags: Set<OperatedFlag> = []) -> TaskItem {
        var item = TaskItem(id: id, projectId: project.id, title: title, branch: "feat/" + Self.slug(title),
                            worktreePath: "/r/.worktrees/\(id.uuidString.prefix(6))", baseBranch: "main",
                            jira: jira.map { JiraRef(key: $0, summary: title, url: "https://jira.example/browse/\($0)") },
                            agent: agent, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Snapshots.clock.now, windowId: "w-\(id.uuidString.prefix(6))")
        item.operated = OperatedTask(
            runId: run, key: title, state: state, end: end, brief: "Do it.",
            dependsOn: stackedOn.map { [TaskDependency(task: $0, kind: .code)] } ?? [], stackedOn: stackedOn, revision: 1,
            acceptance: sha.map { TaskAcceptance(resultSHA: $0, prerequisiteSHAs: [], checkOutput: "tests green", note: nil, at: Snapshots.clock.now) },
            publication: nil, takenOver: takenOver, ownership: 0, launch: nil, retriesUsed: 0, runtimeUsed: 0,
            blockedReason: reason, flags: flags)
        return item
    }

    /// The four tasks of "Newsletter signup", each in the state given.
    func signupTasks(_ states: [OperatedState], shas: [String?] = [nil, nil, nil, nil], ends: [TaskEnd] = [.commit, .commit, .commit, .commit],
                     footerFlags: Set<OperatedFlag> = []) -> [TaskItem] {
        [task(schema, "The signup block schema", jira: "PLUTO-231", in: cms, run: signupId, states[0], end: ends[0], sha: shas[0]),
         task(homepage, "The homepage section", jira: "PLUTO-232", in: web, run: signupId, states[1], end: ends[1], stackedOn: schema, sha: shas[1]),
         task(footer, "Fix the /privacy footer link", agent: .codex, in: web, run: signupId, states[2], end: ends[2], sha: shas[2], flags: footerFlags),
         task(bump, "nuxt 3.19.2 → 3.19.4", agent: .codex, in: web, run: signupId, states[3], end: ends[3], sha: shas[3])]
    }

    /// Puts `runs` and `tasks` in the workspace, the tabs of the tasks at work, and what the operator acts on.
    func show(_ runs: [OperatorRun], _ tasks: [TaskItem], acting: Set<UUID> = []) {
        controller.rows.operatorSource = { [Self.senior, Self.investigator] }
        controller.rows.actingSource = { acting }
        controller.workspace.mutate { state in state.runs = runs; state.tasks = tasks }
        controller.live.sessions = tasks.compactMap { task -> SessionInfo? in
            guard let operated = task.operated, operated.state == .working else { return nil }
            let waiting = operated.flags.contains(.waitingOnYou)
            return Fixture.session("s-\(task.id.uuidString.prefix(6))", task.windowId ?? "", task.id, task.agent.rawValue,
                                   waiting ? "needsInput" : "working", 0, cwd: task.worktreePath, active: true)
        }
        controller.rows.refresh()
    }

    /// The design's step 6: Newsletter signup at work — one done, the homepage answered by the operator,
    /// Codex asking about npm install — and Nuxt upgrade's plan waiting.
    static func atWork(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        let signup = scene.run(scene.signupId, "Newsletter signup", .active,
                               questions: [OperatorQuestion(id: "npm", text: "Codex asks to run npm install", task: scene.footer,
                                                            askedAt: Snapshots.clock.now, resolution: nil)],
                               decisions: [OperatorDecision(key: "subtitle", text: "Gave the block an optional subtitle field: the design shows one, the ticket doesn’t mention it.",
                                                            task: scene.schema, at: Snapshots.clock.now, challenge: nil)])
        let nuxt = scene.run(scene.nuxtId, "Nuxt upgrade", .planning, planRevision: 1, approvedRevision: nil)
        let upgrade = scene.task(scene.upgrade, "Upgrade Nuxt to 3.20", in: scene.web, run: scene.nuxtId, .planned)
        scene.show([signup, nuxt], scene.signupTasks([.accepted, .working, .working, .working], shas: ["4f2a91c", nil, nil, nil],
                                                     footerFlags: [.waitingOnYou]) + [upgrade],
                   acting: [scene.homepage])
        return scene
    }

    static func paused(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        scene.show([scene.run(scene.signupId, "Newsletter signup", .paused)],
                   scene.signupTasks([.accepted, .working, .working, .queued], shas: ["4f2a91c", nil, nil, nil]))
        return scene
    }

    /// The design's step 8: every task done — one merged — and a lesson to keep.
    static func done(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        let run = scene.run(scene.signupId, "Newsletter signup", .complete, lessons: [
            ProposedLesson(key: "fields", lesson: "Ask before adding a field a ticket doesn’t mention.",
                           because: "You removed the subtitle field I added to PLUTO-231.", decided: nil),
        ])
        scene.show([run], scene.signupTasks([.accepted, .accepted, .published, .accepted],
                                            shas: ["4f2a91c", "9b3e07d", "11c5d2e", "a07f6b8"], ends: [.commit, .commit, .merge, .commit]))
        return scene
    }

    /// The design's step 5: the plan waits, and the second opinion changed one thing.
    static func planWaiting(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        let run = scene.run(scene.signupId, "Newsletter signup", .planning, planRevision: 1, approvedRevision: nil, decisions: [
            OperatorDecision(key: "plan-1", text: "2 now branches from 1’s commit.", task: nil, at: Snapshots.clock.now,
                             challenge: "2 should build on 1’s schema change, not only wait for it."),
        ])
        scene.show([run], scene.signupTasks([.planned, .planned, .planned, .planned]))
        return scene
    }

    var signup: OperatorRun? { controller.state.runs.first { $0.id == signupId } }
}

/// The operators' images, drawn after every other.
@MainActor
enum OperatorSnapshots {
    static var all: [Snapshot] {
        [
            Snapshot("operators-none.png") { sidebar(OperatorScene()) },
            Snapshot("operators-working.png") { sidebar(OperatorScene.atWork()) },
            Snapshot("operators-paused.png") { sidebar(OperatorScene.paused()) },
            Snapshot("operators-done.png") { sidebar(OperatorScene.done()) },
            Snapshot("operator-task-rows.png") { taskRows() },
            Snapshot("operator-marks.png") { marks() },
            Snapshot("operator-sheet-new.png") {
                let model = sheetModel(editing: nil)
                model.name = "Senior engineer"
                model.personaText = OperatorScene.senior.persona
                return OperatorSheet(model: model)
            },
            Snapshot("operator-sheet-edit.png") {
                var senior = OperatorScene.senior
                senior.lessons = ["Ask before adding a field a ticket doesn’t mention."]
                return OperatorSheet(model: sheetModel(editing: senior))
            },
            Snapshot("operator-sheet-no-self-doubt.png") {
                let model = sheetModel(editing: OperatorScene.senior)
                model.level = .noSelfDoubt
                model.autonomy = .handsOff
                return OperatorSheet(model: model)
            },
            Snapshot("new-operation.png") {
                let model = NewOperationModel(operators: [OperatorScene.senior, OperatorScene.investigator], picked: "senior") { _, _, _ in UUID() }
                model.brief = "PLUTO-231 newsletter signup block in Storyblok\nPLUTO-232 show it on the homepage — needs 231\nthe footer link to /privacy is broken\nbump nuxt to the latest patch"
                model.doneWhen = OperatorScene.doneWhen
                return NewOperationSheet(model: model)
            },
            Snapshot("overview-plan.png") { overview(OperatorScene.planWaiting()) },
            Snapshot("overview-working.png") { overview(OperatorScene.atWork()) },
            Snapshot("overview-paused.png") { overview(OperatorScene.paused()) },
            Snapshot("overview-done.png") { overview(OperatorScene.done()) },
        ]
    }

    private static func sheetModel(editing: OperatorPersona?) -> OperatorSheetModel {
        OperatorSheetModel(editing: editing, claudeModels: OperatorScene.claudeModels, codexModels: OperatorScene.codexModels,
                           takenHandles: { [] }, save: { _ in })
    }

    /// The list's rows as the sidebar stacks them: OPERATORS, its sections, then PROJECTS and the projects.
    private static func sidebar(_ scene: OperatorScene) -> some View {
        let controller = scene.controller, rows = controller.rows
        return VStack(alignment: .leading, spacing: Space.hairline) {
            OperatorsHeader(controller: controller)
            ForEach(rows.operatorSections) { SidebarView.operatorRows(of: $0, in: rows, controller: controller) }
            SidebarHeader(controller: controller)
            ForEach(rows.entries) { SidebarView.rows(of: $0, in: rows, controller: controller) }
        }
        .padding(.horizontal, Space.inset)
        .frame(width: Size.sidebarWidth + 2 * Space.inset)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.sidebar)
        .surface(.sidebar)
    }

    /// A driven task row in every workflow state, one project's rows stacked.
    private static func taskRows() -> some View {
        let scene = OperatorScene(), web = scene.web, run = scene.signupId
        let parent = scene.task(scene.schema, "The signup block schema", jira: "PLUTO-231", in: web, run: run, .accepted, sha: "4f2a91c")
        let rows: [TaskItem] = [
            parent,
            scene.task(UUID(), "Write the block’s tests", in: web, run: run, .planned),
            scene.task(UUID(), "The homepage section", jira: "PLUTO-232", in: web, run: run, .queued, stackedOn: scene.schema),
            scene.task(scene.homepage, "Show it on the homepage", in: web, run: run, .working),
            scene.task(UUID(), "Fix the /privacy footer link", agent: .codex, in: web, run: run, .working, flags: [.waitingOnYou]),
            scene.task(UUID(), "Bump nuxt", agent: .codex, in: web, run: run, .blocked, reason: "the tests fail on main"),
            scene.task(UUID(), "Retry the build", in: web, run: run, .failed, reason: "npm ci failed"),
            scene.task(UUID(), "Rename the block", in: web, run: run, .noChange),
            scene.task(UUID(), "Ship the block", in: web, run: run, .published, end: .merge, sha: "9b3e07d"),
            scene.task(UUID(), "Draft the docs", in: web, run: run, .published, end: .draftMR, sha: "11c5d2e"),
            scene.task(UUID(), "Tidy the footer", in: web, run: run, .working, takenOver: true),
        ]
        scene.show([scene.run(run, "Newsletter signup", .active, questions: [
            OperatorQuestion(id: "npm", text: "Codex asks to run npm install", task: rows[4].id, askedAt: Snapshots.clock.now, resolution: nil),
        ])], rows, acting: [scene.homepage])
        let projection = scene.controller.rows
        return VStack(alignment: .leading, spacing: Space.hairline) {
            if let section = projection.sections.first(where: { $0.project.id == web.id }) {
                SidebarView.taskRows(of: section, in: projection, controller: scene.controller)
            }
        }
        .padding(.horizontal, Space.inset)
        .frame(width: Size.sidebarWidth + 2 * Space.inset)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.sidebar)
        .surface(.sidebar)
    }

    /// The operator's mark alone and acting, leading Claude's and Codex's, and on a header's disc.
    private static func marks() -> some View {
        HStack(spacing: Space.gap) {
            OperatorAvatar(presence: .driving, size: Size.avatar)
            OperatorAvatar(presence: .acting, size: Size.avatar)
            AvatarGroupView(group: AvatarGroup(marks: [.claude], overflow: 0, operatorPresence: .acting))
            AvatarGroupView(group: AvatarGroup(marks: [.codex], overflow: 0, operatorPresence: .driving))
            SymbolMark(symbol: OperatorAvatar.symbol, size: Size.chip, style: .paper)
            SymbolMark(symbol: OperatorAvatar.symbol, size: Size.control, style: .paper)
        }
        .padding(Space.block)
        .background(Palette.sidebar)
        .surface(.sidebar)
    }

    private static func overview(_ scene: OperatorScene) -> some View {
        let state = scene.controller.state
        let run = scene.signup ?? scene.run(scene.signupId, "Newsletter signup", .active)
        return OperationOverviewSheet(overview: .make(run: run, state: state, acting: scene.controller.rows.acting),
                                      actions: OverviewActions())
    }
}
#endif
