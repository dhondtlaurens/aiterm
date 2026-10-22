import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// Everything the Operator says on a status line (spec §7, §13): a closed list of words, quiet while it
/// watches, acting while AiTerm carries out one of its acts, needs-you while something waits on you.
/// A request outranks an act, a detail is cut to fit with the whole of it in the tooltip, and a task you
/// took over has no line at all.
@Suite struct OperatorLineTests {
    private let web = OperatorUIFixtures.project("pluto-web")

    private func task(_ title: String = "The homepage section", id: UUID = UUID(), jira: String? = nil, agent: AgentKind = .claude,
                      run: OperatorRun, key: String = "t", _ state: OperatedState, end: TaskEnd = .commit,
                      dependsOn: [TaskDependency] = [], stackedOn: UUID? = nil, revision: Int = 1, sha: String? = nil,
                      takenOver: Bool = false, reason: String? = nil) -> TaskItem {
        OperatorUIFixtures.task(title, id: id, jira: jira, agent: agent, project: web.id,
                                operated: OperatorUIFixtures.operated(run: run.id, key: key, state: state, end: end, dependsOn: dependsOn,
                                                                      stackedOn: stackedOn, revision: revision, sha: sha,
                                                                      takenOver: takenOver, blockedReason: reason))
    }

    private func request(_ kind: BroadcastRequest.Kind, _ run: OperatorRun, _ task: TaskItem?, _ text: String) -> BroadcastRequest {
        BroadcastRequest(kind: kind, runId: run.id, taskId: task?.id, text: text, key: kind == .question ? UUID().uuidString : nil)
    }

    @Test func aRequestOutranksAnAct() throws {
        let run = OperatorUIFixtures.run()
        let footer = task("Fix the /privacy footer link", agent: .codex, run: run, .working)
        let homepage = task(run: run, key: "pluto-232", .working)
        let asks = request(.permission, run, footer, "Codex asks to run npm install in Fix the /privacy footer link.")
        // The broadcast: the Operator answering one agent while another waits on you reads the request.
        let line = OperatorLine.broadcast(run, tasks: [footer, homepage], acting: (.answering, task: "pluto-232"), requests: [asks])
        #expect(line.text == "waiting on you", "what it asks is the tooltip's: the task's window shows it whole")
        #expect(line.look == .needsYou)
        #expect(line.tooltip == "Codex asks to run npm install in Fix the /privacy footer link.")
        // And a task: its own request outranks what the Operator is doing to it.
        let row = try #require(OperatorLine.task(footer, run: run, acting: .answering, requests: [asks]))
        #expect(row.text == "waiting on you" && row.look == .needsYou)
        // With no request, the act is what the line says, the task it is about named on the broadcast's.
        let acting = OperatorLine.broadcast(run, tasks: [footer, homepage], acting: (.answering, task: "pluto-232"), requests: [])
        #expect(acting == OperatorLine("answering Claude · The homepage section", look: .acting))
    }

    @Test func severalRequestsCount() {
        let run = OperatorUIFixtures.run()
        let footer = task("Fix the /privacy footer link", run: run, .working), bump = task("Bump nuxt", run: run, .blocked, reason: "the tests fail on main")
        let requests = [request(.permission, run, footer, "Claude Code asks for permission in Fix the /privacy footer link."),
                        request(.blocked, run, bump, "Bump nuxt is blocked: the tests fail on main.")]
        let line = OperatorLine.broadcast(run, tasks: [footer, bump], acting: nil, requests: requests)
        #expect(line.text == "waiting on you · 2 tasks")
        #expect(line.look == .needsYou)
        #expect(line.tooltip.contains("Claude Code asks for permission") && line.tooltip.contains("Bump nuxt is blocked"))
        // Two things one task asks are that task's one line, not a count.
        let both = [requests[0], request(.question, run, footer, "The Operator asks: Which retry policy?")]
        #expect(OperatorLine.broadcast(run, tasks: [footer], acting: nil, requests: both).text == "waiting on you")
    }

