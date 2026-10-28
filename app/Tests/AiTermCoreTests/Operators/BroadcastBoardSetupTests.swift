import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The board of a broadcast set up with the Agents, Task and Done steps (broadcast setup v2, Board): the combination and
/// end lines, status lines worked out from the current end, the header's Goal and Each task lines, the new stops, cards
/// drawn from the records of closed tasks, and the goal's outcome. A legacy run's board is as it was.
@Suite struct BroadcastBoardSetupTests {
    private let web = OperatorUIFixtures.project("webshop"), api = OperatorUIFixtures.project("payments-api")

    private func run(_ state: OperatorRunState = .active, merge: Bool = true, settings: TaskSettings? = OperatorUIFixtures.taskSettings,
                     goal: BroadcastGoal? = OperatorUIFixtures.goal, questions: [OperatorQuestion] = []) -> OperatorRun {
        var profile = OperatorUIFixtures.profile
        profile.slices = Slices(merge: merge)
        var run = OperatorUIFixtures.run(name: "Checkout redesign", profile: profile, state: state, questions: questions,
                                         projectIds: [web.id], agents: OperatorUIFixtures.agents, taskSettings: settings, goal: goal)
        run.prompt = "implement PAY-230 to PAY-236, the new checkout"
        run.firstPlanSize = 3
        return run
    }

    private func state(_ run: OperatorRun, _ tasks: [TaskItem]) -> AppState {
        var state = AppState()
        for project in [web, api] { state.append(project: project) }
        state.runs = [run]
        state.tasks = tasks
        return state
    }

    private func task(_ title: String, jira: String? = nil, run: OperatorRun, _ state: OperatedState, end: TaskEnd = .draftMR,
                      agent: AgentKind = .claude, model: String = "claude-opus-5-5", reasoning: String? = "high") -> TaskItem {
        var operated = OperatorUIFixtures.operated(run: run.id, key: jira ?? title, state: state, end: end,
                                                   sha: [.accepted, .noChange, .published].contains(state) ? "9b3e07d11" : nil)
        if ![.planned, .queued].contains(state) {
            operated.launch = LaunchAttempt(number: 1, requestedAt: OperatorUIFixtures.epoch, openedAt: OperatorUIFixtures.epoch)
        }
        var task = OperatorUIFixtures.task(title, jira: jira, agent: agent, project: web.id, operated: operated)
        task.model = model
        task.reasoning = reasoning
        return task
    }

    private func board(_ run: OperatorRun, _ tasks: [TaskItem], requests: [BroadcastRequest] = [],
                       sessions: [SessionInfo] = []) -> BroadcastBoard {
        BroadcastBoard.make(run: run, state: state(run, tasks), acting: .none, requests: requests, sessions: sessions)
    }

    private func card(_ board: BroadcastBoard, _ title: String) throws -> BroadcastBoard.Card {
        try #require(board.columns.flatMap(\.cards).first { $0.title == title })
    }

    // -- the combination and the end (14A, 17A) ---------------------------------------------------------------------------

