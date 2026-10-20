import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// The design's broadcast as the images draw it (the Proposals tab's `p-op-*` sections): the Operator
/// running "Checkout redesign" over webshop and payments-api, PAY-230 to PAY-236 and the PAY-240 it added.
/// Each scene is a controller of its own, at the snapshot clock; the sidebar draws the broadcast row only
/// once `show` has put a broadcast in, so a bare scene is the OPERATOR heading and its "+".
@MainActor
struct OperatorScene {
    let controller = Fixture.emptyController()
    let projects: [Project]
    let runId = UUID()
    /// The broadcast's tasks by their place in the drawing's plan.
    let layout = UUID(), provider = UUID(), drawer = UUID(), autocomplete = UUID(), summary = UUID(), shipping = UUID(),
        price = UUID(), retry = UUID()

    static let site = URL(string: "https://example.atlassian.net")!
    static let payments = JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site)
    static func project(_ name: String, provider: Provider = .gitlab, jira: [JiraProjectRef] = [payments]) -> Project {
        Project(id: UUID(), name: name, path: "/Users/me/Sites/\(name)", provider: provider, remoteUrl: nil,
                addedAt: Snapshots.clock.now, collapsed: false, jiraProjects: jira)
    }

    /// The drawing's profile: Claude on Opus, the Jira slice off, Review and Merge on, the standard Oracle.
    static let profile = OperatorProfile(
        model: "claude-opus-5-5", reasoning: "high", slices: Slices(jira: false, review: true, merge: true), oracle: .standard,
        instructions: "Draft MRs only on Fridays. Every task starts with /superpowers:brainstorming.")
    static let prompt = "implement PAY-230 to PAY-236, the new checkout"
    static let review = "assign Jan, fix his feedback"
    static let done = "merged after Jan’s approval"

    init(projects: [Project] = [OperatorScene.project("webshop"), OperatorScene.project("payments-api")]) {
        self.projects = projects
        controller.workspace.mutate { state in for project in projects { state.append(project: project) } }
    }

    var webshop: Project { projects[0] }
    var paymentsApi: Project { projects[projects.count > 1 ? 1 : 0] }

    func run(_ state: OperatorRunState, name: String = "Checkout redesign", prompt: String = OperatorScene.prompt,
             review: String? = OperatorScene.review, done: String? = OperatorScene.done, planned: Int? = 8,
             questions: [OperatorQuestion] = [], decisions: [OperatorDecision] = [], finds: [OffBriefFind] = [],
             leftForYou: [String] = []) -> OperatorRun {
        OperatorRun(id: runId, name: name, profile: Self.profile, projectIds: projects.map(\.id), jiraProjectKeys: ["PAY"],
                    prompt: prompt, review: review, done: done, state: state, planRevision: planned == nil ? 0 : 1,
                    firstPlanSize: planned, questions: questions, decisions: decisions, finds: finds, leftForYou: leftForYou,
                    operatorWindowId: "operator-window", createdAt: Snapshots.clock.now)
    }

    /// A worker's permission prompt, as `OperatorController.probePrompt` records one.
    func prompt(_ text: String, on task: UUID) -> OperatorQuestion {
        OperatorQuestion(id: "prompt-\(task.uuidString)-1", text: text, task: task, askedAt: Snapshots.clock.now)
    }

    /// One of the Operator's own questions.
    func question(_ text: String, on task: UUID? = nil) -> OperatorQuestion {
        OperatorQuestion(id: "ask-\(text.count)", text: text, task: task, askedAt: Snapshots.clock.now)
    }

    /// A task the Operator made. One past `queued` has been launched, so its card wears its agent's mark;
    /// `mr` is the request `finish_task` opened, `reviewers` the people its review waits on.
    func task(_ id: UUID, _ title: String, jira: String? = nil, agent: AgentKind = .claude, in project: Project? = nil,
              _ state: OperatedState, end: TaskEnd = .merge, after parent: UUID? = nil, sha: String? = nil, mr: Int? = nil,
              reviewers: [String] = [], added: Bool = false, takenOver: Bool = false, reason: String? = nil) -> TaskItem {
        let project = project ?? webshop
        let branch = "feat/" + ([jira?.lowercased()].compactMap { $0 } + [BranchNaming.slug(title)]).joined(separator: "-")
        var item = TaskItem(id: id, projectId: project.id, title: title, branch: branch,
                            worktreePath: "\(project.path)/.worktrees/\(id.uuidString.prefix(6))", baseBranch: "main",
                            jira: jira.map { JiraRef(key: $0, summary: title, url: "https://example.atlassian.net/browse/\($0)") },
                            agent: agent, model: agent == .claude ? "claude-opus-5-5" : "gpt-6-astra", reasoning: "high",
                            firstPrompt: nil, appendTicket: false, createdAt: Snapshots.clock.now, windowId: "w-\(id.uuidString.prefix(6))")
        let launched = ![.planned, .queued].contains(state)
        item.operated = OperatedTask(
            runId: runId, key: title, state: state, end: end, brief: "Do it.",
            dependsOn: parent.map { [TaskDependency(task: $0, kind: .order)] } ?? [], revision: added ? 2 : 1,
            acceptance: sha.map { TaskAcceptance(resultSHA: $0, prerequisiteSHAs: [], checkOutput: "tests green", note: nil, at: Snapshots.clock.now) },
            publication: mr.map {
                TaskPublication(pushedSHA: sha, mergeRequestURL: "https://gitlab.example/acme/\(project.name)/-/merge_requests/\($0)",
                                mergeRequestNumber: $0, merged: state == .published && end == .merge, mergedSHA: state == .published ? sha : nil)
            },
            takenOver: takenOver, launch: launched ? LaunchAttempt(number: 1, requestedAt: Snapshots.clock.now) : nil,
            blockedReason: reason, peopleReview: reviewers.isEmpty ? nil : PeopleReview(reviewers: reviewers))
        return item
    }

    /// The board's eight, in the plan's order: two merged, the provider switch asking to run npm install,
    /// the cart drawer answered by the Operator, Shipping step in Jan's review, three to start.
    /// `oneProject` puts every task in webshop, as the sidebar's drawing does.
    func checkout(_ states: [UUID: OperatedState] = [:], oneProject: Bool = false) -> [TaskItem] {
        func state(_ id: UUID, _ planned: OperatedState) -> OperatedState { states[id] ?? planned }
        let api = oneProject ? webshop : paymentsApi
        return [
            task(layout, "Checkout layout", jira: "PAY-230", state(layout, .published), sha: "9b3e07d", mr: 412),
            task(provider, "Payment provider switch", jira: "PAY-232", agent: .codex, in: api, state(provider, .working)),
            task(drawer, "Cart drawer", jira: "PAY-231", state(drawer, .working)),
            task(autocomplete, "Address autocomplete", jira: "PAY-233", state(autocomplete, .queued), after: provider),
            task(summary, "Order summary copy", jira: "PAY-234", state(summary, .queued), after: drawer),
            task(shipping, "Shipping step", jira: "PAY-235", state(shipping, .inReview), sha: "71f0e9c", mr: 418, reviewers: ["Jan"]),
            task(price, "Price formatting", jira: "PAY-236", agent: .codex, state(price, .published), sha: "4f2a91c", mr: 415),
            task(retry, "Retry failed payments", jira: "PAY-240", in: api, state(retry, .queued), added: true),
        ]
    }

    /// Puts `run` and `tasks` in the workspace, the tabs of the tasks at work, and what the Operator does.
    /// A task with an open permission prompt has its agent waiting on you.
    func show(_ run: OperatorRun?, _ tasks: [TaskItem], acting: OperatorActs = .none) {
        controller.rows.actingSource = { acting }
        controller.workspace.mutate { state in state.runs = run.map { [$0] } ?? []; state.tasks = tasks }
        let prompted = Set((run?.questions ?? []).filter { $0.id.hasPrefix("prompt-") }.compactMap(\.task))
        controller.live.sessions = tasks.compactMap { task -> SessionInfo? in
            guard let operated = task.operated, operated.state == .working else { return nil }
            return Fixture.session("s-\(task.id.uuidString.prefix(6))", task.windowId ?? "", task.id, task.agent.rawValue,
                                   prompted.contains(task.id) ? "needsInput" : "working", 0, cwd: task.worktreePath, active: true)
        }
        controller.rows.refresh()
    }

    /// What the Operator does to the cart drawer: answering Claude, on its row and the broadcast's.
    var answeringTheDrawer: OperatorActs {
        OperatorActs(tasks: [drawer: .answering], runs: [runId: .init(act: .answering, task: "Cart drawer")])
    }

    var npmInstall: OperatorQuestion { prompt("Codex asks to run npm install", on: provider) }

    // -- the drawing's moments ------------------------------------------------------

    /// The board while it runs: one request on it, the Operator answering another agent.
    static func running(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        scene.show(scene.run(.active, questions: [scene.npmInstall]), scene.checkout(), acting: scene.answeringTheDrawer)
        return scene
    }

    /// Seconds after Start Broadcast: the plan coming in, two cards in Todo, no progress yet.
    static func planning(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        let tasks = [scene.task(scene.layout, "Checkout layout", jira: "PAY-230", .planned),
                     scene.task(scene.drawer, "Cart drawer", jira: "PAY-231", .planned, after: scene.layout)]
        scene.show(scene.run(.planning, planned: nil), tasks)
        return scene
    }

    /// Reopening the Operator's window failed: the board as it ran, its window closed.
    static func windowClosed(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        scene.show(scene.run(.operatorOffline), scene.checkout(), acting: scene.answeringTheDrawer)
        return scene
    }

    /// Every task merged, with what the Operator decided, found and left for you.
    static func debrief(_ scene: OperatorScene = OperatorScene()) -> OperatorScene {
        let merged: [(UUID, String, Int)] = [
            (scene.layout, "9b3e07d", 412), (scene.drawer, "51ac0f2", 416), (scene.provider, "e07d9b3", 417),
            (scene.autocomplete, "3be1a07", 419), (scene.summary, "c4a8d21", 420), (scene.shipping, "71f0e9c", 418),
            (scene.price, "4f2a91c", 415), (scene.retry, "8d21c4a", 421),
        ]
        let shas = Dictionary(uniqueKeysWithValues: merged.map { ($0.0, ($0.1, $0.2)) })
        let tasks = scene.checkout().map { item -> TaskItem in
            var item = item
            guard var operated = item.operated, let merge = shas[item.id] else { return item }
            let (sha, mr) = merge
            operated.state = .published
            operated.launch = LaunchAttempt(number: 1, requestedAt: Snapshots.clock.now)
            operated.peopleReview = nil
            operated.acceptance = TaskAcceptance(resultSHA: sha, prerequisiteSHAs: [], checkOutput: "tests green", note: nil, at: Snapshots.clock.now)
            let project = scene.projects.first { $0.id == item.projectId }?.name ?? "webshop"
            operated.publication = TaskPublication(pushedSHA: sha, mergeRequestURL: "https://gitlab.example/acme/\(project)/-/merge_requests/\(mr)",
                                                   mergeRequestNumber: mr, merged: true, mergedSHA: sha)
            item.operated = operated
            return item
        }
        let run = scene.run(.complete, decisions: [
            OperatorDecision(key: "retry", text: "Added Retry failed payments (PAY-240)", task: scene.retry, at: Snapshots.clock.now,
                             why: "The provider switch left failed payments with no retry. In the brief’s scope; the Oracle agreed."),
            OperatorDecision(key: "flag", text: "Kept the old button behind a flag", task: scene.drawer, at: Snapshots.clock.now,
                             why: "PAY-231’s ticket didn’t say.", objection: "the flag can go in one line."),
            OperatorDecision(key: "currency", text: "Answered “which currency format?” with the shop’s locale", task: scene.price,
                             at: Snapshots.clock.now, why: "From the code: every price already uses it."),
        ], finds: [
            OffBriefFind(key: "key", title: "An API key in payments-api’s test fixtures", why: "A live-looking Adyen key in a committed fixture. Off-brief."),
            OffBriefFind(key: "flaky", title: "A flaky cart test on main", why: "Fails one run in five, unrelated to this work."),
        ], leftForYou: ["File the 2 finds in Jira"])
        scene.show(run, tasks)
        return scene
    }

    var board: BroadcastBoard? { controller.rows.board }
}