    @Test func noProgressWhilePlanning() {
        let run = OperatorUIFixtures.run(state: .planning, planRevision: 0)
        let planned = [task(run: run, .planned), task("Write the tests", run: run, .planned)]
        let line = OperatorLine.broadcast(run, tasks: planned, acting: nil, requests: [])
        #expect(line == OperatorLine("loading the construct", look: .acting), "planning is the Operator acting, and says nothing of progress")
        let checking = OperatorLine.broadcast(run, tasks: planned, acting: (.consultingTheOracle, task: nil), requests: [])
        #expect(checking == OperatorLine("consulting the Oracle", look: .acting))
        for line in [line, checking] { #expect(!line.text.contains(" of "), "\(line.text)") }
    }

    @Test func waitingOnAPersonIsQuiet() {
        let run = OperatorUIFixtures.run()
        var reviewed = task(run: run, .inReview)
        reviewed.operated?.peopleReview = PeopleReview(reviewers: ["Jan"])
        let done = task("The schema", run: run, .accepted, sha: "4f2a91cdeadbeef")
        let line = OperatorLine.broadcast(run, tasks: [reviewed, done], acting: nil, requests: [])
        #expect(line == OperatorLine("in review · waiting on Jan"))
        #expect(OperatorLine.task(reviewed, run: run, acting: nil, requests: []) == OperatorLine("in review · waiting on Jan"))
        // With an agent at work the broadcast counts it, as a task state.
        let working = [task(run: run, .working), task(run: run, .working), task(run: run, .working), reviewed]
        #expect(OperatorLine.broadcast(run, tasks: working, acting: nil, requests: []) == OperatorLine("3 working", look: .acting),
                "its tasks work: the line moves")
    }