    @Test func aRunningCardSaysItsCombinationAndItsEnd() throws {
        let run = run(merge: false)
        let tasks = [task("Cart drawer", jira: "PAY-231", run: run, .working),
                     task("Payment provider switch", run: run, .working, agent: .codex, model: "gpt-6-astra", reasoning: "medium"),
                     task("Price formatting", run: run, .published)]
        let board = board(run, tasks)
        let drawer = try card(board, "Cart drawer")
        #expect(drawer.combination == "claude-opus-5-5 · High")
        #expect(drawer.end == BroadcastBoard.EndLine(current: .draftMR, selectable: [.commit, .draftMR]),
                "Merge and Local merge can't be picked while the Merge slice is off")
        #expect(try card(board, "Payment provider switch").combination == "gpt-6-astra · Medium", "a long model, whole")
        let done = try card(board, "Price formatting")
        #expect(done.end == nil, "the end line goes once the task finishes")
        #expect(done.combination == "claude-opus-5-5 · High")
        var merging = self.run()
        merging.id = run.id
        #expect(try card(self.board(merging, [tasks[0]]), "Cart drawer").end?.selectable == TaskEnd.allCases)
    }

    @Test func aCardWithSeveralTabsPutsEachCombinationUnderItsKey() throws {
        let run = run()
        var drawer = task("Cart drawer", run: run, .working)
        var tests = OperatorUIFixtures.extraTab("e2e-tests")
        tests.model = "gpt-6-astra"; tests.reasoning = "medium"
        drawer.operated?.extraTabs = [tests]
        let sessions = [OperatorUIFixtures.tab("s1", of: drawer, .working),
                        OperatorUIFixtures.tab("s2", of: drawer, .idle, index: 1, key: "e2e-tests", agent: .codex)]
        let card = try card(board(run, [drawer], sessions: sessions), "Cart drawer")
        #expect(card.combination == nil, "each tab says its own")
        #expect(card.tabs.map(\.combination) == ["claude-opus-5-5 · High", "gpt-6-astra · Medium"])
        #expect(card.end?.current == .draftMR, "the end stays on the card's own line")
    }

    @Test func aLegacyRunsCardIsAsItWas() throws {
        var legacy = run(settings: nil, goal: nil)
        legacy.agents = []
        legacy.review = "assign Jan"
        legacy.done = "merged after Jan's approval"
        let board = board(legacy, [task("Cart drawer", run: legacy, .working)])
        let card = try card(board, "Cart drawer")
        #expect(card.combination == nil && card.end == nil && card.notice == nil && card.fixRounds == nil)
        #expect(board.clauses.map(\.label) == ["Asked", "Review", "Done"])
        #expect(board.eachTask == nil)
    }

    // -- status lines from the current end --------------------------------------------------------------------------------

    @Test func aStatusLineIsWorkedOutFromTheCurrentEnd() throws {
        let run = run()
        // An end changed from Merge to Draft MR with the merge's wait and refusal left behind: neither is said.
        var drawer = task("Cart drawer", run: run, .accepted, end: .draftMR)
        drawer.operated?.publication = TaskPublication(waitingSince: OperatorUIFixtures.epoch, waitingReason: "pipeline running",
                                                       mergeRefusal: "Jan has not approved it.")
        let card = try card(board(run, [drawer]), "Cart drawer")
        #expect(card.line?.text == "accepted · not finished")
        #expect(card.mergeRefusal == nil)
        // On a merge end the same publication still says it.
        drawer.operated?.end = .merge
        let merging = try self.card(board(run, [drawer]), "Cart drawer")
        #expect(merging.line?.text == "waiting to merge · pipeline running")
        #expect(merging.mergeRefusal == "Jan has not approved it.")
        drawer.operated?.end = .mergeLocal
        drawer.operated?.publication?.waitingSince = nil
        #expect(try self.card(board(run, [drawer]), "Cart drawer").line?.text == "waiting to merge · refused by the Oracle")
    }

    // -- the header (15A) -------------------------------------------------------------------------------------------------

    @Test func theHeaderSaysTheGoalAndWhatEachTaskFollows() {
        let board = board(run(), [])
        #expect(board.clauses == [BroadcastBoard.Clause(label: "Asked", text: "implement PAY-230 to PAY-236, the new checkout"),
                                  BroadcastBoard.Clause(label: "Goal", text: "The newsletter signup works end to end on staging.")])
        #expect(board.eachTask == BroadcastBoard.Clause(
            label: "Each task",
            text: "“An adversarial review with /code-review. It passes with no Critical or Important findings. After 3 rounds of "
                + "fixes, ask me.” · ends at draft MR · closed at the end"))
        #expect(board.eachTaskWhole.hasPrefix("Each task “An adversarial review"))

        let plain = self.board(run(settings: TaskSettings(review: "  ", end: .commit, closeWhenDone: false), goal: nil), [])
        #expect(plain.clauses.map(\.label) == ["Asked"])
        #expect(plain.eachTask == BroadcastBoard.Clause(label: "Each task", text: "ends at commit"))
    }

    @Test func theBandChecksTheGoalAndSaysHowItEnded() throws {
        var checking = run()
        checking.goalCheckDue = true
        checking.roundsUsed = 1
        let done = [task("Cart drawer", run: checking, .published), task("Shipping step", run: checking, .published),
                    task("Price formatting", run: checking, .published)]
        let board = board(checking, done)
        #expect(board.band == OperatorLine("checking the goal", look: .acting))
        #expect(board.progress == "3 of 3 done · round 1 of 2")
        checking.roundsUsed = 0
        #expect(self.board(checking, done).progress == "3 of 3 done", "the first check is of the plan, in no round yet")

        var ended = checking
        ended.goalCheckDue = false
        ended.state = .stopped
        ended.endedAt = OperatorUIFixtures.epoch
        ended.goalOutcome = .notMet
        ended.leftForYou = ["Add the coupon field", "Wire the analytics"]
        let shelved = BroadcastBoard.shelved(run: ended, state: state(ended, done))
        #expect(shelved.band == OperatorLine("ended · goal not met"))
        #expect(shelved.progress == "3 of 3 done · 2 left for you")
        #expect(shelved.goalOutcome == .notMet)
        ended.goalOutcome = .unchecked
        #expect(BroadcastBoard.shelved(run: ended, state: state(ended, done)).band.text == "ended · goal not checked by the Oracle")
        ended.goalOutcome = .met
        ended.leftForYou = []
        let met = BroadcastBoard.shelved(run: ended, state: state(ended, done))
        #expect(met.band.text == "ended · goal met" && met.progress == "3 of 3 done")
    }

    // -- the new stops (16) -----------------------------------------------------------------------------------------------

    @Test func aTaskInReviewCountsItsRounds() throws {
        let run = run()
        var drawer = task("Address autocomplete", run: run, .working)
        var review = OperatorUIFixtures.extraTab("review")
        review.role = .review
        drawer.operated?.extraTabs = [review]
        let sessions = [OperatorUIFixtures.tab("s1", of: drawer, .idle),
                        OperatorUIFixtures.tab("s2", of: drawer, .working, index: 1, key: "review", agent: .codex)]
        // No verdict yet: today's words.
        #expect(try card(board(run, [drawer], sessions: sessions), "Address autocomplete").line?.text == "Operator watching · 2 tabs")
        drawer.operated?.reviewVerdicts = [OperatorUIFixtures.verdict(passed: false, round: 1, important: 2),
                                           OperatorUIFixtures.verdict(passed: false, round: 2, important: 1)]
        let card = try card(board(run, [drawer], sessions: sessions), "Address autocomplete")
        #expect(card.line == OperatorLine("in review · round 2 of 3", look: .acting))
        #expect(card.tabs.map(\.key) == ["main", "review"], "its review tab listed like any other")
        // A prompt that names no rounds: today's words.
        let unnamed: [ReviewVerdict] = (drawer.operated?.reviewVerdicts ?? []).map { var verdict = $0; verdict.rounds = nil; return verdict }
        drawer.operated?.reviewVerdicts = unnamed
        #expect(try self.card(board(run, [drawer], sessions: sessions), "Address autocomplete").line?.text == "Operator watching · 2 tabs")
    }

    @Test func aTaskOutOfFixRoundsAsksYouOnItsCard() throws {
        var question = OperatorUIFixtures.question("Address autocomplete is out of fix rounds: one more, or accept it?", id: "fix-pay-233")
        var run = run()
        var drawer = task("Address autocomplete", run: run, .working)
        question.task = drawer.id
        question.about = OperatorQuestion.fixRounds
        drawer.operated?.reviewVerdicts = [OperatorUIFixtures.verdict("4f2a91c7d", passed: false, round: 3, important: 1)]
        run.questions = [question]
        let requests = OperatorRequests.open(run: run, state: state(run, [drawer]))
        let card = try card(board(run, [drawer], requests: requests), "Address autocomplete")
        #expect(card.line == OperatorLine("out of fix rounds", look: .needsYou, tooltip: question.text))
        #expect(card.needsYou)
        #expect(card.fixRounds == "3 rounds of fixes, and the last review, of 4f2a91c, still found 1 Important.")
        #expect(BroadcastBoard.counts(of: OperatorUIFixtures.verdict(passed: false, round: 1, critical: 1, important: 2, minor: 3))
                == "1 round of fixes, and the last review, of 4f2a91c, still found 1 Critical, 2 Important and 3 Minor.")
        #expect(BroadcastBoard.counts(of: OperatorUIFixtures.verdict(passed: false, round: 2))
                == "2 rounds of fixes, and the last review, of 4f2a91c, didn’t pass.")
        // Answered and resolved, it is gone.
        run.questions[0].resolution = "One more round."
        #expect(try self.card(board(run, [drawer]), "Address autocomplete").fixRounds == nil)
    }

    @Test func aKeptWorktreeIsSaidOnlyOnceTheClosingRan() throws {
        var run = run(.complete)
        run.completedAt = OperatorUIFixtures.epoch
        let shipping = task("Shipping step", run: run, .published)
        #expect(try card(board(run, [shipping]), "Shipping step").notice == nil, "not closed yet")
        run.closedAt = OperatorUIFixtures.epoch
        let card = try card(board(run, [shipping]), "Shipping step")
        #expect(card.line == OperatorLine("draft MR · worktree kept", look: .ended))
        #expect(card.notice == "Not closed: its worktree has uncommitted changes. Remove it yourself once they are safe.")
        // A task that didn't reach its end isn't closed, so nothing is kept.
        let failed = task("Flaky", run: run, .failed)
        #expect(try self.card(board(run, [failed]), "Flaky").notice == nil)
        // Nor with closing off.
        var open = run
        open.taskSettings?.closeWhenDone = false
        #expect(try self.card(board(open, [shipping]), "Shipping step").notice == nil)
    }

    @Test func aRemovedTasksCardIsDrawnFromItsRecord() throws {
        var run = run(.complete)
        run.completedAt = OperatorUIFixtures.epoch
        run.closedAt = OperatorUIFixtures.epoch
        let layout = task("Checkout layout", jira: "PAY-230", run: run, .published, end: .merge)
        let drawer = task("Cart drawer", run: run, .working)
        run.finished = [OperatorUIFixtures.finished(layout, result: "merged · 9b3e07d")]
        let board = board(run, [drawer])
        let done = try #require(board.columns.first { $0.column == .done })
        let card = try #require(done.cards.first)
        #expect(card.id == layout.id && card.title == "Checkout layout" && card.ticket == "PAY-230" && card.agent == .claude)
        #expect(card.line == OperatorLine("merged · 9b3e07d · removed", look: .ended))
        #expect(card.combination == "claude-opus-5-5 · High")
        #expect(card.opens == .nothing && card.end == nil && !card.needsYou)
        #expect(board.progress == "1 of 2 done", "a removed task still counts")
        #expect(BroadcastBoard.count(of: run, tasks: [drawer]) == "1 of 2")
        // A record of a row still there is that row's card, once.
        let twice = self.board(run, [layout, drawer])
        #expect(twice.columns.flatMap(\.cards).filter { $0.id == layout.id }.count == 1)
        // The Shelf reads it the same.
        var ended = run
        ended.state = .stopped
        ended.endedAt = OperatorUIFixtures.epoch
        let shelved = BroadcastBoard.shelved(run: ended, state: state(ended, []))
        #expect(shelved.columns.first { $0.column == .done }?.cards.first?.line?.text == "merged · 9b3e07d · removed")
    }
}