/// The Operator's images, drawn after every other, in the order `OperatorSnapshotTests` pins.
@MainActor
enum OperatorSnapshots {
    static var all: [Snapshot] {
        [
            // The sidebar with no broadcast: OPERATOR and its "+", nothing beneath it.
            Snapshot("operator-heading-empty.png") { headingEmpty() },
            // The broadcast row in each state, then on the selection, acting and needing you.
            Snapshot("broadcast-row-states.png") { broadcastRowStates() },
            // A broadcast running: the heading without its "+", the row, and a driven task row in every state,
            // the one needing you selected.
            Snapshot("driven-task-rows.png") { drivenTaskRows() },
            Snapshot("board-running.png") { board(OperatorScene.running()) },
            Snapshot("board-planning.png") { board(OperatorScene.planning()) },
            Snapshot("board-paused.png") { board(pausedCleanup()) },
            Snapshot("board-reopen-failed.png") { board(OperatorScene.windowClosed(), reopenFailed: true) },
            Snapshot("debrief.png") { board(OperatorScene.debrief()) },
            Snapshot("new-broadcast-1.png") { newBroadcast(step: 1) },
            Snapshot("new-broadcast-2.png") { newBroadcast(step: 2) },
            Snapshot("new-broadcast-3.png") { newBroadcast(step: 3) },
            Snapshot("new-broadcast-4.png") { newBroadcast(step: 4) },
            Snapshot("new-broadcast-3-review-off.png") { newBroadcast(step: 3, slices: Slices(jira: true, merge: true)) },
            Snapshot("new-broadcast-4-merge-off.png") { newBroadcast(step: 4, slices: Slices(jira: true, review: true)) },
            Snapshot("settings-operator.png") {
                OperatorSettingsPane(model: operatorSettings(oracle: true))
                    .padding(Space.margin).frame(width: Sheet.width).background(Palette.surface)
            },
            Snapshot("settings-operator-oracle-off.png") {
                OracleGroup(model: operatorSettings(oracle: false))
                    .padding(Space.margin).frame(width: Sheet.width).background(Palette.surface)
            },
            // Settings › Agents' first group: on with Claude Code installed, then off and disabled without it.
            Snapshot("settings-help-with-problems.png") {
                VStack(alignment: .leading, spacing: Space.block) {
                    HelpWithProblemsGroup(choice: .constant(HelpWithProblems(isOn: true)), installed: [.claude, .codex])
                    HelpWithProblemsGroup(choice: .constant(HelpWithProblems(isOn: true)), installed: [.codex, .pi])
                }
                .padding(Space.margin).frame(width: Sheet.width).background(Palette.surface)
            },
            // Find a Fix in the sidebar banner's Notice: offered, looking, its proposal, and a fix that failed.
            Snapshot("banner-find-a-fix-offered.png") { fixBanner(.offered) },
            Snapshot("banner-find-a-fix-looking.png") { fixBanner(.looking) },
            Snapshot("banner-find-a-fix-proposal.png") { fixBanner(.proposal(proposal)) },
            Snapshot("banner-find-a-fix-failed.png") {
                fixBanner(.failed("The fix stopped on cart/drawer.vue, and AiTerm aborted the rebase again."))
            },
            // A failed create in a sheet's footer: one sentence, so the title alone, the actions footer buttons.
            Snapshot("notice-footer.png") { noticeFooter() },
        ]
    }

