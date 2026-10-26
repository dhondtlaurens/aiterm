import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The broadcast's board as a value (spec §4, §4.2, §13): the header restating the brief, the columns
/// Todo · In progress · Review · Done with each task's card where its state puts it, what a card opens,
/// and what its tabs read: the summary, what is left for you, and the shelved form of an ended broadcast.
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

    @Test func anOracleRefusalKeepsTheReviewStatusAndAddsASeparateNote() throws {
        let run = run()
        var task = task("Review me", run: run.id, .inReview)
        task.operated?.publication = TaskPublication(mergeRefusal: "Jan has not approved it.")
        let board = BroadcastBoard.make(run: run, state: state(run, [task]), acting: .none, requests: [])
        let card = try #require(board.columns.first { $0.column == .review }?.cards.first)
        #expect(card.line?.text == "in review")
        #expect(card.mergeRefusal == "Jan has not approved it.")
        #expect(!card.needsYou)
    }

    @Test func anOracleRefusalOfAnAcceptedMergeSaysNothingIsMerging() throws {
        let run = run()
        var task = task("Merge me", run: run.id, .accepted, end: .merge)
        task.operated?.publication = TaskPublication(mergeRefusal: "Jan has not approved it.")
        let board = BroadcastBoard.make(run: run, state: state(run, [task]), acting: .none, requests: [])
        let card = try #require(board.columns.flatMap(\.cards).first)
        #expect(card.line?.text == "waiting to merge · refused by the Oracle")
        #expect(card.line?.look == .quiet)
        #expect(card.mergeRefusal == "Jan has not approved it.")
        #expect(!card.needsYou)
    }

    @Test func theHeaderRestatesTheBrief() throws {
        let run = run()
        let tasks = [task("Checkout layout", jira: "PAY-230", run: run.id, .published, end: .merge),
                     task("Cart drawer", jira: "PAY-231", run: run.id, .working)]
            + (0..<6).map { task("Later \($0)", run: run.id, .queued) }
        let board = BroadcastBoard.make(run: run, state: state(run, tasks), acting: .none, requests: [])
        #expect(board.title == "Checkout redesign")
        #expect(board.band == OperatorLine("1 working", look: .acting))
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
        let requests = OperatorRequests.open(run: asking, state: state)
        let board = BroadcastBoard.make(run: asking, state: state, acting: .none, requests: requests)
        let cards = Dictionary(uniqueKeysWithValues: board.columns.flatMap(\.cards).map { ($0.title, $0) })

        #expect(cards["Payment provider switch"]?.opens == .taskWindow(permission.id), "a permission prompt: the task's window")
        #expect(cards["Payment provider switch"]?.line?.text == "waiting on you")
        // A question the Operator asks about a task is the Operator's row's (2A, 22 Oct 2026): the card goes on with its task.
        #expect(cards["Retry failed payments"]?.opens == .taskWindow(question.id), "a question: the Operator's row's, not the card's")
        #expect(cards["Retry failed payments"]?.line?.text == "Operator watching")
        #expect(cards["Address autocomplete"]?.opens == .operatorWindow, "blocked: the Operator's window")
        #expect(cards["Shipping step"]?.opens == .sidebarBanner(issue: "issue-7"), "AiTerm's problem: the banner's Notice")
        #expect(cards["Shipping step"]?.line?.text == "blocked · The rebase conflicted")
        #expect(cards["Cart drawer"]?.opens == .taskWindow(working.id), "a started task: its window")
        #expect(cards["Order summary copy"]?.opens == .nothing, "a Todo task has nothing to open")
        for title in ["Payment provider switch", "Address autocomplete", "Shipping step"] {
            #expect(cards[title]?.needsYou == true, "\(title) needs you")
        }
        #expect(cards["Cart drawer"]?.needsYou == false && cards["Order summary copy"]?.needsYou == false)
        #expect(cards["Retry failed payments"]?.needsYou == false)

        // The Operator acting on a card says so there.
        let acting = OperatorActs(tasks: [working.id: .answering], runs: [asking.id: .init(act: .answering, task: "PAY-231")])
        let answering = BroadcastBoard.make(run: asking, state: state, acting: acting, requests: requests)
        let line = answering.columns.flatMap(\.cards).first { $0.id == working.id }?.line
        #expect(line?.text == "Operator answering" && line?.look == .acting)
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

    /// Once its Claude worker says it runs another model or effort than planned, the tooltip says so under the Operator's
    /// choice. The plan's own, a model of the family a planned alias names (`opus`), any effort when none was planned
    /// (Claude Code's default then), and a Codex worker's own word add nothing. The board is handed the tabs as the rows
    /// read them, with no model, and what each first worker runs beside them, as the sidebar hands them in.
    @Test func theCardsTooltipSaysWhatItsClaudeWorkerRunsNow() throws {
        let run = run()
        var task = task("Payment provider switch", run: run.id, .working)
        task.operated?.modelReason = "A wide refactor."
        func tooltip(planned: String = "claude-fable-5-1[1m]", effort: String? = "max", agent: SessionAgent = .claude,
                     now model: String?, _ reasoning: String?) throws -> String? {
            task.model = planned
            task.reasoning = effort
            var worker = OperatorUIFixtures.tab("s1", of: task, .working, agent: agent)
            worker.model = model
            worker.reasoning = reasoning
            let state = state(run, [task])
            let board = BroadcastBoard.make(run: run, state: state, acting: .none, requests: [], sessions: [worker.rowRelevant],
                                            liveModels: BroadcastBoard.liveModels(of: run, state: state, sessions: [worker]))
            return try #require(board.columns.flatMap(\.cards).first).modelTooltip
        }
        #expect(try tooltip(now: "claude-opus-5-5", "high") == "Claude · claude-fable-5-1[1m] · max\nA wide refactor.\nNow on claude-opus-5-5 · high")
        #expect(try tooltip(now: "claude-fable-5-1[1m]", "low") == "Claude · claude-fable-5-1[1m] · max\nA wide refactor.\nNow on claude-fable-5-1[1m] · low")
        #expect(try tooltip(now: "claude-fable-5-1[1m]", "max") == "Claude · claude-fable-5-1[1m] · max\nA wide refactor.")
        #expect(try tooltip(now: nil, nil) == "Claude · claude-fable-5-1[1m] · max\nA wide refactor.")
        #expect(try tooltip(agent: .codex, now: "gpt-6-astra", "high") == "Claude · claude-fable-5-1[1m] · max\nA wide refactor.")
        // A planned alias runs as its family's model, and with no effort planned the one it runs is Claude Code's default.
        #expect(try tooltip(planned: "opus", effort: nil, now: "claude-opus-5-5", "high") == "Claude · opus\nA wide refactor.")
        #expect(try tooltip(planned: "opus", effort: "high", now: "claude-opus-5-5[1m]", "high") == "Claude · opus · high\nA wide refactor.")
        #expect(try tooltip(planned: "opus", effort: "high", now: "claude-opus-5-5", nil) == "Claude · opus · high\nA wide refactor.")
        #expect(try tooltip(planned: "opus", effort: nil, now: "claude-sonnet-5-5", "high")
                == "Claude · opus\nA wide refactor.\nNow on claude-sonnet-5-5 · high")
        #expect(try tooltip(planned: "opus", effort: "high", now: "claude-opus-5-5", "low")
                == "Claude · opus · high\nA wide refactor.\nNow on claude-opus-5-5 · low")
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

    /// Once every task is done the board keeps its columns, everything in Done: the Summary tab holds what the
    /// debrief did, and the board has no value of its own for it.
    @Test func aCompleteRunKeepsItsColumnsAndOpensOnItsSummary() throws {
        var run = run(.complete)
        run.leftForYou = ["Marking !412 ready is yours."]
        run.completedAt = OperatorUIFixtures.epoch
        var layout = task("Checkout layout", jira: "PAY-230", run: run.id, .published, end: .merge)
        layout.mr = MergeRequestRef(iid: 412, title: "Checkout layout", url: "https://gitlab.example/shop/-/merge_requests/412")
        let drawer = task("Cart drawer", jira: "PAY-231", run: run.id, .accepted, agent: .codex)
        let nothing = task("Already done", run: run.id, .noChange, started: false)
        let state = state(run, [layout, drawer, nothing, task("You stopped it", run: run.id, .stopped)])
        let board = BroadcastBoard.make(run: run, state: state, acting: .none, requests: [])
        #expect(column(board, .done) == ["Checkout layout", "Cart drawer", "Already done"])
        #expect(column(board, .todo).isEmpty && column(board, .inProgress).isEmpty && column(board, .review).isEmpty)
        let cards = board.columns.flatMap(\.cards)
        #expect(cards.map(\.result) == ["merged · 9b3e07d", "done · 9b3e07d", "done · no change"])
        #expect(cards.first?.mr == "!412" && cards.first?.opens == .taskWindow(layout.id))
        #expect(board.isComplete && !board.isShelved)
        #expect(board.band.text == "done · writing summary", "every task done, no summary written yet")
        #expect(board.leftForYou == ["Marking !412 ready is yours."])
        #expect(board.summary == .writing)
        #expect(board.firstTab == .summary)
        #expect(board.isSelectable(.summary) && board.isSelectable(.board) && board.isSelectable(.activity))

        // A task waiting on a person keeps the run going, on its Board.
        var waiting = self.run()
        waiting.state = .active
        var reviewed = task("Shipping step", run: waiting.id, .inReview)
        reviewed.operated?.peopleReview = PeopleReview(reviewers: ["Jan"])
        let working = BroadcastBoard.make(run: waiting, state: self.state(waiting, [reviewed]), acting: .none, requests: [])
        #expect(!working.isComplete)
    }

    /// The tabs: Board · Activity · Summary. A running broadcast opens on its Board and has no Summary to select;
    /// a written one opens on its Summary.
    @Test func theBoardOpensOnItsSummaryOnceThereIsOne() {
        #expect(BroadcastBoard.Tab.allCases == [.board, .activity, .summary])
        #expect(BroadcastBoard.Tab.allCases.map(\.title) == ["Board", "Activity", "Summary"])
        let running = BroadcastBoard.make(run: run(), state: state(run()), acting: .none, requests: [])
        #expect(running.summary == .notYet)
        #expect(running.firstTab == .board)
        #expect(running.isSelectable(.board) && running.isSelectable(.activity))
        #expect(!running.isSelectable(.summary), "nothing to read while it works")
        #expect(!running.isComplete && !running.isShelved)
        #expect(running.leftForYou.isEmpty)

        var written = run(.complete)
        written.completedAt = OperatorUIFixtures.epoch
        written.summary = "Everything merged."
        written.summaryAt = OperatorUIFixtures.epoch
        let board = BroadcastBoard.make(run: written, state: state(written), acting: .none, requests: [])
        #expect(board.summary == .written(text: "Everything merged.", at: OperatorUIFixtures.epoch))
        #expect(board.firstTab == .summary && board.isSelectable(.summary))
    }

    /// End's change to `state`, as `OperatorController.applyEnd` makes it: the run stopped, the tasks that never started
    /// dropped, those started and still open stopped and yours.
    private func ended(_ id: UUID, in state: inout AppState) {
        state.updateRun(id: id) { $0.intent = .stopped; $0.state = .stopped; $0.endedAt = OperatorUIFixtures.epoch }
        for task in state.tasks(inRun: id) {
            guard let operated = task.operated else { continue }
            if !operated.started, !task.hasCheckout { state.tasks.removeAll { $0.id == task.id } }
            else if operated.state.isOpen {
                _ = try? OperatedTransitions.apply(.stop, toTask: task.id, in: &state, by: .you)
                guard let index = state.tasks.firstIndex(where: { $0.id == task.id }) else { continue }
                state.tasks[index].operated?.takenOver = true
                state.tasks[index].operated?.ownership += 1
            }
        }
    }

    /// An ended broadcast, read from the Shelf: every task it drove, the live and the archived, in the order they were
    /// created, no card a button and no worker tab listed, never paused, opening on its Summary. What End handed you
    /// mid-flight stays In progress, taken over, and counts towards the total but not as done.
    @Test func aShelvedBoardListsLiveAndArchivedTasksAndOpensNothing() throws {
        var run = run(.active)
        run.leftForYou = ["Marking !412 ready is yours."]
        func dated(_ item: TaskItem, _ seconds: TimeInterval) -> TaskItem {
            var item = item
            item.createdAt = Date(timeIntervalSince1970: seconds)
            return item
        }
        var price = dated(task("Price formatting", run: run.id, .working, agent: .codex), 40)
        price.operated?.extraTabs = [OperatorUIFixtures.extraTab("docs", agent: .claude)]
        var unstarted = dated(task("Order summary copy", run: run.id, .queued), 50)
        unstarted.worktreePath = ""
        let live = [dated(task("Cart drawer", run: run.id, .working), 20), price, unstarted]
        let archived = [dated(task("Checkout layout", jira: "PAY-230", run: run.id, .published, end: .merge), 10),
                        dated(task("Shipping step", run: run.id, .accepted), 30),
                        dated(task("Another run's task", run: UUID(), .accepted), 5)]
        var state = state(run, live)
        state.archive = archived.map { ArchivedTask(task: $0, archivedAt: OperatorUIFixtures.epoch) }
        ended(run.id, in: &state)
        run = try #require(state.run(id: run.id))
        #expect(state.tasks.map(\.title) == ["Cart drawer", "Price formatting"], "End dropped the task that never started")

        let board = BroadcastBoard.shelved(run: run, state: state)
        let cards = board.columns.flatMap(\.cards)
        #expect(cards.map(\.title).sorted() == ["Cart drawer", "Checkout layout", "Price formatting", "Shipping step"],
                "the live and the archived tasks of this run, no other run's")
        #expect(column(board, .inProgress) == ["Cart drawer", "Price formatting"], "in flight when it ended")
        #expect(column(board, .done) == ["Checkout layout", "Shipping step"], "in the order they were created")
        let handed = cards.filter { $0.takenOver }
        #expect(handed.map(\.title) == ["Cart drawer", "Price formatting"])
        #expect(handed.allSatisfy { $0.line == nil && !$0.needsYou && $0.result == nil }, "they read taken over, nothing more")
        #expect(board.progress == "2 of 4 done", "counted, and not as done")
        #expect(board.band.text == "ended")
        #expect(cards.allSatisfy { $0.opens == .nothing }, "a shelved board opens no window")
        #expect(cards.allSatisfy { $0.tabs.isEmpty })
        #expect(cards.first { $0.title == "Checkout layout" }?.ticket == "PAY-230")
        #expect(board.isShelved && !board.isPaused)
        #expect(board.summary == .endedEarly, "stopped before its plan was done, nothing written")
        #expect(board.firstTab == .summary && board.isSelectable(.summary))
        #expect(board.leftForYou == ["Marking !412 ready is yours."])
        #expect(board.title == "Checkout redesign")

        // The live board keeps its rule: a task stopped and yours is no longer the broadcast's work.
        let liveBoard = BroadcastBoard.make(run: run, state: state, acting: .none, requests: [])
        #expect(column(liveBoard, .inProgress).isEmpty)
        #expect(BroadcastBoard.count(of: run, tasks: state.tasks) == "0 of 0")
    }

    /// A snag as `report_snag` records it.
    private func snag(_ title: String, actual: String = "No prompt was open.", taskKey: String? = nil) -> OperatorSnag {
        OperatorSnag(key: title, title: title, showed: "run_status listed it under promptsWaitingOnYou.", actual: actual,
                     workaround: "Read the task's screen.", taskKey: taskKey, appVersion: "0.28.1", at: OperatorUIFixtures.epoch)
    }

    /// What the Operator worked around in AiTerm is the Summary's too, as `report_snag` kept it, and none with none.
    @Test func theSummaryListsWhatTheOperatorWorkedAround() {
        var run = run(.complete)
        run.completedAt = OperatorUIFixtures.epoch
        #expect(BroadcastBoard.make(run: run, state: state(run), acting: .none, requests: []).snags.isEmpty)
        run.snags = [snag("Waiting on you showed a task with no prompt open", taskKey: "PAY-232"), snag("find_user answered AiTerm isn’t answering")]
        let board = BroadcastBoard.make(run: run, state: state(run), acting: .none, requests: [])
        #expect(board.snags == run.snags)
        #expect(board.fixTask(board.snags[0]) == run.snags[0].fixTask(broadcast: "Checkout redesign", runId: run.id))
    }

    /// An ended broadcast opened from the Shelf keeps what the Operator worked around, each copying as its fix task.
    @Test func aShelvedBroadcastsSummaryShowsItsSnags() throws {
        var run = run(.active)
        run.snags = [snag("Waiting on you showed a task with no prompt open", taskKey: "PAY-232")]
        var state = state(run, [task("Cart drawer", run: run.id, .working)])
        ended(run.id, in: &state)
        let board = BroadcastBoard.shelved(run: try #require(state.run(id: run.id)), state: state)
        #expect(board.isShelved && board.firstTab == .summary)
        #expect(board.snags == run.snags)
        #expect(board.fixTask(board.snags[0]) == run.snags[0].fixTask(broadcast: "Checkout redesign", runId: run.id))
    }

    /// Copy All puts every snag's fix task on the clipboard, in the order they were reported, a rule between each.
    @Test func copyAllJoinsEveryFixTask() {
        var run = run(.complete)
        run.snags = [snag("First"), snag("Second", taskKey: "PAY-232"), snag("Third")]
        let board = BroadcastBoard.make(run: run, state: state(run), acting: .none, requests: [])
        let tasks = run.snags.map { $0.fixTask(broadcast: "Checkout redesign", runId: run.id) }
        #expect(board.copyAll == tasks.joined(separator: "\n\n---\n\n"))
        #expect(board.copyAll?.components(separatedBy: "\n\n---\n\n").count == 3)
    }

    /// With one snag its own Copy is all there is to copy, so there is no Copy All; with none, nothing.
    @Test func copyAllIsLeftOutWithOneSnag() {
        var run = run(.complete)
        #expect(BroadcastBoard.make(run: run, state: state(run), acting: .none, requests: []).copyAll == nil)
        run.snags = [snag("Only")]
        #expect(BroadcastBoard.make(run: run, state: state(run), acting: .none, requests: []).copyAll == nil)
        run.snags.append(snag("Another"))
        #expect(BroadcastBoard.make(run: run, state: state(run), acting: .none, requests: []).copyAll != nil)
    }

    /// With no creation order to tell them apart, the live tasks come first and the archived ones after, each in its own order.
    @Test func aShelvedBoardKeepsTheStateOrderWhenCreatedTogether() {
        var run = run(.stopped)
        run.endedAt = OperatorUIFixtures.epoch
        var state = state(run, [task("Live one", run: run.id, .accepted), task("Live two", run: run.id, .accepted)])
        state.archive = [ArchivedTask(task: task("Archived one", run: run.id, .accepted), archivedAt: OperatorUIFixtures.epoch),
                         ArchivedTask(task: task("Archived two", run: run.id, .accepted), archivedAt: OperatorUIFixtures.epoch)]
        #expect(column(BroadcastBoard.shelved(run: run, state: state), .done) == ["Live one", "Live two", "Archived one", "Archived two"])
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
        typealias Tab = BroadcastBoard.TabLine
        #expect(tabs == [
            Tab(key: "main", agent: .codex, line: OperatorLine("turn ended"), status: .idle, opens: .tab(task: price.id, sessionId: "s1")),
            Tab(key: "docs", agent: .claude, line: OperatorLine("waiting on you", look: .needsYou), status: .needsInput,
                opens: .tab(task: price.id, sessionId: "s2")),
            Tab(key: "api-mocks", agent: .claude, line: OperatorLine("closed"), status: nil, opens: .nothing),
            Tab(key: "e2e-tests", agent: .codex, line: OperatorLine("opening"), status: .working, opens: .nothing),
        ])
        #expect(tabs.map(\.isClosed) == [false, false, true, false])
        #expect(cards.first { $0.title == "Cart drawer" }?.tabs == [], "one tab: nothing to tell apart")
        #expect(cards.first { $0.title == "Price formatting" }?.line == OperatorLine("Operator watching · 3 tabs", look: .acting))
        // At work, its words say so.
        let working = BroadcastBoard.make(run: run, state: state(run, [price]), acting: .none, requests: [],
                                          sessions: [OperatorUIFixtures.tab("s1", of: price, .working, agent: .codex)])
        #expect(working.columns.flatMap(\.cards).first?.tabs.first?.line == OperatorLine("at work"))
    }

    /// An accepted task whose end is still ahead is not done: it counts as open and stays In progress.
    @Test func acceptedPublicationStillNeedsItsEnd() {
        var run = OperatorFixtures.run()
        run.firstPlanSize = 1
        var task = OperatorFixtures.task("PAY-1", .accepted, run: run.id)
        task.operated?.end = .merge
        task.operated?.acceptance = TaskAcceptance(resultSHA: "4f2a91c", prerequisiteSHAs: [], checkOutput: "passed", note: nil, at: OperatorFixtures.epoch)
        let state = OperatorFixtures.state(run, [task])
        #expect(BroadcastBoard.progress(of: run, tasks: [task]) == "0 of 1 done")
        #expect(OperatorLine.ending(of: task.operated!) == nil)
        let board = BroadcastBoard.make(run: run, state: state, acting: OperatorActs(), requests: [])
        #expect(board.columns.first { $0.column == .inProgress }?.cards.count == 1)
    }

    /// A publication left for you is the task's end: Done on the board, the broadcast complete, kept through coding.
    @Test func leftForYouReachesTheEndAndSurvivesCoding() throws {
        let run = OperatorFixtures.run()
        var task = OperatorFixtures.task("PAY-1", .accepted, run: run.id, end: .draftMR)
        task.operated?.acceptance = OperatorFixtures.acceptance()
        task.operated?.publication = TaskPublication(leftForYou: true)
        let decoded = try JSONDecoder().decode(TaskPublication.self, from: JSONEncoder().encode(task.operated!.publication!))
        #expect(decoded.leftForYou)
        let board = BroadcastBoard.make(run: run, state: OperatorFixtures.state(run, [task]), acting: .none, requests: [])
        #expect(board.columns.first { $0.column == .done }?.cards.count == 1)
        #expect(RunScheduler.isComplete(run, in: OperatorFixtures.state(run, [task])))
        #expect(OperatorLine.ending(of: task.operated!) == "left for you · 4f2a91c")
    }
}
