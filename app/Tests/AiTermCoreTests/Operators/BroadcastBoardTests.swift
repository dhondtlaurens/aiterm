import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The broadcast's board as a value (spec §4, §4.2, §13): the header restating the brief, the columns
/// Todo · In progress · Review · Done with each task's card where its state puts it, what a card opens,
/// and the debrief that takes the board's place once every task is done.
@Suite struct BroadcastBoardTests {
    private let web = OperatorUIFixtures.project("webshop"), api = OperatorUIFixtures.project("payments-api")

    private func state(_ run: OperatorRun, _ tasks: [TaskItem] = []) -> AppState {
        var state = AppState()
        for project in [web, api] { state.append(project: project) }
        state.runs = [run]
        state.tasks = tasks
        return state
    }

    private func run(_ state: OperatorRunState = .active, review: String? = "assign Jan, fix his feedback",
                     projects: [UUID]? = nil, questions: [OperatorQuestion] = []) -> OperatorRun {
        var run = OperatorUIFixtures.run(name: "Checkout redesign", state: state, done: "merged after Jan's approval",
                                         questions: questions, projectIds: projects ?? [web.id, api.id])
        run.prompt = "implement PAY-230 to PAY-236, the new checkout"
        run.review = review
        run.firstPlanSize = 8
        return run
    }

    /// A task of `run` in `state`; `started` gives it a launch, as a worker started for it does.
    private func task(_ title: String, jira: String? = nil, run: UUID, _ state: OperatedState, project: Project? = nil,
                      agent: AgentKind = .claude, started: Bool? = nil, takenOver: Bool = false, end: TaskEnd = .commit,
                      blockedReason: String? = nil) -> TaskItem {
        var operated = OperatorUIFixtures.operated(run: run, key: jira ?? title, state: state, end: end,
                                                   sha: [.accepted, .noChange, .published].contains(state) ? "9b3e07d11" : nil,
                                                   takenOver: takenOver, blockedReason: blockedReason)
        if started ?? ![.planned, .queued].contains(state) {
            operated.launch = LaunchAttempt(number: 1, requestedAt: OperatorUIFixtures.epoch, openedAt: OperatorUIFixtures.epoch)
        }
        return OperatorUIFixtures.task(title, jira: jira, agent: agent, project: (project ?? web).id, operated: operated)
    }

    private func column(_ board: BroadcastBoard, _ column: BroadcastBoard.Column) -> [String] {
        board.columns.first { $0.column == column }?.cards.map(\.title) ?? []
    }