    // -- the sidebar ----------------------------------------------------------------

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

    /// No broadcast: the heading and its "+", over webshop and a task of your own.
    private static func headingEmpty() -> some View {
        let scene = OperatorScene(projects: [OperatorScene.project("webshop")])
        let footer = TaskItem(id: UUID(), projectId: scene.webshop.id, title: "Fix the footer links", branch: "fix/web-88-footer",
                              worktreePath: "/Users/me/Sites/webshop/.worktrees/web-88-footer", baseBranch: "main",
                              jira: JiraRef(key: "WEB-88", summary: "Footer links", url: "https://example.atlassian.net/browse/WEB-88"),
                              agent: .claude, model: "claude-opus-5-5", reasoning: "high", firstPrompt: nil, appendTicket: false,
                              createdAt: Snapshots.clock.now, windowId: "w-footer")
        scene.controller.workspace.mutate { $0.tasks = [footer] }
        scene.controller.live.sessions = [Fixture.session("s-footer", "w-footer", footer.id, "claude", "idle", 0,
                                                          cwd: footer.worktreePath, active: true)].compactMap { $0 }
        scene.controller.rows.refresh()
        return sidebar(scene)
    }

    /// The row in the drawing's nine states, then selected while the Operator acts and while it needs you.
    private static func broadcastRowStates() -> some View {
        func watching(_ scene: OperatorScene) -> [TaskItem] { scene.checkout([scene.shipping: .working]) }
        let planning = OperatorScene()
        planning.show(planning.run(.planning, planned: nil), [])

        let oracle = OperatorScene()
        let planned = oracle.checkout([oracle.layout: .queued, oracle.provider: .queued, oracle.drawer: .queued,
                                       oracle.shipping: .queued, oracle.price: .queued]).filter { $0.id != oracle.retry }
        oracle.show(oracle.run(.active, planned: 7), planned,
                    acting: OperatorActs(runs: [oracle.runId: .init(act: .consultingTheOracle)]))

        let watched = OperatorScene()
        watched.show(watched.run(.active), watching(watched))

        let asked = OperatorScene()
        asked.show(asked.run(.active, questions: [asked.question("retry policy?")]), watching(asked))

        let several = OperatorScene()
        several.show(several.run(.active, questions: [several.npmInstall, several.question("which currency format?", on: several.drawer)]),
                     watching(several))

        let review = OperatorScene()
        review.show(review.run(.active), review.checkout([review.provider: .published, review.drawer: .published,
                                                          review.autocomplete: .published, review.summary: .published,
                                                          review.retry: .published]))

        let paused = OperatorScene()
        paused.show(paused.run(.paused), watching(paused))

        let closed = OperatorScene()
        closed.show(closed.run(.operatorOffline), watching(closed))

        let done = OperatorScene.debrief()

        let acting = OperatorScene()
        acting.show(acting.run(.active), watching(acting), acting: acting.answeringTheDrawer)
        acting.controller.focus.browse(.operation(acting.runId))

        let needsYou = OperatorScene()
        needsYou.show(needsYou.run(.active, questions: [needsYou.npmInstall, needsYou.question("which currency format?", on: needsYou.drawer)]),
                      watching(needsYou))
        needsYou.controller.focus.browse(.operation(needsYou.runId))

        let scenes = [planning, oracle, watched, asked, several, review, paused, closed, done, acting, needsYou]
        return VStack(alignment: .leading, spacing: Space.hairline) {
            ForEach(scenes.indices, id: \.self) { index in
                if let row = scenes[index].controller.rows.broadcast {
                    BroadcastRowView(row: row, controller: scenes[index].controller)
                }
            }
        }
        .padding(.horizontal, Space.inset).padding(.vertical, Space.tight)
        .frame(width: Size.sidebarWidth + 2 * Space.inset)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.sidebar)
        .surface(.sidebar)
    }

    /// The broadcast running over webshop: a driven task in every state, Payment provider switch selected.
    private static func drivenTaskRows() -> some View {
        let scene = OperatorScene()
        let more = (coupon: UUID(), tax: UUID(), icon: UUID(), wrap: UUID(), express: UUID(), tidy: UUID())
        let checkout = scene.checkout([scene.summary: .working, scene.price: .accepted], oneProject: true).map { task -> TaskItem in
            var task = task
            if task.id == scene.price { task.operated?.publication = nil }
            return task
        }
        let tasks = checkout + [
            scene.task(more.express, "Express checkout", .queued),
            scene.task(more.coupon, "Coupon field", .blocked, reason: "the tests fail on main"),
            scene.task(more.tax, "Tax rounding", .failed, reason: "npm ci failed"),
            scene.task(more.icon, "Basket icon", .noChange),
            scene.task(more.wrap, "Gift wrap option", .published, end: .draftMR, sha: "c2d4e6f", mr: 422),
            scene.task(more.tidy, "Tidy the footer", .working, takenOver: true),
        ]
        scene.show(scene.run(.active, questions: [scene.npmInstall]), tasks, acting: scene.answeringTheDrawer)
        scene.controller.focus.browse(.task(scene.provider))
        return sidebar(scene)
    }

    // -- the board --------------------------------------------------------------------

    private static func board(_ scene: OperatorScene, reopenFailed: Bool = false) -> some View {
        let board = scene.board ?? BroadcastBoard.make(run: scene.run(.active), state: scene.controller.state, acting: .none, requests: [])
        return BroadcastBoardSheet(board: board, reopenFailed: reopenFailed, actions: BoardActions())
    }

    /// The drawing's paused broadcast: one project, so no project on the cards, and no review, so no Review column.
    private static func pausedCleanup() -> OperatorScene {
        let scene = OperatorScene(projects: [OperatorScene.project("personal-site", provider: .github, jira: [])])
        let analytics = UUID(), builder = UUID(), rss = UUID()
        let run = OperatorRun(id: scene.runId, name: "Personal site cleanup", profile: OperatorScene.profile,
                              projectIds: [scene.webshop.id], prompt: "tidy the blog’s build and drop the old analytics",
                              done: "merged locally when everything’s resolved", state: .paused, planRevision: 1, firstPlanSize: 3,
                              operatorWindowId: "operator-window", createdAt: Snapshots.clock.now)
        scene.show(run, [
            scene.task(analytics, "Drop the old analytics", .queued, end: .mergeLocal),
            scene.task(builder, "Upgrade the static site builder", .working, end: .mergeLocal),
            scene.task(rss, "Fix the RSS feed’s dates", .published, end: .mergeLocal, sha: "1c84e20"),
        ])
        return scene
    }

    // -- New Broadcast ----------------------------------------------------------------

    /// New Broadcast on `step`, as the drawing fills it: PAY · Payments picked, which picked webshop and
    /// payments-api, then the prompt, Jan's review and the merge, or with Review or Merge off the steps left empty.
    private static func newBroadcast(step: Int, slices: Slices = Slices(jira: true, review: true, merge: true)) -> some View {
        let projects = [OperatorScene.project("webshop"), OperatorScene.project("payments-api")]
        // What `/` lists: seeded, and found again by the load the sheet starts when hosted.
        let skills = [AgentCompletion(name: "superpowers:brainstorming", kind: .skill,
                                      detail: "You MUST use this before any creative work", source: .plugin("superpowers"))]
        let model = NewBroadcastModel(projects: projects, slices: slices, skills: { _, _ in skills }) { _ in UUID() }
        model.received([OperatorScene.payments])
        model.add(jiraProject: OperatorScene.payments)
        model.completions.all = skills
        model.prompt = "Implement PAY-230 to PAY-236, the new checkout. PAY-232 needs the Adyen SDK; keep the old provider "
            + "behind a flag until it ships. Start each task with /superpowers:brainstorming."
        if slices.review { model.review = "Assign Jan. Have the agent fix his feedback and reply in the threads." }
        if slices.merge { model.done = "Merged after Jan’s approval, pipeline green." }
        return NewBroadcastSheet(model: model).seeded(step: step)
    }

    // -- Settings -----------------------------------------------------------------------

    /// Settings › Operator as the drawing has it: Opus 5.5 on High, Jira and Review on, Merge off, the Oracle
    /// on Codex's gpt-6-astra (or off, its choice kept), and the house rules.
    private static func operatorSettings(oracle: Bool) -> OperatorSettingsModel {
        var profile = OperatorScene.profile
        profile.slices = Slices(jira: true, review: true, merge: false)
        profile.oracle.isOn = oracle
        let efforts = ["low", "medium", "high"]
        let loaded = OperatorSettingsModel.Loaded(
            profile: profile,
            models: [.claude: [AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil, efforts: efforts, defaultEffort: "high")],
                     .codex: [AgentModel(id: "gpt-6-astra", label: "gpt-6-astra", detail: nil, efforts: efforts, defaultEffort: "medium")]],
            agentDefaults: [:],
            skills: [AgentCompletion(name: "superpowers:brainstorming", kind: .skill, detail: "You MUST use this before any creative work",
                                     source: .plugin("superpowers"))])
        let model = OperatorSettingsModel(installed: { [.claude, .codex] }, load: { loaded }, save: { _ in })
        model.received(loaded)
        return model
    }

    // -- Notices --------------------------------------------------------------------------

    /// The design's conflicted rebase of webshop's `main`, refused from the banner's Rebase.
    private static var conflict: OperationIssue {
        .rebaseRefused(WorktreeError.rebaseConflicted("main", detail: "CONFLICT (content): Merge conflict in src/cart/drawer.vue"),
                       in: UUID(), projectPath: "/Users/me/Sites/webshop")
    }

    /// The design's proposal for it.
    private static let proposal = FixProposal(
        headline: "Both sides renamed the price helper.",
        why: "origin moved it to utils/price.ts; your main still imports the old path.",
        steps: ["Rebase onto origin’s main again", "Take origin’s utils/price.ts", "Point the 3 imports at the new path"],
        moves: ["main"], drops: [], verify: nil)

    /// The failed-operation banner as the sidebar draws it, its Find a Fix in `state`, at the sidebar's width.
    private static func fixBanner(_ state: FixSession.State) -> some View {
        let issue = conflict
        let session = FixSession.snapshot(state, fixer: .ready(.claude), request: issue.fix!, proposal: proposal)
        return IssueBanner(issue: issue, fix: session, perform: { _ in }, cancelFix: {}, dismiss: {})
            .frame(width: Size.sidebarWidth + 2 * Space.inset)
            .background(Palette.sidebar)
            .surface(.sidebar)
    }

    /// New Review's footer after git refused the review's branch, checked out in webshop's own folder (only a
    /// review's branch can be: a task's is new).
    private static func noticeFooter() -> some View {
        let failure = CreationFailure(WorktreeError.branchInProjectFolder("feat/pay-231-cart-drawer", at: "/Users/me/Sites/webshop",
                                                                          switchTo: "main", hasChanges: false),
                                      projectPath: "/Users/me/Sites/webshop")
        let session = failure.fix.map { FixSession.snapshot(.offered, fixer: .ready(.claude), request: $0) }
        return CreationFooter(step: 3, error: failure, availableAgents: [.claude], createLabel: "Create Review", creating: false,
                              canAdvance: true, closeList: { false }, back: {}, advance: {}, recover: {}, fix: session)
            .padding(Space.margin).frame(width: Sheet.width).background(Palette.surfaceRaised)
    }
}
#endif