    /// A task whose workers all ended their turn waits for the Operator to accept it: the line counts it apart
    /// from the tasks still at work (P3, 21 Oct 2026: accepting is the Operator's job, never yours), and once none
    /// works it says how many it has to check, quiet.
    @Test func tasksReadyToAcceptAreCountedApartFromThoseAtWork() {
        let run = OperatorUIFixtures.run()
        let working = [task(run: run, .working), task(run: run, .working)]
        let ready = [task(run: run, .working), task(run: run, .working)]
        func line(_ tasks: [TaskItem], ready: [TaskItem]) -> OperatorLine {
            OperatorLine.broadcast(run, tasks: tasks, acting: nil, requests: [], ready: Set(ready.map(\.id)))
        }
        #expect(line(working + ready.prefix(1), ready: Array(ready.prefix(1)))
                == OperatorLine("2 working · 1 to check", look: .acting), "both, each counted once")
        #expect(line(working, ready: []) == OperatorLine("2 working", look: .acting))
        #expect(line(ready, ready: ready) == OperatorLine("2 to check"), "nothing works: it waits for its turn, quiet")
        #expect(line(Array(ready.prefix(1)), ready: ready) == OperatorLine("1 to check"))
        // Only a working task waits to be accepted: one accepted already is done, whatever its tabs say.
        let accepted = task("The schema", run: run, .accepted, sha: "4f2a91cdeadbeef")
        #expect(line(working + [accepted], ready: [accepted]) == OperatorLine("2 working", look: .acting))
        // The longest count fits the sidebar's line.
        let many = (0..<24).map { _ in task(run: run, .working) }
        #expect(line(many, ready: Array(many.prefix(12))).text.count <= OperatorLine.maxLength)
        // An act outranks the count, as it outranks the tasks at work.
        #expect(OperatorLine.broadcast(run, tasks: ready, acting: (.checkingTheWork, task: nil), requests: [], ready: Set(ready.map(\.id)))
                == OperatorLine("checking the work", look: .acting))
    }

    @Test func everyActHasItsWords() {
        let words: [OperatorAct: String] = [
            .loadingTheConstruct: "loading the construct", .consultingTheOracle: "consulting the Oracle",
            .starting: "starting Codex", .answering: "answering Codex", .checkingTheWork: "checking the work",
            .reviewingWith: "reviewing with Codex", .openingTheMR: "opening the MR", .assigning: "assigning Jan",
            .relayingFeedback: "relaying feedback", .merging: "merging", .filingATicket: "filing a ticket",
            .reopeningItsWindow: "reopening its window",
        ]
        #expect(Set(words.keys) == Set(OperatorAct.allCases), "the list is closed: every act has its words")
        for act in OperatorAct.allCases { #expect(act.words(agent: .codex, names: ["Jan"]) == words[act], "\(act)") }
        #expect(OperatorAct.assigning.words(agent: .claude, names: ["Jan", "Piet"]) == "assigning Jan and Piet")
        #expect(OperatorAct.assigning.words(agent: .claude) == "assigning reviewers")
        // On a task's own row its icon names the agent, so the line names the Operator; a review its reviewer.
        let rowWords: [OperatorAct: String] = [
            .starting: "Operator starting it", .answering: "Operator answering", .checkingTheWork: "Operator checking the work",
            .reviewingWith: "Codex reviewing", .relayingFeedback: "Operator relaying feedback",
        ]
        for act in OperatorAct.allCases {
            #expect(act.rowWords(agent: .codex, names: ["Jan"]) == rowWords[act] ?? words[act], "\(act)")
        }
        let run = OperatorUIFixtures.run()
        let codex = task(agent: .codex, run: run, .working)
        #expect(OperatorLine.task(codex, run: run, acting: .starting, requests: []) == OperatorLine("Operator starting it", look: .acting))
        #expect(OperatorLine.task(codex, run: run, acting: .answering, requests: []) == OperatorLine("Operator answering", look: .acting),
                "never Codex answering Codex")
        #expect(OperatorLine.task(codex, run: run, acting: .consultingTheOracle, requests: []) == OperatorLine("consulting the Oracle", look: .acting))
    }

    @Test func takenOverHasNoLine() {
        let run = OperatorUIFixtures.run()
        for state in [OperatedState.working, .queued, .accepted] {
            #expect(OperatorLine.task(task(run: run, state, takenOver: true), run: run, acting: .answering, requests: []) == nil, "\(state)")
        }
        // Nor does a task the Operator let go of, or one in a broadcast that ended.
        #expect(OperatorLine.task(task(run: run, .stopped), run: run, acting: nil, requests: []) == nil)
        let ended = OperatorUIFixtures.run(state: .stopped)
        #expect(OperatorLine.task(task(run: ended, .working), run: ended, acting: nil, requests: []) == nil)
        #expect(OperatorLine.task(OperatorUIFixtures.task("Mine", project: web.id, operated: nil), run: run, acting: nil, requests: []) == nil)
    }

    @Test func aTasksLineSaysWhereItIsInItsWorkflow() {
        let run = OperatorUIFixtures.run()
        let parent = task("The signup block schema", jira: "PAY-232", run: run, .accepted, sha: "4f2a91cdeadbeef")
        func line(_ task: TaskItem, _ requests: [BroadcastRequest] = []) -> String? {
            OperatorLine.task(task, run: run, acting: nil, requests: requests)?.text
        }
        #expect(line(task(run: run, .queued)) == "queued")
        #expect(line(task(run: run, .planned)) == "queued")
        #expect(line(task(run: run, .queued, dependsOn: [TaskDependency(task: parent.id, kind: .order)])) == "queued · after another task",
                "with no lookup the parent is named generically")
        #expect(OperatorLine.task(task(run: run, .working), run: run, acting: nil, requests: []) == OperatorLine("Operator watching", look: .acting),
                "the agent works: the line moves with the row's mark")
        #expect(line(task(run: run, .queued, revision: 3)) == "added by the Operator")
        #expect(line(task(run: run, .blocked, reason: "the tests fail on main")) == "blocked · the tests fail on main")
        #expect(OperatorLine.task(task(run: run, .blocked, reason: "the tests fail on main"), run: run, acting: nil, requests: [])?.look == .needsYou)
        #expect(line(task(run: run, .accepted, sha: "4f2a91cdeadbeef")) == "done · 4f2a91c")
        var draft = task(run: run, .published, end: .draftMR, sha: "11c5d2e00")
        draft.operated?.publication = TaskPublication(mergeRequestURL: "https://gitlab.example/a/b/-/merge_requests/412", mergeRequestNumber: 412)
        #expect(line(draft) == "draft MR · !412")
        #expect(line(task(run: run, .published, end: .merge, sha: "9b3e07d1234")) == "merged · 9b3e07d")
        #expect(line(task(run: run, .published, end: .mergeLocal, sha: "9b3e07d1234")) == "merged locally · 9b3e07d")
        #expect(line(task(run: run, .published, end: .commit, sha: "9b3e07d1234")) == "done · 9b3e07d")
        #expect(OperatorLine.task(task(run: run, .accepted, sha: "4f2a91cdeadbeef"), run: run, acting: nil, requests: [])?.look == .ended,
                "done is the Operator's: nothing left for you, and the row says it ended")
        // Every end the line names is ended (1A, 21 Oct 2026): the row draws its check for it.
        for ended in [task(run: run, .noChange), draft, task(run: run, .published, end: .merge, sha: "9b3e07d1234"),
                      task(run: run, .published, end: .mergeLocal, sha: "9b3e07d1234"), task(run: run, .published, end: .commit, sha: "9b3e07d1234")] {
            #expect(OperatorLine.task(ended, run: run, acting: nil, requests: [])?.look == .ended, "\(ended.operated?.state.rawValue ?? "")")
        }
        // An accepted task AiTerm is publishing: something moves, so the line acts, as every act does.
        #expect(OperatorLine.task(task(run: run, .accepted, end: .draftMR, sha: "4f2a91cdeadbeef"), run: run, acting: nil, requests: [])
                == OperatorLine("opening the MR", look: .acting))
        #expect(OperatorLine.task(task(run: run, .accepted, end: .merge, sha: "4f2a91cdeadbeef"), run: run, acting: nil, requests: [])
                == OperatorLine("merging", look: .acting))
        // A publication handed back is the one finished state that is yours.
        var left = task(run: run, .accepted, sha: "4f2a91cdeadbeef")
        left.operated?.publication = TaskPublication(leftForYou: true)
        #expect(OperatorLine.task(left, run: run, acting: nil, requests: []) == OperatorLine("left for you · 4f2a91c", look: .needsYou))
    }

    @Test func aTaskWaitingItsTurnNamesWhatItWaitsFor() {
        let run = OperatorUIFixtures.run()
        let parent = task("The signup block schema", jira: "PAY-232", run: run, .working)
        let byKey = task(run: run, .queued, dependsOn: [TaskDependency(task: parent.id, kind: .code)], stackedOn: parent.id)
        #expect(OperatorLine.task(byKey, run: run, acting: nil, requests: [], tasks: [parent.id: parent])?.text == "queued · after PAY-232")
    }

    /// A question the Operator asks about a task is the Operator's row's (2A, 22 Oct 2026): you answer it in the
    /// Operator's window, so the task's own line goes on saying what its worker does. A worker's prompt stays its own.
    @Test func aQuestionAboutATaskIsNotOnItsLineAndABlockedReasonIsCutToFit() throws {
        let run = OperatorUIFixtures.run()
        let asked = task(run: run, .working)
        let question = "The Operator asks: Should the signup block keep its subtitle on mobile, where the design leaves it out?"
        let line = try #require(OperatorLine.task(asked, run: run, acting: nil, requests: [request(.question, run, asked, question)]))
        #expect(line == OperatorLine("Operator watching", look: .acting))
        let prompt = "Claude Code asks for permission in the signup block."
        #expect(OperatorLine.task(asked, run: run, acting: nil, requests: [request(.permission, run, asked, prompt)])
                == OperatorLine("waiting on you", look: .needsYou, tooltip: prompt))
        // No window says why a task is blocked, so its line keeps the reason, cut to fit.
        let because = "npm ci failed with a lockfile that no longer matches package.json"
        let blocked = try #require(OperatorLine.task(task(run: run, .blocked, reason: because), run: run, acting: nil, requests: []))
        #expect(blocked.text.hasPrefix("blocked · npm ci failed") && blocked.text.hasSuffix("…"), "\(blocked.text)")
        #expect(blocked.text.count <= OperatorLine.maxLength && blocked.tooltip == "blocked · " + because)
    }

    @Test func theBroadcastSaysItsOwnState() {
        func line(_ state: OperatorRunState) -> String {
            OperatorLine.broadcast(OperatorUIFixtures.run(state: state), tasks: [], acting: nil, requests: []).text
        }
        #expect(line(.paused) == "paused")
        #expect(line(.operatorOffline) == "paused · the Operator’s window is closed")
    }

    /// Every task done is not the summary ready: the line waits for the Operator to write it, or for AiTerm to give up.
    @Test func theBroadcastSaysWhenItsSummaryIsReady() {
        func line(_ change: (inout OperatorRun) -> Void) -> String {
            var run = OperatorUIFixtures.run(state: .complete)
            run.completedAt = OperatorUIFixtures.epoch
            change(&run)
            return OperatorLine.broadcast(run, tasks: [], acting: nil, requests: []).text
        }
        #expect(line { _ in } == "done · writing summary")
        #expect(line { $0.summary = "Both merged."; $0.summaryAt = OperatorUIFixtures.epoch } == "done · summary ready")
        #expect(line { $0.summaryGivenUp = true } == "done")
        #expect(line { $0.completedAt = nil } == "done · writing summary", "completed before AiTerm recorded when: still waiting")
    }

    /// A quiet line cut to fit keeps the whole of it in the tooltip, as needs-you does.
    @Test func aCutQuietLineKeepsTheWholeInItsTooltip() throws {
        let run = OperatorUIFixtures.run()
        let because = "npm ci failed with a lockfile that no longer matches package.json"
        let failed = try #require(OperatorLine.task(task(run: run, .failed, reason: because), run: run, acting: nil, requests: []))
        #expect(failed.text.hasSuffix("…") && failed.text.count <= OperatorLine.maxLength, "\(failed.text)")
        #expect(failed.tooltip == "failed · " + because)
        let parent = task("Show the newsletter signup block on the homepage and the blog", run: run, .working)
        let child = task(run: run, .queued, dependsOn: [TaskDependency(task: parent.id, kind: .order)])
        let queued = try #require(OperatorLine.task(child, run: run, acting: nil, requests: [], tasks: [parent.id: parent]))
        #expect(queued.text.hasSuffix("…"), "\(queued.text)")
        #expect(queued.tooltip == "queued · after Show the newsletter signup block on the homepage and the blog")
        var reviewed = task(run: run, .inReview)
        reviewed.operated?.peopleReview = PeopleReview(reviewers: ["Jan Peeters", "An Vermeulen", "Piet Janssens"])
        let waiting = OperatorLine.broadcast(run, tasks: [reviewed], acting: nil, requests: [])
        #expect(waiting.text.hasSuffix("…"))
        #expect(waiting.tooltip == "in review · waiting on Jan Peeters, An Vermeulen and Piet Janssens")
    }

    /// A finished task's leftover request asks nothing on the broadcast's line either, as on its own.
    @Test func aFinishedTasksLeftoverRequestIsNotTheBroadcasts() {
        let run = OperatorUIFixtures.run()
        let done = task(run: run, .accepted, sha: "4f2a91cdeadbeef"), working = task("Bump nuxt", run: run, .working)
        let leftover = request(.question, run, done, "The Operator asks: retry policy?")
        #expect(OperatorLine.task(done, run: run, acting: nil, requests: [leftover])?.text == "done · 4f2a91c")
        #expect(OperatorLine.broadcast(run, tasks: [done, working], acting: nil, requests: [leftover]) == OperatorLine("1 working", look: .acting))
        // Beside another task's request it is not counted either.
        let asks = request(.permission, run, working, "Claude Code asks for permission in Bump nuxt.")
        #expect(OperatorLine.broadcast(run, tasks: [done, working], acting: nil, requests: [leftover, asks]).text == "waiting on you")
    }

    // MARK: - A task the Operator holds, in its plain verbs (P3, 21 Oct 2026)

    /// The words, kept in `Count` alone: the Operator named on a task's row, task states counted on the broadcast's.
    @Test func theCountsWordsNameTheOperator() {
        #expect(OperatorLine.Count.working.words == "Operator watching")
        #expect(OperatorLine.Count.ready.words == "ready for the Operator")
        #expect(OperatorLine.Count.working.counted(1) == "1 working")
        #expect(OperatorLine.Count.working.counted(2) == "2 working")
        #expect(OperatorLine.Count.ready.counted(1) == "1 to check")
    }

    /// While its agent works the Operator watches it, never named by the agent the row's icon already shows; once
    /// every worker ended its turn it is ready for the Operator. Both move with the row's spinner: the Operator
    /// holds the task.
    @Test func aWorkingTaskIsWatchedThenReadyForTheOperator() {
        let run = OperatorUIFixtures.run()
        let codex = task(agent: .codex, run: run, .working)
        func line(_ state: SessionState) -> OperatorLine? {
            OperatorLine.task(codex, run: run, acting: nil, requests: [],
                              sessions: [OperatorUIFixtures.tab("s1", of: codex, state, agent: .codex)])
        }
        #expect(line(.working) == OperatorLine("Operator watching", look: .acting))
        #expect(line(.idle) == OperatorLine("ready for the Operator", look: .acting))
        #expect(line(.done) == OperatorLine("ready for the Operator", look: .acting))
        // Without its tabs listed nothing says it is done: the Operator watches it, as before.
        #expect(OperatorLine.task(codex, run: run, acting: nil, requests: []) == OperatorLine("Operator watching", look: .acting))
        // An act outranks both.
        #expect(OperatorLine.task(codex, run: run, acting: .checkingTheWork, requests: [],
                                  sessions: [OperatorUIFixtures.tab("s1", of: codex, .idle)]) == OperatorLine("Operator checking the work", look: .acting))
    }

    /// A driven task with several worker tabs keeps one row (P5 A): its line counts the tabs still open, and a
    /// request names the tab that asks.
    @Test func severalWorkerTabsAreCountedAndTheAskingOneNamed() throws {
        let run = OperatorUIFixtures.run()
        var tabbed = task("Price formatting", jira: "PAY-236", agent: .codex, run: run, .working)
        tabbed.operated?.extraTabs = [OperatorUIFixtures.extraTab("docs", agent: .claude), OperatorUIFixtures.extraTab("api-mocks")]
        let main = OperatorUIFixtures.tab("s1", of: tabbed, .working, agent: .codex)
        let docs = OperatorUIFixtures.tab("s2", of: tabbed, .working, index: 1, key: "docs")
        let mocks = OperatorUIFixtures.tab("s3", of: tabbed, .idle, index: 2, key: "api-mocks", agent: .codex)
        func line(_ sessions: [SessionInfo], _ requests: [BroadcastRequest] = []) -> OperatorLine? {
            OperatorLine.task(tabbed, run: run, acting: nil, requests: requests, sessions: sessions)
        }
        #expect(line([main, docs, mocks]) == OperatorLine("Operator watching · 3 tabs", look: .acting))
        #expect(line([main, docs]) == OperatorLine("Operator watching · 2 tabs", look: .acting), "a closed tab is no longer watched")
        #expect(line([main]) == OperatorLine("Operator watching", look: .acting), "one tab left: no count")

        let asks = BroadcastRequest(kind: .permission, runId: run.id, taskId: tabbed.id, text: "Claude Code asks to run npm ci in Price formatting.",
                                    tab: "docs")
        let asking = try #require(line([main, docs, mocks], [asks]))
        #expect(asking == OperatorLine("waiting on you · docs", look: .needsYou, tooltip: asks.text))
        var first = asks
        first.tab = WorkerTab.firstKey
        #expect(line([main, docs, mocks], [first])?.text == "waiting on you · main", "beside extra tabs the first worker is named too")
        // A task with no extra tab has nothing to tell apart.
        let alone = task(run: run, .working)
        let its = BroadcastRequest(kind: .permission, runId: run.id, taskId: alone.id, text: "Claude Code waits for input.", tab: WorkerTab.firstKey)
        #expect(OperatorLine.task(alone, run: run, acting: nil, requests: [its])?.text == "waiting on you")
        // A long key is cut to fit, whole in nothing but the tooltip's request.
        var long = asks
        long.tab = "the-end-to-end-tests-for-the-checkout-flow"
        let cut = try #require(line([main, docs, mocks], [long]))
        #expect(cut.text.hasPrefix("waiting on you · the-end") && cut.text.count <= OperatorLine.maxLength, "\(cut.text)")
    }

    /// A prompt open in a worker tab is the request of the tab that asks first by tab order: the first worker,
    /// then the extra tabs in the order they opened.
    @Test func aTasksPromptIsTheFirstAskingTabsByTabOrder() throws {
        var run = OperatorUIFixtures.run()
        var tabbed = task(run: run, .working)
        tabbed.operated?.extraTabs = [OperatorUIFixtures.extraTab("docs"), OperatorUIFixtures.extraTab("e2e-tests")]
        func state() -> AppState {
            var state = AppState()
            state.append(project: web)
            state.runs = [run]
            state.tasks = [tabbed]
            return state
        }
        func open(_ questions: [OperatorQuestion]) -> BroadcastRequest? {
            run.questions = questions
            return OperatorRequests.open(run: run, state: state(), prompts: [:]).first { $0.kind == .permission }
        }
        let prefix = "prompt-\(tabbed.id.uuidString)-"
        #expect(try #require(open([OperatorUIFixtures.question("e2e", id: prefix + "1", task: tabbed.id, tab: "e2e-tests"),
                                    OperatorUIFixtures.question("docs", id: prefix + "2", task: tabbed.id, tab: "docs")])).tab == "docs")
        #expect(try #require(open([OperatorUIFixtures.question("docs", id: prefix + "1", task: tabbed.id, tab: "docs"),
                                    OperatorUIFixtures.question("main", id: prefix + "2", task: tabbed.id)])).tab == WorkerTab.firstKey)
        // A question the Operator asks is no tab's.
        run.questions = [OperatorUIFixtures.question("Which retry policy?", task: tabbed.id)]
        let asked = OperatorRequests.open(run: run, state: state(), prompts: [:])
        #expect(asked.map(\.tab) == [nil])
    }

    // MARK: - The Operator row: its own session only

    /// The Operator row speaks for its own session, nothing of its tasks: its act, what it waits on between turns,
    /// what it asks in its window, and its window closed.
    @Test func theOperatorRowSaysItsOwnSession() {
        let run = OperatorUIFixtures.run()
        let pay = task("Cart drawer", jira: "PAY-231", run: run, key: "pay-231", .working)
        func line(acting: (OperatorAct, task: String?)? = nil, working: Bool = false, asking: Bool = false,
                  windowClosed: Bool = false, paused: Bool = false, summary: RunSummary = .notYet) -> OperatorLine {
            OperatorLine.session(acting: acting, working: working, asking: asking, windowClosed: windowClosed, paused: paused,
                                 summary: summary, tasks: [pay])
        }
        #expect(line() == OperatorLine("watching 1 task"), "between turns: its working tasks counted, quiet")
        #expect(OperatorLine.session(acting: nil, working: false, asking: false, windowClosed: false, tasks: [])
                == OperatorLine("waiting for its tasks"), "none at work")
        #expect(line(summary: .writing) == OperatorLine("writing the summary", look: .acting), "every task done: it writes the summary")
        #expect(line(working: true, summary: .written(text: "Both merged.", at: OperatorUIFixtures.epoch))
                == OperatorLine("done · summary ready"), "as the header says it")
        #expect(line(summary: .notComing) == OperatorLine("done"), "AiTerm gave up waiting for it")
        #expect(line(asking: true, summary: .writing).look == .needsYou, "its own ask still comes first")
        #expect(line(working: true) == OperatorLine("working", look: .acting))
        #expect(line(acting: (.answering, task: "pay-231"), working: true) == OperatorLine("answering Claude · PAY-231", look: .acting))
        #expect(line(acting: (.consultingTheOracle, task: nil)) == OperatorLine("consulting the Oracle", look: .acting))
        #expect(line(acting: (.answering, task: "pay-231"), working: true, asking: true) == OperatorLine("waiting on you", look: .needsYou),
                "what it asks outranks what it does")
        // A question about one task names it (2A, 22 Oct 2026); the question itself is the tooltip.
        let about = OperatorLine.session(acting: nil, working: false, asking: true, about: "PAY-232", asks: "The Operator asks: retry policy?",
                                         windowClosed: false, tasks: [pay])
        #expect(about == OperatorLine("waiting on you · PAY-232", look: .needsYou, tooltip: "The Operator asks: retry policy?"))
        #expect(line(working: true, paused: true) == OperatorLine("paused"))
        #expect(line(asking: true, windowClosed: true) == OperatorLine("window closed"), "no window, nothing it can ask in")
        for said in [line(), line(asking: true), line(windowClosed: true)] { #expect(said.text.count <= OperatorLine.maxLength) }
    }
}