    @Test func theHeaderRestatesTheBrief() throws {
        let run = run()
        let tasks = [task("Checkout layout", jira: "PAY-230", run: run.id, .published, end: .merge),
                     task("Cart drawer", jira: "PAY-231", run: run.id, .working)]
            + (0..<6).map { task("Later \($0)", run: run.id, .queued) }
        let board = BroadcastBoard.make(run: run, state: state(run, tasks), acting: .none, requests: [])
        #expect(board.title == "Checkout redesign")
        #expect(board.band == OperatorLine("monitoring 1 task", look: .acting))
        #expect(board.progress == "1 of 8 done", "the band's progress, and no projects")
        #expect(board.clauses == [BroadcastBoard.Clause(label: "Asked", text: "implement PAY-230 to PAY-236, the new checkout"),
                                  BroadcastBoard.Clause(label: "Review", text: "assign Jan, fix his feedback"),
                                  BroadcastBoard.Clause(label: "Done", text: "merged after Jan's approval")])
        #expect(board.asked == "Asked implement PAY-230 to PAY-236, the new checkout · Review assign Jan, fix his feedback · Done merged after Jan's approval")

        // No progress until the first plan is in Todo.
        var planning = self.run(.planning, review: nil)
        planning.firstPlanSize = nil
        let early = BroadcastBoard.make(run: planning, state: state(planning), acting: .none, requests: [])
        #expect(early.progress == nil)
        #expect(early.band.text == "loading the construct")
        #expect(early.clauses.map(\.label) == ["Asked", "Done"], "no Review clause without a review")
    }

    @Test func cardsSitInTheirColumns() {
        let run = run()
        let tasks = [
            task("Address autocomplete", run: run.id, .queued),
            task("Retry failed payments", run: run.id, .planned),
            task("Waiting on main", run: run.id, .blocked, started: false, blockedReason: "the tests fail on main"),
            task("Payment provider switch", run: run.id, .working, agent: .codex),
            task("Flaky", run: run.id, .failed),
            task("Stuck", run: run.id, .blocked, blockedReason: "it needs a key"),
            task("Shipping step", run: run.id, .inReview),
            task("Checkout layout", run: run.id, .published, end: .merge),
            task("Price formatting", run: run.id, .accepted),
            task("Nothing to do", run: run.id, .noChange),
            task("You stopped it", run: run.id, .stopped),
        ]
        let board = BroadcastBoard.make(run: run, state: state(run, tasks), acting: .none, requests: [])
        #expect(board.columns.map(\.column) == [.todo, .inProgress, .review, .done])
        #expect(board.columns.map(\.title) == ["Todo", "In progress", "Review", "Done"])
        #expect(column(board, .todo) == ["Address autocomplete", "Retry failed payments", "Waiting on main"])
        #expect(column(board, .inProgress) == ["Payment provider switch", "Flaky", "Stuck"])
        #expect(column(board, .review) == ["Shipping step"])
        #expect(column(board, .done) == ["Checkout layout", "Price formatting", "Nothing to do"], "a stopped task is on no column")

        // The agent's mark on every card, started or not (spec §15.4), and the line its row says.
        let cards = board.columns.flatMap(\.cards)
        #expect(cards.first { $0.title == "Address autocomplete" }?.agent == .claude, "a Todo card wears its agent before launch")
        #expect(cards.filter { $0.agent == nil }.isEmpty, "no card is without its agent")
        #expect(cards.first { $0.title == "Payment provider switch" }?.agent == .codex)
        #expect(cards.first { $0.title == "Checkout layout" }?.line?.text == "merged · 9b3e07d")
        #expect(cards.first { $0.title == "Address autocomplete" }?.line?.text == "queued")

        // Empty columns say so in one muted line.
        var planning = self.run(.planning)
        planning.firstPlanSize = nil
        let empty = BroadcastBoard.make(run: planning, state: state(planning, [task("Checkout layout", run: planning.id, .planned)]),
                                        acting: .none, requests: [])
        #expect(empty.columns.map(\.empty) == ["Nothing left to start.", "Nothing started yet.", "Nothing in review.", "Nothing done yet."])
        #expect(BroadcastBoard.make(run: planning, state: state(planning), acting: .none, requests: []).columns[0].empty
                == "Nothing planned yet.")
    }

    @Test func reviewColumnOnlyWithAReview() {
        let reviewed = run()
        let unreviewed = run(review: nil)
        #expect(BroadcastBoard.make(run: reviewed, state: state(reviewed), acting: .none, requests: []).columns.map(\.column)
                == [.todo, .inProgress, .review, .done])
        let tasks = [task("Shipping step", run: unreviewed.id, .inReview)]
        let board = BroadcastBoard.make(run: unreviewed, state: state(unreviewed, tasks), acting: .none, requests: [])
        #expect(board.columns.map(\.column) == [.todo, .inProgress, .done])
        #expect(column(board, .inProgress) == ["Shipping step"], "with no Review column a task in review is in progress")
        var blank = run(review: "  ")
        blank.review = "  "
        #expect(BroadcastBoard.make(run: blank, state: state(blank), acting: .none, requests: []).columns.count == 3)
    }

    @Test func projectOnlyWhenSeveral() throws {
        let several = run()
        let tasks = [task("Payment provider switch", jira: "PAY-232", run: several.id, .working, project: api)]
        let card = try #require(BroadcastBoard.make(run: several, state: state(several, tasks), acting: .none, requests: [])
            .columns.flatMap(\.cards).first)
        #expect(card.project == "payments-api")
        #expect(card.ticket == "PAY-232")

        let one = run(projects: [web.id])
        let alone = [task("Fix the RSS feed's dates", run: one.id, .working)]
        let single = try #require(BroadcastBoard.make(run: one, state: state(one, alone), acting: .none, requests: [])
            .columns.flatMap(\.cards).first)
        #expect(single.project == nil, "one project: no project on the cards")
        #expect(single.ticket == nil)
    }

    @Test func eachRequestOpensItsPlace() throws {
        let run = run(questions: [OperatorUIFixtures.question("retry policy?", id: "q1")])
        var permission = task("Payment provider switch", jira: "PAY-232", run: run.id, .working, agent: .codex)
        let question = task("Retry failed payments", jira: "PAY-240", run: run.id, .working)
        let blocked = task("Address autocomplete", jira: "PAY-233", run: run.id, .blocked, blockedReason: "the tests fail on main")
        var problem = task("Shipping step", jira: "PAY-235", run: run.id, .blocked, blockedReason: "The rebase conflicted.")
        problem.operated?.problem = "issue-7"
        let working = task("Cart drawer", jira: "PAY-231", run: run.id, .working)
        let todo = task("Order summary copy", jira: "PAY-234", run: run.id, .queued)
        permission.operated?.flags = [.waitingOnYou]
        var asking = run
        asking.questions = [OperatorUIFixtures.question("retry policy?", id: "q1", task: question.id),
                            OperatorQuestion(id: "prompt-1", text: "Codex asks to run npm install", task: permission.id,
                                             askedAt: OperatorUIFixtures.epoch)]
        let state = state(asking, [permission, question, blocked, problem, working, todo])
        let requests = OperatorRequests.open(run: asking, state: state, prompts: [permission.id: "run npm install"])
        let board = BroadcastBoard.make(run: asking, state: state, acting: .none, requests: requests)
        let cards = Dictionary(uniqueKeysWithValues: board.columns.flatMap(\.cards).map { ($0.title, $0) })

        #expect(cards["Payment provider switch"]?.opens == .taskWindow(permission.id), "a permission prompt: the task's window")
        #expect(cards["Payment provider switch"]?.line?.text == "waiting on you")
        #expect(cards["Retry failed payments"]?.opens == .operatorWindow, "a question: the Operator's window")
        #expect(cards["Retry failed payments"]?.line?.text == "waiting on you")
        #expect(cards["Address autocomplete"]?.opens == .operatorWindow, "blocked: the Operator's window")
        #expect(cards["Shipping step"]?.opens == .sidebarBanner(issue: "issue-7"), "AiTerm's problem: the banner's Notice")
        #expect(cards["Shipping step"]?.line?.text == "blocked · The rebase conflicted")
        #expect(cards["Cart drawer"]?.opens == .taskWindow(working.id), "a started task: its window")
        #expect(cards["Order summary copy"]?.opens == .nothing, "a Todo task has nothing to open")
        for title in ["Payment provider switch", "Retry failed payments", "Address autocomplete", "Shipping step"] {
            #expect(cards[title]?.needsYou == true, "\(title) needs you")
        }
        #expect(cards["Cart drawer"]?.needsYou == false && cards["Order summary copy"]?.needsYou == false)

        // The Operator acting on a card says so there.
        let acting = OperatorActs(tasks: [working.id: .answering], runs: [asking.id: .init(act: .answering, task: "PAY-231")])
        let answering = BroadcastBoard.make(run: asking, state: state, acting: acting, requests: requests)
        let line = answering.columns.flatMap(\.cards).first { $0.id == working.id }?.line
        #expect(line?.text == "answering Claude" && line?.look == .acting)
    }

    @Test func theCardsTooltipCarriesTheModelAndItsReason() throws {
        let run = run()
        var task = task("Payment provider switch", run: run.id, .working, agent: .codex)
        task.model = "gpt-5.5"
        task.reasoning = "high"
        task.operated?.modelReason = "The provider's SDK is new; Codex has read it."
        let card = try #require(BroadcastBoard.make(run: run, state: state(run, [task]), acting: .none, requests: [])
            .columns.flatMap(\.cards).first)
        #expect(card.modelTooltip == "Codex · gpt-5.5 · high\nThe provider's SDK is new; Codex has read it.")
        task.reasoning = nil
        task.operated?.modelReason = nil
        let plain = try #require(BroadcastBoard.make(run: run, state: state(run, [task]), acting: .none, requests: [])
            .columns.flatMap(\.cards).first)
        #expect(plain.modelTooltip == "Codex · gpt-5.5")
    }

    @Test func takenOverCardReadsTakenOver() throws {
        let run = run()
        let mine = task("Order summary copy", jira: "PAY-234", run: run.id, .working, takenOver: true)
        let board = BroadcastBoard.make(run: run, state: state(run, [mine]), acting: .none, requests: [])
        #expect(column(board, .inProgress) == ["Order summary copy"], "it stays in its column")
        let card = try #require(board.columns.flatMap(\.cards).first)
        #expect(card.takenOver)
        #expect(card.line == nil, "no badge until you Hand Back")
        #expect(!card.needsYou)
        #expect(card.opens == .taskWindow(mine.id))
    }

    @Test func theDebriefListsEveryDeliveredTask() throws {
        var run = run(.complete)
        run.decisions = [OperatorDecision(key: "d1", text: "Added Retry failed payments (PAY-240)", task: nil, at: OperatorUIFixtures.epoch,
                                          why: "The provider switch left failed payments with no retry."),
                         OperatorDecision(key: "d2", text: "Kept the old button behind a flag", task: nil, at: OperatorUIFixtures.epoch,
                                          why: "PAY-231’s ticket didn’t say.", objection: "The flag is dead code."),
                         OperatorDecision(key: "d3", text: "Kept the subtitle", task: nil, at: OperatorUIFixtures.epoch,
                                          objection: "It repeats the title.")]
        run.finds = [OffBriefFind(key: "f1", title: "An API key in payments-api's test fixtures", why: "A live-looking key.", ticket: "PAY-250")]
        run.leftForYou = ["Marking !412 ready is yours."]
        var layout = task("Checkout layout", jira: "PAY-230", run: run.id, .published, end: .merge)
        layout.mr = MergeRequestRef(iid: 412, title: "Checkout layout", url: "https://gitlab.example/shop/-/merge_requests/412")
        layout.model = "opus"
        layout.operated?.modelReason = "Layout work."
        let drawer = task("Cart drawer", jira: "PAY-231", run: run.id, .accepted, agent: .codex)
        let nothing = task("Already done", run: run.id, .noChange, started: false)
        let state = state(run, [layout, drawer, nothing, task("You stopped it", run: run.id, .stopped)])
        let board = BroadcastBoard.make(run: run, state: state, acting: .none, requests: [])
        let debrief = try #require(board.debrief)
        #expect(debrief.delivered.map(\.title) == ["Checkout layout", "Cart drawer", "Already done"])
        #expect(debrief.delivered.map(\.result) == ["merged · 9b3e07d", "done · 9b3e07d", "done · no change"])
        #expect(debrief.delivered.map(\.agent) == [.claude, .codex, .claude], "every row wears its agent's mark")
        #expect(debrief.delivered.last?.opens == .taskWindow(nothing.id))
        #expect(debrief.delivered.first?.ticket == "PAY-230" && debrief.delivered.first?.mr == "!412")
        #expect(debrief.delivered.first?.mrHost == .gitLab)
        #expect(debrief.delivered.first?.modelTooltip == "Claude · opus\nLayout work.")
        #expect(debrief.delivered.first?.opens == .taskWindow(layout.id), "a row opens its task's window, as a card does")
        #expect(debrief.decided == run.decisions)
        #expect(debrief.decided.first?.why == "The provider switch left failed payments with no retry.")
        #expect(debrief.decided.map(\.reason) == ["The provider switch left failed payments with no retry.",
                                                  "PAY-231’s ticket didn’t say. The Oracle objected: “The flag is dead code.”",
                                                  "The Oracle objected: “It repeats the title.”"])
        #expect(OperatorDecision(key: "k", text: "t", task: nil, at: OperatorUIFixtures.epoch).reason == nil)
        #expect(debrief.finds == run.finds)
        #expect(debrief.leftForYou == ["Marking !412 ready is yours."])
        #expect(debrief.sections == [.decided, .finds, .leftForYou])
        #expect(board.band.text == "done · debrief ready")

        // A task waiting on a person keeps the board.
        var waiting = self.run()
        waiting.state = .active
        var reviewed = task("Shipping step", run: waiting.id, .inReview)
        reviewed.operated?.peopleReview = PeopleReview(reviewers: ["Jan"])
        #expect(BroadcastBoard.make(run: waiting, state: self.state(waiting, [reviewed]), acting: .none, requests: []).debrief == nil)
    }

    @Test func emptyDebriefListsAreLeftOut() throws {
        let run = run(.complete)
        let board = BroadcastBoard.make(run: run, state: state(run, [task("Checkout layout", run: run.id, .accepted)]),
                                        acting: .none, requests: [])
        let debrief = try #require(board.debrief)
        #expect(debrief.sections.isEmpty, "nothing decided, found or left: no list")
        var found = run
        found.finds = [OffBriefFind(key: "f1", title: "A flaky cart test on main", why: "Fails one run in five.")]
        let some = try #require(BroadcastBoard.make(run: found, state: state(found, [task("Checkout layout", run: found.id, .accepted)]),
                                                    acting: .none, requests: []).debrief)
        #expect(some.sections == [.finds])
    }

    @Test func aPauseOrAClosedWindowIsPaused() {
        #expect(BroadcastBoard.make(run: run(.paused), state: state(run(.paused)), acting: .none, requests: []).isPaused)
        #expect(BroadcastBoard.make(run: run(.operatorOffline), state: state(run(.operatorOffline)), acting: .none, requests: []).isPaused)
        #expect(!BroadcastBoard.make(run: run(), state: state(run()), acting: .none, requests: []).isPaused)
    }

    /// A card whose task has several worker tabs lists each under a hairline (P5 A): its agent, its key (`main` for the
    /// first worker), what it does and its mark. A tab's click closes the board and brings that tab forward; a closed
    /// tab is listed, muted, and is no button. A task with one tab lists none.
    @Test func aCardListsItsWorkerTabs() throws {
        let run = run()
        var price = task("Price formatting", jira: "PAY-236", run: run.id, .working, agent: .codex)
        price.operated?.extraTabs = [OperatorUIFixtures.extraTab("docs", agent: .claude), OperatorUIFixtures.extraTab("api-mocks", agent: .claude),
                                     OperatorUIFixtures.extraTab("e2e-tests", opened: false)]
        let drawer = task("Cart drawer", jira: "PAY-231", run: run.id, .working)
        let sessions = [OperatorUIFixtures.tab("s1", of: price, .idle, agent: .codex),
                        OperatorUIFixtures.tab("s2", of: price, .needsInput, index: 1, key: "docs"),
                        OperatorUIFixtures.tab("s9", of: drawer, .working)]
        let board = BroadcastBoard.make(run: run, state: state(run, [price, drawer]), acting: .none, requests: [], sessions: sessions)
        let cards = try #require(board.columns.first { $0.column == .inProgress }?.cards)
        let tabs = try #require(cards.first { $0.title == "Price formatting" }?.tabs)
        typealias Tab = BroadcastBoard.Tab
        #expect(tabs == [
            Tab(key: "main", agent: .codex, line: OperatorLine("turn ended"), status: .idle, opens: .tab(task: price.id, sessionId: "s1")),
            Tab(key: "docs", agent: .claude, line: OperatorLine("waiting on you", look: .needsYou), status: .needsInput,
                opens: .tab(task: price.id, sessionId: "s2")),
            Tab(key: "api-mocks", agent: .claude, line: OperatorLine("closed"), status: nil, opens: .nothing),
            Tab(key: "e2e-tests", agent: .codex, line: OperatorLine("opening"), status: .working, opens: .nothing),
        ])
        #expect(tabs.map(\.isClosed) == [false, false, true, false])
        #expect(cards.first { $0.title == "Cart drawer" }?.tabs == [], "one tab: nothing to tell apart")
        #expect(cards.first { $0.title == "Price formatting" }?.line == OperatorLine("monitoring 3 tabs", look: .acting))
        // At work, its words say so.
        let working = BroadcastBoard.make(run: run, state: state(run, [price]), acting: .none, requests: [],
                                          sessions: [OperatorUIFixtures.tab("s1", of: price, .working, agent: .codex)])
        #expect(working.columns.flatMap(\.cards).first?.tabs.first?.line == OperatorLine("at work"))
    }
}
