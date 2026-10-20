import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// When Backpack Mode pushes to the iPhone, and what a push says (spec 2026-10-20). The queue is fed
/// one check at a time, as the 5 s tick feeds it, against a clock the test sets.
@Suite struct BackpackPushesTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let a = UUID(), b = UUID(), c = UUID()

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func row(_ id: UUID, _ status: TaskStatus, _ agent: AgentKind? = .claude) -> PushRow {
        PushRow(id: .task(id), status: status, agent: agent)
    }

    /// A queue whose first check, a minute before `t0` with the lid shut, saw `rows`: the baseline.
    func queue(_ rows: [PushRow], pushes: BackpackPushes = .needsInput) -> BackpackPushQueue {
        var queue = BackpackPushQueue()
        #expect(queue.check(rows, away: true, pushes: pushes, at: at(-60)) == nil)
        return queue
    }

    // MARK: What a push says

    @Test func onePushSaysTheAgentAndNothingElse() {
        let push = BackpackPush(needsInput: [.claude], done: [])
        #expect(push.title == "AiTerm")
        #expect(push.body == "Claude Code needs your input.")
    }

    @Test func severalRowsAreCounted() {
        #expect(BackpackPush(needsInput: [.claude, .codex, nil], done: []).body == "3 agents need your input.")
        #expect(BackpackPush(needsInput: [], done: [.pi]).body == "PI finished.")
        #expect(BackpackPush(needsInput: [], done: [.claude, .codex]).body == "2 agents finished.")
        #expect(BackpackPush(needsInput: [.grok], done: [.claude, .codex]).body == "Grok Build needs your input. 2 agents finished.")
        #expect(BackpackPush(needsInput: [nil], done: []).body == "An agent needs your input.")
    }

    // MARK: When

    /// The person saw them before shutting the lid.
    @Test func rowsAlreadyWaitingWhenTheLidShutsAreNotPushed() {
        var queue = BackpackPushQueue()
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: t0) == nil)
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: at(60)) == nil)
    }

    @Test func aRowThatStartsWaitingIsPushedAfterTheHold() {
        var queue = queue([row(a, .working)])
        let waiting = [row(a, .needsInput)]
        #expect(queue.check(waiting, away: true, pushes: .needsInput, at: t0) == nil)
        #expect(queue.check(waiting, away: true, pushes: .needsInput, at: at(29)) == nil)
        #expect(queue.check(waiting, away: true, pushes: .needsInput, at: at(30))?.body == "Claude Code needs your input.")
        #expect(queue.check(waiting, away: true, pushes: .needsInput, at: at(60)) == nil, "once")
    }

    /// Something else answered it — an Operator, a hook — so the person never hears of it.
    @Test func aPromptAnsweredWithinTheHoldNeverBuzzes() {
        var queue = queue([row(a, .working)])
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: t0) == nil)
        #expect(queue.check([row(a, .working)], away: true, pushes: .needsInput, at: at(10)) == nil)
        #expect(queue.check([row(a, .working)], away: true, pushes: .needsInput, at: at(40)) == nil)
    }

    /// A broadcast's workers asking seconds apart: one push, counted.
    @Test func rowsDueTogetherAreOnePush() {
        var queue = queue([row(a, .working), row(b, .working, .codex)])
        #expect(queue.check([row(a, .needsInput), row(b, .working, .codex)], away: true, pushes: .needsInput, at: t0) == nil)
        let both = [row(a, .needsInput), row(b, .needsInput, .codex)]
        #expect(queue.check(both, away: true, pushes: .needsInput, at: at(5)) == nil)
        #expect(queue.check(both, away: true, pushes: .needsInput, at: at(30))?.body == "2 agents need your input.")
        #expect(queue.check(both, away: true, pushes: .needsInput, at: at(35)) == nil, "b went with a")
    }

    /// The first waiting row anchors the hold; once it is answered, the next one does.
    @Test func theHoldFollowsTheRowsStillWaiting() {
        var queue = queue([row(a, .working), row(b, .working, .codex)])
        #expect(queue.check([row(a, .needsInput), row(b, .working, .codex)], away: true, pushes: .needsInput, at: t0) == nil)
        let onlyB = [row(a, .working), row(b, .needsInput, .codex)]
        #expect(queue.check(onlyB, away: true, pushes: .needsInput, at: at(20)) == nil)
        #expect(queue.check(onlyB, away: true, pushes: .needsInput, at: at(30)) == nil, "a left: b has held 10 s")
        #expect(queue.check(onlyB, away: true, pushes: .needsInput, at: at(50))?.body == "Codex needs your input.")
    }

    @Test func pushesAreSpacedFiveMinutes() {
        var queue = queue([row(a, .working), row(b, .working, .codex)])
        #expect(queue.check([row(a, .needsInput), row(b, .working, .codex)], away: true, pushes: .needsInput, at: t0) == nil)
        #expect(queue.check([row(a, .needsInput), row(b, .working, .codex)], away: true, pushes: .needsInput, at: at(30)) != nil)
        let both = [row(a, .needsInput), row(b, .needsInput, .codex)]
        #expect(queue.check(both, away: true, pushes: .needsInput, at: at(60)) == nil)
        #expect(queue.check(both, away: true, pushes: .needsInput, at: at(90)) == nil)
        #expect(queue.check(both, away: true, pushes: .needsInput, at: at(329)) == nil)
        #expect(queue.check(both, away: true, pushes: .needsInput, at: at(330))?.body == "Codex needs your input.")
    }

    /// Asked again within 15 minutes of its push, a row waits for them to pass; still waiting then,
    /// it is pushed — never twice within 15 minutes, and no question lost.
    @Test func aRowAskingAgainWithinFifteenMinutesWaitsForThem() {
        var queue = queue([row(a, .working)])
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: t0) == nil)
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: at(30)) != nil)
        #expect(queue.check([row(a, .working)], away: true, pushes: .needsInput, at: at(60)) == nil)
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: at(400)) == nil)
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: at(929)) == nil)
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: at(930))?.body == "Claude Code needs your input.")
    }

    /// Answered and asking again after the 15 minutes, a row is pushed as any other.
    @Test func aRowAskingAgainLaterIsPushedAgain() {
        var queue = queue([row(a, .working)])
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: t0) == nil)
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: at(30)) != nil)
        #expect(queue.check([row(a, .working)], away: true, pushes: .needsInput, at: at(990)) == nil)
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: at(1000)) == nil)
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: at(1030))?.body == "Claude Code needs your input.")
    }

    @Test(arguments: [BackpackPushes.needsInput, .needsInputOrDone, .never])
    func whatIsPushedIsWhatWasChosen(_ pushes: BackpackPushes) {
        var queue = queue([row(a, .working), row(b, .working, .codex)], pushes: pushes)
        let moved = [row(a, .done), row(b, .needsInput, .codex)]
        #expect(queue.check(moved, away: true, pushes: pushes, at: t0) == nil)
        let body = queue.check(moved, away: true, pushes: pushes, at: at(30))?.body
        switch pushes {
        case .needsInput: #expect(body == "Codex needs your input.")
        case .needsInputOrDone: #expect(body == "Codex needs your input. Claude Code finished.")
        case .never: #expect(body == nil)
        }
    }

    /// A row that moves while the person is at the open Mac is theirs already: shutting the lid
    /// later does not push it.
    @Test func nothingIsPushedWithTheLidOpenAndTheBaselineFollows() {
        var queue = queue([row(a, .working)])
        #expect(queue.check([row(a, .needsInput)], away: false, pushes: .needsInput, at: t0) == nil)
        #expect(queue.check([row(a, .needsInput)], away: false, pushes: .needsInput, at: at(40)) == nil)
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: at(60)) == nil)
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: at(200)) == nil)
    }

    /// The person looked at the Mac: what was pushed is not pushed again, and something new is
    /// pushed without waiting out the spacing.
    @Test func reopeningTheLidStartsOver() {
        var queue = queue([row(a, .working), row(b, .working, .codex)])
        #expect(queue.check([row(a, .needsInput), row(b, .working, .codex)], away: true, pushes: .needsInput, at: t0) == nil)
        #expect(queue.check([row(a, .needsInput), row(b, .working, .codex)], away: true, pushes: .needsInput, at: at(30)) != nil)
        #expect(queue.check([row(a, .needsInput), row(b, .working, .codex)], away: false, pushes: .needsInput, at: at(40)) == nil)
        #expect(queue.check([row(a, .needsInput), row(b, .working, .codex)], away: true, pushes: .needsInput, at: at(50)) == nil)
        let both = [row(a, .needsInput), row(b, .needsInput, .codex)]
        #expect(queue.check(both, away: true, pushes: .needsInput, at: at(60)) == nil)
        #expect(queue.check(both, away: true, pushes: .needsInput, at: at(90))?.body == "Codex needs your input.")
    }

    /// The mode ending itself: what still waits goes at once, hold and spacing aside, and the queue
    /// starts over.
    @Test func flushPushesWhatWaitsAtOnce() {
        var queue = queue([row(a, .working), row(b, .working, .codex)], pushes: .needsInputOrDone)
        #expect(queue.check([row(a, .working), row(b, .needsInput, .codex)], away: true, pushes: .needsInputOrDone, at: at(-40)) == nil)
        #expect(queue.check([row(a, .working), row(b, .needsInput, .codex)], away: true, pushes: .needsInputOrDone, at: at(-10)) != nil)
        let finished = [row(a, .done), row(b, .needsInput, .codex)]
        #expect(queue.check(finished, away: true, pushes: .needsInputOrDone, at: t0) == nil)
        #expect(queue.flush(finished, at: at(5))?.body == "Claude Code finished.")
        #expect(queue.check([row(a, .done), row(b, .done, .codex)], away: true, pushes: .needsInputOrDone, at: at(10)) == nil,
                "a fresh baseline")
    }

    @Test func flushWithNothingWaitingPushesNothing() {
        var queue = queue([row(a, .needsInput)])
        #expect(queue.flush([row(a, .needsInput)], at: t0) == nil)
    }

    /// A row the sidebar no longer has — removed, its project gone — is not pushed.
    @Test func aRowThatGoesIsForgotten() {
        var queue = queue([row(a, .working)])
        #expect(queue.check([row(a, .needsInput)], away: true, pushes: .needsInput, at: t0) == nil)
        #expect(queue.check([], away: true, pushes: .needsInput, at: at(10)) == nil)
        #expect(queue.check([], away: true, pushes: .needsInput, at: at(40)) == nil)
    }

    /// A row that appears while the person is away — a task an Operator starts — and asks at once is
    /// news.
    @Test func aNewRowThatAsksIsPushed() {
        var queue = queue([row(a, .working)])
        let joined = [row(a, .working), row(b, .needsInput, .codex)]
        #expect(queue.check(joined, away: true, pushes: .needsInput, at: t0) == nil)
        #expect(queue.check(joined, away: true, pushes: .needsInput, at: at(30))?.body == "Codex needs your input.")
    }

    // MARK: Rows

    /// Each row's status as the sidebar draws it, and the agent of its first tab in that status:
    /// a task's tabs by their tag, a terminal's by its window. A task on its way out is left out.
    @Test func pushRowsNameTheAgentOfTheTabInThatStatus() {
        let project = Project(id: UUID(), name: "client-x", path: "/repo", provider: .git, remoteUrl: nil, addedAt: t0, collapsed: false)
        let idle = UUID()
        func task(_ id: UUID, _ status: TaskStatus) -> TaskRow {
            TaskRow(id: id, title: "fix payroll export", jiraKey: "ACME-1", jiraUrl: nil, mr: nil, branch: .none,
                    avatars: AvatarGroup(marks: [], overflow: 0), status: status)
        }
        let terminal = TerminalRow(id: c, name: "Logs", branch: .none, avatars: AvatarGroup(marks: [], overflow: 0), status: .done)
        let section = ProjectSection(project: project, tasks: [task(a, .needsInput), task(b, .needsInput), task(idle, .idle)],
                                     terminals: [terminal])
        func tab(_ id: String, task: UUID?, _ agent: SessionAgent, _ state: SessionState, tab: Int, window: String) -> SessionInfo {
            SessionInfo(sessionId: id, windowId: window, tabIndex: tab, taskId: task?.uuidString, projectId: nil, agent: agent,
                        model: nil, state: state, title: "", cwd: "/repo")
        }
        let sessions = [
            tab("s2", task: a, .codex, .needsInput, tab: 1, window: "w1"),
            tab("s1", task: a, .claude, .idle, tab: 0, window: "w1"),
            tab("s3", task: a, .grok, .needsInput, tab: 2, window: "w1"),
            tab("s4", task: b, .claude, .needsInput, tab: 0, window: "w2"),
            tab("s5", task: nil, .pi, .done, tab: 0, window: "w9"),
        ]
        let rows = PushRow.rows(sections: [section], sessions: sessions, terminalWindows: [c: "w9"], skippingTasks: [b])
        #expect(rows == [PushRow(id: .terminal(c), status: .done, agent: .pi),
                         PushRow(id: .task(a), status: .needsInput, agent: .codex),
                         PushRow(id: .task(idle), status: .idle, agent: nil)])
    }

    // MARK: The broadcast

    private func broadcasting(_ run: OperatorRun, _ tasks: [TaskItem] = []) -> AppState {
        var state = AppState()
        state.append(project: web)
        state.runs = [run]
        state.tasks = tasks
        return state
    }

    private var web: Project { OperatorUIFixtures.project("pluto-web") }

    /// A worker's prompt is its task's row's to push: the broadcast's row needs you only for what moves
    /// no task row — the Operator's own question, a blocked task — and is named by the Operator's agent.
    @Test func theBroadcastNeedsYouOnlyForWhatNoTaskRowCarries() {
        var run = OperatorUIFixtures.run()
        let worker = OperatorUIFixtures.task("Fix the footer", agent: .codex, project: web.id,
                                             operated: OperatorUIFixtures.operated(run: run.id, key: "t", state: .working))
        run.questions = [OperatorQuestion(id: "prompt-1", text: "Codex asks to run npm install", task: worker.id, askedAt: t0)]
        #expect(PushRow.broadcast(state: broadcasting(run, [worker])) == PushRow(id: .broadcast(run.id), status: .idle, agent: .claude))
        run.questions.append(OperatorUIFixtures.question("Which footer copy should it use?"))
        #expect(PushRow.broadcast(state: broadcasting(run, [worker])) == PushRow(id: .broadcast(run.id), status: .needsInput, agent: .claude))
        let blocked = OperatorUIFixtures.task("Fix the header", project: web.id,
                                              operated: OperatorUIFixtures.operated(run: run.id, key: "h", state: .blocked,
                                                                                    blockedReason: "it needs a decision"))
        #expect(PushRow.broadcast(state: broadcasting(OperatorUIFixtures.run(id: run.id), [blocked]))?.status == .needsInput)
    }

    @Test func theBroadcastIsDoneOnceItsDebriefIsReady() {
        #expect(PushRow.broadcast(state: broadcasting(OperatorUIFixtures.run(state: .complete)))?.status == .done)
        #expect(PushRow.broadcast(state: broadcasting(OperatorUIFixtures.run(state: .stopped))) == nil, "ended: no row")
        #expect(PushRow.broadcast(state: AppState()) == nil)
    }
}
