import Testing
import Foundation
@testable import AiTermCore

@Suite struct RunStatusTests {
    typealias F = OperatorFixtures

    /// A run with revision 2 submitted, five tasks in every situation the
    /// obligations name, and an open and a resolved question.
    private func scene() -> (AppState, [UUID: TaskLiveFacts], ids: [String: UUID]) {
        let a = F.task("A", .accepted), b = F.task("B", .working, dependsOn: [TaskDependency(task: a.id, kind: .code)])
        var c = F.task("C", .working), d = F.task("D", .working), e = F.task("E", .planned, revision: 2)
        c.operated?.flags = [.possiblyStalled, .uncertain]
        d.operated?.takenOver = true
        var s = F.state(F.run(planRevision: 2), [a, b, c, d, e])
        s.tasks[0].operated?.acceptance = F.acceptance("4f2a91c0ffee")
        s.runs[0].questions = [
            OperatorQuestion(id: "q-open", text: "Which API version?", task: c.id, askedAt: F.epoch),
            OperatorQuestion(id: "q-done", text: "Old?", task: nil, askedAt: F.epoch, resolution: "v2"),
        ]
        let live: [UUID: TaskLiveFacts] = [
            b.id: TaskLiveFacts(status: .done, lastCommit: "b0b0b0b", summary: "Added the endpoint"),
            c.id: TaskLiveFacts(status: .needsInput, waitingPrompt: "permission"),
            d.id: TaskLiveFacts(status: .idle),
        ]
        return (s, live, ["A": a.id, "B": b.id, "C": c.id, "D": d.id, "E": e.id])
    }

    @Test func theSnapshotSaysTheRunAndEveryTask() throws {
        let (s, live, ids) = scene()
        let status = try #require(RunStatus.build(state: s, run: F.runId, revision: 7, live: live))
        #expect(status.revision == 7)
        #expect(status.run.planRevision == 2 && status.run.openRevision == 3 && status.run.state == .active)
        #expect(status.tasks.map(\.key) == ["A", "B", "C", "D", "E"])
        let b = status.tasks[1]
        #expect(b.id == ids["B"] && b.project == "Shop" && b.live == .done && b.lastCommit == "b0b0b0b")
        #expect(b.summary == "Added the endpoint" && b.branch == "feat/b")
        #expect(b.dependsOn == [RunStatus.Dependency(key: "A", kind: .code)])
        #expect(status.tasks[0].acceptedSHA == "4f2a91c0ffee")
        #expect(status.tasks[2].flags == [.possiblyStalled, .uncertain])
        #expect(status.tasks[4].live == nil)
    }

