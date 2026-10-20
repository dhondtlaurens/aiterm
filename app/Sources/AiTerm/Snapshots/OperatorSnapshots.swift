import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// The design's broadcast as the images draw it: the Operator running "Newsletter signup" over
/// pluto-cms and pluto-web (PLUTO-231's schema, PLUTO-232's homepage section building on it, the
/// /privacy footer link, the nuxt bump). Each scene is a controller of its own, at the snapshot clock;
/// the sidebar draws the broadcast row only once `show` has put a broadcast in, so a bare scene is the
/// OPERATOR heading and its "+" with nothing beneath it.
@MainActor
struct OperatorScene {
    let controller = Fixture.emptyController()
    let cms = Project(id: UUID(), name: "pluto-cms", path: "/r/pluto-cms", provider: .gitlab, remoteUrl: nil,
                      addedAt: Snapshots.clock.now, collapsed: false)
    let web = Project(id: UUID(), name: "pluto-web", path: "/r/pluto-web", provider: .gitlab, remoteUrl: nil,
                      addedAt: Snapshots.clock.now, collapsed: false)
    let schema = UUID(), homepage = UUID(), footer = UUID(), bump = UUID()
    let signupId = UUID()

    static let profile = OperatorProfile(
        model: "claude-opus-5-5", reasoning: "high",
        instructions: "You are a senior frontend engineer on Nuxt and Storyblok projects. You keep changes small and reviewable, match the code around you, and write a test where the project has them. You would rather ask than guess at product decisions.")
    static let done = "a commit per item, tests green, I review and push"

    init() {
        controller.workspace.mutate { [cms, web] state in state.append(project: cms); state.append(project: web) }
    }