    /// A complete run with no summary says one is due, so a restarted Operator writes it; with one, or while active, none is.
    @Test func aCompleteRunWithoutASummaryHasOneDue() throws {
        var (s, live, _) = scene()
        func due() throws -> Bool { try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).run.summaryDue }
        #expect(try !due(), "an active run")
        s.runs[0].state = .complete
        #expect(try due())
        s.runs[0].summary = "Everything merged."
        #expect(try !due())
    }

    @Test func theObligationsSayWhatWaits() throws {
        let (s, live, _) = scene()
        let o = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).obligations
        #expect(o.questionsWaiting == [RunStatus.Question(key: "q-open", text: "Which API version?", task: "C", askedAt: F.epoch)])
        #expect(o.promptsWaitingOnYou == ["C"])
        #expect(o.readyForAcceptance == ["B"], "D ended its turn too, but you took it over")
        #expect(o.possiblyStalled == ["C"] && o.uncertain == ["C"])
    }

    /// A question on a task is a question, not a prompt: the task leaves promptsWaitingOnYou, keeps its
    /// question under questionsWaiting, and still isn't ready to accept while it waits on you.
    @Test func aQuestionOnATaskIsNotAPromptInItsTerminal() throws {
        var q = F.task("Q", .working)
        q.operated?.flags = [.waitingOnYou]
        var s = F.state(F.run(), [q])
        s.runs[0].questions = [OperatorQuestion(id: "merged-on-host-1", text: "Merged on the host?", task: q.id, askedAt: F.epoch)]
        let live = [q.id: TaskLiveFacts(status: .idle)]
        let o = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).obligations
        #expect(!o.promptsWaitingOnYou.contains("Q"))
        #expect(o.questionsWaiting.map(\.task) == ["Q"])
        #expect(!o.readyForAcceptance.contains("Q"))
    }

    /// What you typed in the task's worker window while a question about it was open (`answeredInWindow`) comes with that
    /// question, so the Operator can check it and resolve; a question with none omits the field.
    @Test func aQuestionShowsWhatYouTypedInItsWorkersWindow() throws {
        let q = F.task("Q", .working)
        var s = F.state(F.run(), [q])
        s.runs[0].questions = [OperatorQuestion(id: "locale", text: "Which locale?", task: q.id, askedAt: F.epoch, answeredInWindow: "Use nl-BE"),
                               OperatorQuestion(id: "api", text: "Which API?", task: q.id, askedAt: F.epoch)]
        let waiting = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: [:])).obligations.questionsWaiting
        #expect(waiting.map(\.answeredInWindow) == ["Use nl-BE", nil])
        let json = try String(decoding: JSONEncoder().encode(waiting), as: UTF8.self)
        #expect(json.components(separatedBy: "answeredInWindow").count == 2, "only the marked question carries the field")
    }

    /// A worker that committed off its task branch is named with what AiTerm found, the branch and the SHA,
    /// and listed among the obligations, so the Operator looks before the runtime runs out.
    @Test func aTaskOffItsBranchSaysWhatWasFound() throws {
        var (s, live, _) = scene()
        let drift = BranchDrift(source: .lastMessage, branch: "feat/mine", sha: "c0ffee1",
                                found: "Its last message names c0ffee1, which isn't on its task branch feat/b: it is on feat/mine.")
        s.tasks[1].operated?.branchDrift = drift
        let status = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live))
        #expect(status.tasks[1].branchDrift == drift && status.tasks[0].branchDrift == nil)
        #expect(status.obligations.branchDrift == ["B"])
        let json = String(decoding: try status.json(), as: UTF8.self)
        #expect(json.contains(#""branchDrift":{"branch":"feat\/mine","found":"#) && json.contains(#""sha":"c0ffee1","source":"lastMessage"}"#))
    }

    /// What the Operator needs to judge the backlog and its own reach: the first plan's size, the finds,
    /// the slices and the Oracle as the run froze them, and each agent's weekly usage.
    @Test func theRunSaysItsFirstPlanSizeFindsSlicesOracleAndUsage() throws {
        var (s, live, _) = scene()
        s.runs[0].firstPlanSize = 4
        s.runs[0].finds = [OffBriefFind(key: "f1", title: "Dead footer link", why: "/privacy 404s")]
        s.runs[0].profile.slices = Slices(jira: true, review: false, merge: true)
        s.runs[0].profile.oracle.isOn = false

        let run = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live,
                                               runLive: RunLiveFacts(weeklyUsage: [.claude: 81, .codex: 12]))).run

        #expect(run.firstPlanSize == 4)
        #expect(run.finds.map(\.key) == ["f1"])
        #expect(run.slices == Slices(jira: true, review: false, merge: true))
        #expect(!run.oracleIsOn)
        #expect(run.usage == ["claude": 81, "codex": 12])
    }

    @Test func aRunWithNoPlanOrUsageSaysSo() throws {
        let (s, live, _) = scene()
        let run = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).run
        #expect(run.firstPlanSize == nil && run.finds.isEmpty && run.slices == .none && run.usage.isEmpty)
        #expect(run.oracleIsOn == s.runs[0].profile.oracle.isOn)
    }

    /// The broadcast's prompt, Review and Done, as the run froze them.
    @Test func theRunSaysItsPromptReviewAndDone() throws {
        var (s, live, _) = scene()
        s.runs[0].review = "Jan approves each MR"
        let run = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).run
        #expect(run.prompt == "Implement the sprint." && run.review == "Jan approves each MR" && run.done == "a commit per item, tests green")
    }

    @Test func theToolsJSONHasSortedKeysAndISODates() throws {
        let (s, live, _) = scene()
        let data = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).json()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["revision", "run", "tasks", "obligations"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""askedAt":"2023-11-14T22:13:20Z""#))
        #expect(text.hasPrefix(#"{"obligations":"#))
        #expect(!text.contains("approvedRevision") && !text.contains("planAwaitingApproval") && !text.contains("gated"))
    }

    // -- a task with extra worker tabs (`open_tab`) ------------------------------------------------

    /// One working task, B, with an extra tab `review` beside its first worker.
    private func twoTabs(first: SessionState?, review: SessionState?, opening: Bool = false, closed: Bool = false,
                         prompt: String? = nil) throws -> (RunStatus, TaskItem) {
        var b = F.task("B", .working)
        b.operated?.extraTabs = [ExtraTab(key: "review", agent: .codex, model: "gpt-6-mini", reasoning: nil, modelReason: "Tests.",
                                          brief: "Write the tests.", launch: LaunchAttempt(number: 1, requestedAt: F.epoch))]
        let tab = TaskLiveFacts.Tab(key: "review", agent: .codex, model: "gpt-6-mini", status: review, opening: opening, closed: closed,
                                    waitingPrompt: prompt)
        let status = try #require(RunStatus.build(state: F.state(F.run(), [b]), run: F.runId, revision: 1,
                                                  live: [b.id: TaskLiveFacts(status: first, tabs: [tab])]))
        return (status, b)
    }

    /// A task is ready for acceptance only once every one of its worker tabs ended its turn.
    @Test func aTaskWithOneTabStillAtWorkIsNotReadyForAcceptance() throws {
        #expect(try twoTabs(first: .idle, review: .working).0.obligations.readyForAcceptance.isEmpty)
        #expect(try twoTabs(first: .working, review: .done).0.obligations.readyForAcceptance.isEmpty)
        #expect(try twoTabs(first: .idle, review: nil, opening: true).0.obligations.readyForAcceptance.isEmpty, "still opening is at work")
        #expect(try twoTabs(first: .idle, review: .done).0.obligations.readyForAcceptance == ["B"])
        #expect(try twoTabs(first: .done, review: nil).0.obligations.readyForAcceptance == ["B"], "a closed extra tab is no worker")
    }

    /// A worker that ended its turn with work still running in the background (Claude's Stop says what) is paused, not
    /// done: Claude Code wakes it once that work ends. Its task is not ready to accept; it is listed under `background`,
    /// with the commands its line says, so the Operator can tell a long test run from a stuck worker.
    @Test func aWorkerWaitingOnBackgroundWorkIsNotReadyForAcceptance() throws {
        let b = F.task("B", .working)
        func status(_ background: [String]) throws -> RunStatus {
            try #require(RunStatus.build(state: F.state(F.run(), [b]), run: F.runId, revision: 1,
                                         live: [b.id: TaskLiveFacts(status: .done, background: background)]))
        }
        let waiting = try status(["npm run test:run"])
        #expect(waiting.obligations.readyForAcceptance.isEmpty)
        #expect(waiting.obligations.background == ["B"])
        #expect(waiting.tasks[0].background == ["npm run test:run"])
        let ended = try status([])
        #expect(ended.obligations.readyForAcceptance == ["B"] && ended.obligations.background.isEmpty)
        #expect(ended.tasks[0].background == nil)
        #expect(!RunStatus.isReadyForAcceptance(F.operated("B", .working), live: .idle, background: ["CI on !46"]))
    }

    @Test func readinessCountsEveryWorkerTab() {
        let working = F.operated("B", .working)
        #expect(RunStatus.isReadyForAcceptance(working, live: .idle))
        #expect(RunStatus.isReadyForAcceptance(working, live: .idle, extraTabs: [.done, nil]))
        #expect(!RunStatus.isReadyForAcceptance(working, live: .idle, extraTabs: [.working]))
        #expect(!RunStatus.isReadyForAcceptance(working, live: .done, extraTabs: [.needsInput]))
        #expect(!RunStatus.isReadyForAcceptance(working, live: nil, extraTabs: [.idle]), "a first worker with no tab has not ended its turn")
    }

    /// A prompt open in an extra tab waits on you, named by its task and its tab, and the task is not ready.
    @Test func aPromptInAnExtraTabWaitsOnYouNamingTheTab() throws {
        let (status, _) = try twoTabs(first: .idle, review: .needsInput, prompt: "Codex asks for permission")
        #expect(status.obligations.promptsWaitingOnYou == ["B/review"])
        #expect(status.obligations.readyForAcceptance.isEmpty)
    }

    /// A task with extra tabs lists every worker tab, its first worker as `main`; one without keeps today's line.
    @Test func theTaskLineListsItsTabsOnlyWhenItHasExtraOnes() throws {
        let (status, b) = try twoTabs(first: .idle, review: nil, opening: true)
        #expect(status.tasks[0].live == .idle && status.tasks[0].agent == .claude && status.tasks[0].model == b.model)
        #expect(status.tasks[0].tabs == [RunStatus.TabLine(key: "main", agent: .claude, model: b.model, live: .idle),
                                         RunStatus.TabLine(key: "review", agent: .codex, model: "gpt-6-mini", live: nil, opening: true)])
        let json = String(decoding: try status.json(), as: UTF8.self)
        #expect(json.contains(#""tabs":[{"agent":"claude","closed":false,"key":"main","live":"idle","model":"opus","opening":false},"#))
        let (s, live, _) = scene()
        let plain = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live))
        #expect(plain.tasks.allSatisfy { $0.tabs == nil })
        #expect(!String(decoding: try plain.json(), as: UTF8.self).contains(#""tabs""#))
    }

    /// An extra tab closed after it opened is listed, marked closed, with no live status; it is no worker, so the task
    /// is ready once its other tabs ended their turn.
    @Test func aClosedExtraTabIsListedClosed() throws {
        let (status, b) = try twoTabs(first: .idle, review: nil, closed: true)
        #expect(status.tasks[0].tabs == [RunStatus.TabLine(key: "main", agent: .claude, model: b.model, live: .idle),
                                         RunStatus.TabLine(key: "review", agent: .codex, model: "gpt-6-mini", live: nil, closed: true)])
        #expect(String(decoding: try status.json(), as: UTF8.self).contains(#"{"agent":"codex","closed":true,"key":"review","model":"gpt-6-mini","opening":false}"#))
        #expect(status.obligations.readyForAcceptance == ["B"])
    }

    // -- a worker's turn, seen on every task (spec §E, §J) ------------------------------------------------

    /// One task in `state` whose first worker is `live` with what its last turn left: `turn` as the controller reads it.
    private func turn(_ state: OperatedState, live: SessionState? = .idle, lastMessage: String? = nil, commitsAhead: Int? = nil,
                      changed: Bool = false, accepted: Bool = false) throws -> RunStatus {
        var b = F.task("B", state)
        if accepted { b.operated?.acceptance = F.acceptance("4f2a91c") }
        let facts = TaskLiveFacts(status: live, lastMessage: lastMessage, commitsAhead: commitsAhead, changedAfterAcceptance: changed)
        return try #require(RunStatus.build(state: F.state(F.run(), [b]), run: F.runId, revision: 1, live: [b.id: facts]))
    }

    /// A worker that ended its turn asking something has not finished: the Operator answers it, then reads the result.
    @Test func aWorkingWorkerThatAsksIsNotReady() throws {
        let status = try turn(.working, lastMessage: "Tests pass.\n\nShould I also bump eslint?", commitsAhead: 2)
        #expect(status.obligations.readyForAcceptance.isEmpty)
        #expect(status.obligations.workerAsks == [RunStatus.WorkerAsk(key: "B", question: "Should I also bump eslint?")])
        #expect(status.obligations.finishedWithoutCommit.isEmpty)
        #expect(!RunStatus.isReadyForAcceptance(F.operated("B", .working), live: .idle, asks: true))
    }

    /// A turn that ended with nothing committed past the base is not ready, and still wakes the Operator, listed.
    @Test func noCommitIsNotReadyButIsListed() throws {
        let status = try turn(.working, lastMessage: "Nothing to update.", commitsAhead: 0)
        #expect(status.obligations.readyForAcceptance.isEmpty)
        #expect(status.obligations.finishedWithoutCommit == ["B"])
        #expect(status.obligations.workerAsks.isEmpty)
        #expect(!RunStatus.isReadyForAcceptance(F.operated("B", .working), live: .idle, commitsAhead: 0))
        let json = String(decoding: try status.json(), as: UTF8.self)
        #expect(json.contains(#""finishedWithoutCommit":["B"]"#))
    }

    /// A turn with a commit and no question is ready, as is one AiTerm couldn't count the commits of.
    @Test func aCleanTurnWithACommitIsReady() throws {
        let status = try turn(.working, lastMessage: "Added the endpoint. All tests pass.", commitsAhead: 1)
        #expect(status.obligations.readyForAcceptance == ["B"])
        #expect(status.obligations.workerAsks.isEmpty && status.obligations.finishedWithoutCommit.isEmpty)
        #expect(try turn(.working, commitsAhead: nil).obligations.readyForAcceptance == ["B"], "an unread turn reads as before")
        #expect(RunStatus.isReadyForAcceptance(F.operated("B", .working), live: .idle, commitsAhead: 1))
        let b = F.task("B", .working)
        let unread = try #require(RunStatus.build(state: F.state(F.run(), [b]), run: F.runId, revision: 1,
                                                  live: [b.id: TaskLiveFacts(status: .idle, turnUnread: true)]))
        #expect(unread.obligations.readyForAcceptance.isEmpty, "a turn AiTerm is still reading is not ready yet")
    }

    /// A task in review is not working, yet its worker's question reaches the Operator all the same.
    @Test func anInReviewWorkerThatAsksIsListed() throws {
        let status = try turn(.inReview, lastMessage: "I fixed the lint.\n\nShould I commit it and push again?", accepted: true)
        #expect(status.obligations.workerAsks == [RunStatus.WorkerAsk(key: "B", question: "Should I commit it and push again?")])
        #expect(status.obligations.readyForAcceptance.isEmpty && status.obligations.finishedWithoutCommit.isEmpty)
    }

    /// Work done in an accepted task's worker after its acceptance, a dirty worktree or a HEAD past the accepted commit,
    /// is listed on accepted, inReview and published tasks; never on a working one.
    @Test func workDoneAfterAcceptanceIsListed() throws {
        let dirty = WorkerTurn.changedAfterAcceptance(porcelain: " M src/app.ts", head: "4f2a91c", accepted: "4f2a91c")
        let moved = WorkerTurn.changedAfterAcceptance(porcelain: "", head: "b0b0b0b", accepted: "4f2a91c")
        #expect(dirty && moved)
        for state in [OperatedState.accepted, .inReview, .published] {
            #expect(try turn(state, changed: dirty, accepted: true).obligations.changedAfterAcceptance == ["B"], "\(state)")
        }
        #expect(try turn(.working, changed: true).obligations.changedAfterAcceptance.isEmpty)
        #expect(try turn(.accepted, changed: false, accepted: true).obligations.changedAfterAcceptance.isEmpty)
    }

    /// A worker whose next turn started is at work: what its last turn said is gone from the obligations.
    @Test func aNewTurnClearsTheAsk() throws {
        let asked = "Should I also bump eslint?"
        #expect(try turn(.working, live: .idle, lastMessage: asked).obligations.workerAsks.count == 1)
        let next = try turn(.working, live: .working, lastMessage: asked, commitsAhead: 0)
        #expect(next.obligations.workerAsks.isEmpty && next.obligations.finishedWithoutCommit.isEmpty)
        #expect(try turn(.accepted, live: .working, changed: true, accepted: true).obligations.changedAfterAcceptance.isEmpty)
    }

    @Test func anUnknownRunHasNoSnapshot() {
        #expect(RunStatus.build(state: .empty, run: UUID(), revision: 1, live: [:]) == nil)
    }

    /// A worker whose session says working but whose transcript went quiet reads `working?` and is uncertain, on a task in
    /// any state (spec §H); one that is not quiet reads as the session does.
    @Test func aQuietWorkingWorkerReadsWorkingQuestionMarkAndIsUncertain() throws {
        let a = F.task("A", .inReview), b = F.task("B", .accepted), c = F.task("C", .working)
        let s = F.state(F.run(planRevision: 1), [a, b, c])
        let live: [UUID: TaskLiveFacts] = [a.id: TaskLiveFacts(status: .working, quiet: true), b.id: TaskLiveFacts(status: .working),
                                           c.id: TaskLiveFacts(status: .idle, quiet: true)]
        let status = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live))
        #expect(status.tasks.map(\.live) == [.workingQuiet, .working, .idle], "only a working session can be quiet")
        #expect(status.obligations.uncertain == ["A"])
        let json = try #require(String(data: status.json(), encoding: .utf8))
        #expect(json.contains(#""live":"working?""#))
    }

    /// A task already flagged uncertain (a shell where its agent should be) is listed once, quiet or not.
    @Test func aTaskUncertainTwiceOverIsListedOnce() throws {
        var a = F.task("A", .working)
        a.operated?.flags = [.uncertain]
        let s = F.state(F.run(planRevision: 1), [a])
        let status = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: [a.id: TaskLiveFacts(status: .working, quiet: true)]))
        #expect(status.obligations.uncertain == ["A"])
    }
}