    func run(_ id: UUID, _ name: String, _ state: OperatorRunState, planRevision: Int = 1,
             questions: [OperatorQuestion] = [], decisions: [OperatorDecision] = []) -> OperatorRun {
        // The four tasks are in Todo once a plan is submitted: the row's progress starts then.
        OperatorRun(id: id, name: name, profile: Self.profile, projectIds: [cms.id, web.id],
                    prompt: "PLUTO-231 newsletter signup block in Storyblok",
                    done: Self.done, state: state, intent: nil, planRevision: planRevision,
                    firstPlanSize: planRevision > 0 ? 4 : nil,
                    questions: questions, decisions: decisions, operatorConversation: nil,
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

    /// Puts `runs` and `tasks` in the workspace, the tabs of the tasks at work, and what the operator does to each.
    func show(_ runs: [OperatorRun], _ tasks: [TaskItem], acting: [UUID: OperatorAct] = [:]) {
        controller.rows.actingSource = { OperatorActs(tasks: acting) }
        controller.workspace.mutate { state in state.runs = runs; state.tasks = tasks }
        controller.live.sessions = tasks.compactMap { task -> SessionInfo? in
            guard let operated = task.operated, operated.state == .working else { return nil }
            let waiting = operated.flags.contains(.waitingOnYou)
            return Fixture.session("s-\(task.id.uuidString.prefix(6))", task.windowId ?? "", task.id, task.agent.rawValue,
                                   waiting ? "needsInput" : "working", 0, cwd: task.worktreePath, active: true)
        }
        controller.rows.refresh()
    }

    /// The design's step 6: Newsletter signup at work — one done, the homepage answered by the Operator,
    /// Codex asking about npm install.
    static func atWork(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        let signup = scene.run(scene.signupId, "Newsletter signup", .active,
                               questions: [OperatorQuestion(id: "prompt-\(scene.footer.uuidString)-1", text: "Codex asks to run npm install", task: scene.footer,
                                                            askedAt: Snapshots.clock.now, resolution: nil)],
                               decisions: [OperatorDecision(key: "subtitle", text: "Gave the block an optional subtitle field: the design shows one, the ticket doesn’t mention it.",
                                                            task: scene.schema, at: Snapshots.clock.now, challenge: nil)])
        scene.show([signup], scene.signupTasks([.accepted, .working, .working, .working], shas: ["4f2a91c", nil, nil, nil],
                                               footerFlags: [.waitingOnYou]),
                   acting: [scene.homepage: .answering])
        return scene
    }

    static func paused(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        scene.show([scene.run(scene.signupId, "Newsletter signup", .paused)],
                   scene.signupTasks([.accepted, .working, .working, .queued], shas: ["4f2a91c", nil, nil, nil]))
        return scene
    }

    /// The design's step 8: every task done, one merged.
    static func done(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        let run = scene.run(scene.signupId, "Newsletter signup", .complete)
        scene.show([run], scene.signupTasks([.accepted, .accepted, .published, .accepted],
                                            shas: ["4f2a91c", "9b3e07d", "11c5d2e", "a07f6b8"], ends: [.commit, .commit, .merge, .commit]))
        return scene
    }

    /// The design's step 5: the plan is drawn up and not yet submitted, and the second opinion changed one thing.
    static func planWaiting(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        let run = scene.run(scene.signupId, "Newsletter signup", .planning, planRevision: 0, decisions: [
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
            Snapshot("new-operation.png") {
                let model = NewOperationModel { _, _ in UUID() }
                model.prompt = "PLUTO-231 newsletter signup block in Storyblok\nPLUTO-232 show it on the homepage, needs 231\nthe footer link to /privacy is broken\nbump nuxt to the latest patch"
                model.done = OperatorScene.done
                return NewOperationSheet(model: model)
            },
            Snapshot("overview-plan.png") { overview(OperatorScene.planWaiting()) },
            Snapshot("overview-working.png") { overview(OperatorScene.atWork()) },
            Snapshot("overview-paused.png") { overview(OperatorScene.paused()) },
            Snapshot("overview-done.png") { overview(OperatorScene.done()) },
        ]
    }

    /// The list's rows as the sidebar stacks them: OPERATOR and the broadcast's row, then PROJECTS and the projects.
    private static func sidebar(_ scene: OperatorScene) -> some View {
        let controller = scene.controller, rows = controller.rows
        return VStack(alignment: .leading, spacing: Space.hairline) {
            SidebarView.operatorRows(in: rows, controller: controller)
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
            // A worker's prompt, as `OperatorController.probePrompt` records one.
            OperatorQuestion(id: "prompt-\(rows[4].id.uuidString)-1", text: "Codex asks to run npm install", task: rows[4].id,
                             askedAt: Snapshots.clock.now, resolution: nil),
        ])], rows, acting: [scene.homepage: .answering])
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

    /// The operator badge in each look, on the sidebar and on the selection: quiet, acting (still, as
    /// every snapshot draws it), the Oracle joining, needs you, and a detail cut to fit.
    private static func marks() -> some View {
        let lines = [
            OperatorLine("queued · after PAY-232"),
            OperatorLine("starting Claude", look: .acting),
            OperatorLine("consulting the Oracle", look: .acting, oracle: true),
            OperatorLine("waiting on you · retry policy?", look: .needsYou),
            OperatorLine("blocked · the tests fail on main", look: .needsYou),
            OperatorLine(OperatorLine.fit("waiting on you", "Should the signup block keep its subtitle on mobile?"), look: .needsYou),
        ]
        func column(_ surface: Surface, _ ground: Color) -> some View {
            VStack(alignment: .leading, spacing: Space.base) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in OperatorBadge(line: line) }
            }
            .padding(Space.block)
            .background(ground)
            .surface(surface)
        }
        return HStack(spacing: 0) {
            column(.sidebar, Palette.sidebar)
            column(.accent, Palette.selection)
        }
    }

    private static func overview(_ scene: OperatorScene) -> some View {
        let state = scene.controller.state
        let run = scene.signup ?? scene.run(scene.signupId, "Newsletter signup", .active)
        return OperationOverviewSheet(overview: .make(run: run, state: state, acting: Set(scene.controller.rows.acting.tasks.keys)),
                                      actions: OverviewActions())
    }
}
#endif
