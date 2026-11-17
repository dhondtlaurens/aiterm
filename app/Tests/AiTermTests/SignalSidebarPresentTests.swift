import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// A driven task that waits, on a turn, the Operator or a person, draws the waiting ring and says what it waits for;
/// only a worker or the Operator busy now draws the spinner (seen 16 Nov 2026 on two requests that read `working`).
@Suite @MainActor struct SignalSidebarPresentTests {
    private func row(_ world: SignalWorld, sessions: [SessionInfo] = [], acts: [UUID: String] = [:]) throws -> TaskRow {
        let entries = SidebarModel.entries(state: world.state, sessions: sessions, branchByCwd: [:], projectBranch: [:])
        return try #require(SignalSidebar(state: world.state, entries: entries, acts: acts).signals.first?.tasks.first)
    }
    private func tab(_ id: UUID, _ state: SessionState) -> SessionInfo {
        SessionInfo.make("worker", window: "worker-window", task: id, state: state)
    }
    private func watching(_ condition: DoneWhen, facts: SignalWaitFacts? = nil) -> (SignalWorld, UUID) {
        var world = SignalWorld(); let signal = world.signal(done: condition), id = world.workingTask(signal: signal)
        world.state.tasks[0].mr = .init(iid: 102, title: "Work", url: "https://git.example/shop/web/-/merge_requests/102")
        world.state.updateSignalTask(id) { $0.phase = .watching(condition); $0.waitingOn = facts }
        return (world, id)
    }

    // MARK: - A working task whose workers ended their turn

    @Test func aWorkingTaskWhoseWorkersEndedTheirTurnWaitsOnTheOperator() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        for state in [SessionState.idle, .done] {
            let row = try row(world, sessions: [tab(id, state)])
            #expect(row.status == .waiting, "\(state)")
            #expect(row.operatorLine == .workerDone)
            #expect(row.operatorLine?.text == "worker done · Operator to review")
            #expect(row.operatorLine?.look == .quiet, "Nothing the Operator does yet")
        }
        #expect(try row(world).status == .waiting, "No worker tab at all is no worker at work either")
        #expect(try row(world, sessions: [tab(id, .idle)], acts: [id: "answering its worker"]).status == .working, "An Operator act spins")
    }
    @Test func aWorkerAtWorkKeepsTheSpinnerAndItsBackgroundWorkItsRing() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let working = try row(world, sessions: [tab(id, .working)])
        #expect(working.status == .working && working.operatorLine == nil, "The line reads its quiet working")
        world.state.updateSignalTask(id) { $0.phase = .watching(.approved) }
        #expect(try row(world, sessions: [tab(id, .working)]).status == .working)
    }

    // MARK: - A task watching its done condition

    @Test func everyDoneConditionSaysWhatItWaitsForWithTheWaitingRing() throws {
        let lines: [(DoneWhen, String, String)] = [
            (.operatorJudges, "waiting for the Operator", "Waiting for the Operator to judge this stage done."),
            (.hasReviewer, "waiting for a reviewer", "Waiting for someone to be asked to review !102."),
            (.approved, "waiting on reviewer approval", "Waiting for a reviewer to approve !102."),
            (.threadsResolved, "waiting on review threads", "Waiting for the review threads on !102 to be resolved."),
            (.merged, "waiting for the merge", "Waiting for !102 to be merged."),
            (.mergedOrClosed, "waiting for merge or close", "Waiting for !102 to be merged or closed."),
            (.ticketStatus("Done"), "waiting for ticket to reach Done", "Waiting for PAY-1 to move to “Done”."),
            (.myReviewPosted, "waiting for you to post the review", "Waiting for your review of !102 to be posted."),
        ]
        for (condition, text, tooltip) in lines {
            var (world, _) = watching(condition)
            world.state.tasks[0].jira = JiraRef(key: "PAY-1", summary: "Make retries safe", url: "https://jira.example/browse/PAY-1")
            let row = try row(world)
            #expect(row.status == .waiting, "\(condition)")
            #expect(row.operatorLine?.text == text, "\(condition)")
            #expect(row.operatorLine?.tooltip == tooltip, "\(condition)")
            #expect((row.operatorLine?.text.count ?? 99) <= OperatorLine.maxLength, "\(condition)")
        }
        let (unknown, _) = watching(.unknown(["kind": "future"]))
        #expect(try row(unknown).status == .idle, "A condition this version cannot read waits on nothing it knows")
    }
    @Test func anApprovalNamesTheRequestsReviewersByFirstName() throws {
        let (one, _) = watching(.approved, facts: SignalWaitFacts(reviewers: ["Lawrence De Spiegeleire"]))
        #expect(try row(one).operatorLine?.text == "waiting on approval · Lawrence")
        #expect(try row(one).operatorLine?.tooltip == "Waiting for Lawrence De Spiegeleire to approve !102.")
        let (two, _) = watching(.approved, facts: SignalWaitFacts(reviewers: ["Lawrence De Spiegeleire", "jan-dv"]))
        #expect(try row(two).operatorLine?.text == "waiting on approval · Lawrence, jan-dv")
        #expect(try row(two).operatorLine?.tooltip == "Waiting for Lawrence De Spiegeleire or jan-dv to approve !102.")
        let (none, _) = watching(.approved, facts: SignalWaitFacts(reviewers: []))
        #expect(try row(none).operatorLine?.text == "waiting on reviewer approval", "No reviewer asked yet")
        let (unread, _) = watching(.approved, facts: SignalWaitFacts(openThreads: 2))
        #expect(try row(unread).operatorLine?.text == "waiting on reviewer approval", "Reviewers not read")
    }
    @Test func aLongLineIsCutToFortyCharactersAndTheTooltipKeepsItAll() {
        let many = OperatorLine.waiting(for: .approved, facts: SignalWaitFacts(reviewers: ["Lawrence De Spiegeleire", "Jan De Visscher", "Nathan Geleyn"]), request: "!103")
        #expect(many.text == "waiting on approval · Lawrence +2")
        #expect(many.tooltip == "Waiting for Lawrence De Spiegeleire, Jan De Visscher or Nathan Geleyn to approve !103.")
        let long = OperatorLine.waiting(for: .approved, facts: SignalWaitFacts(reviewers: ["Maximiliaan-Alexander Vandenberghe", "Jan"]))
        #expect(long.text.count == OperatorLine.maxLength && long.text.hasSuffix("… +1"), "\(long.text)")
        let status = OperatorLine.waiting(for: .ticketStatus("Ready for Acceptance Testing"), facts: nil, ticket: "PAY-1")
        #expect(status.text == "waiting for ticket to reach Ready for A…")
        #expect(status.text.count == OperatorLine.maxLength)
        #expect(status.tooltip == "Waiting for PAY-1 to move to “Ready for Acceptance Testing”.")
    }
    @Test func openThreadsAreCountedWhenTheDoneCheckReadThem() throws {
        let (three, _) = watching(.threadsResolved, facts: SignalWaitFacts(openThreads: 3))
        #expect(try row(three).operatorLine?.text == "waiting on 3 open threads")
        #expect(try row(three).operatorLine?.tooltip == "Waiting for 3 open review threads on !102 to be resolved.")
        let (one, _) = watching(.threadsResolved, facts: SignalWaitFacts(openThreads: 1))
        #expect(try row(one).operatorLine?.text == "waiting on 1 open thread")
        let (unread, _) = watching(.threadsResolved)
        #expect(try row(unread).operatorLine?.text == "waiting on review threads")
    }
    @Test func aMetConditionHeldForTheMergeSaysWhatTheMergeLacks() throws {
        let (judged, _) = watching(.operatorJudges, facts: SignalWaitFacts(mergeBlockers: [.checks]))
        #expect(try row(judged).status == .waiting)
        #expect(try row(judged).operatorLine?.text == "waiting to merge · checks")
        #expect(try row(judged).operatorLine?.tooltip == "Its done condition is met. !102 merges once it has green checks.")
        let all = OperatorLine.waiting(for: .approved, facts: SignalWaitFacts(reviewers: ["Ann"], mergeBlockers: [.approval, .checks, .threads, .push]))
        #expect(all.text == "waiting to merge · approval, checks, th…" && all.text.count == OperatorLine.maxLength)
        #expect(all.tooltip == "Its done condition is met. The request merges once it has an approval, green checks, every thread resolved and its local commits pushed.")
        #expect(OperatorLine.waiting(for: .approved, facts: SignalWaitFacts(mergeBlockers: [])).text == "waiting to merge")
        let host = OperatorLine.waiting(for: .approved, facts: SignalWaitFacts(mergeBlockers: [.host]), request: "!102")
        #expect(host.text == "waiting to merge · host check")
        #expect(host.tooltip == "Its done condition is met. !102 merges once it has the host’s go-ahead (no conflicts, nothing else it waits on).")
    }
    @Test func withoutARequestTheSentenceSaysTheRequest() {
        #expect(OperatorLine.waiting(for: .merged, facts: nil).tooltip == "Waiting for the request to be merged.")
        #expect(OperatorLine.waiting(for: .ticketStatus("Done"), facts: nil).tooltip == "Waiting for the ticket to move to “Done”.")
    }

    // MARK: - What stays as it was

    @Test func needsYouBlockedPausedWindowClosedAndDoneAreUnchanged() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        #expect(try row(world, sessions: [tab(id, .needsInput)]).status == .needsInput)
        let asked = world.now
        world.state.operatorSession?.questions = [.init(id: "q", task: id, text: "Which locale?", openedAt: asked)]
        #expect(try row(world).operatorLine?.look == .needsYou)
        world.state.operatorSession?.questions = []
        world.state.updateSignalTask(id) { $0.phase = .blocked; $0.blockedReason = "Pick a project." }
        #expect(try row(world).status == .needsInput && row(world).operatorLine?.text == "blocked")
        world.state.updateSignalTask(id) { $0.phase = .done }
        #expect(try row(world).status == .idle && row(world).operatorLine?.text == "done")
        world.state.updateSignalTask(id) { $0.phase = .working }
        world.state.tasks[0].windowId = nil; world.state.tasks[0].conversations = [.init(agent: .claude, id: "saved")]
        #expect(try row(world).operatorLine == .windowClosed && row(world).status == .idle)
        world.state.tasks[0].windowId = "worker-window"
        world.state.operatorSession?.paused = true
        #expect(try row(world).operatorLine == .paused && row(world).status == .idle)
    }

    // MARK: - Counted as waiting, never as working

    @Test func aFoldedSectionCountsWaitingTasksAsWaiting() throws {
        var world = SignalWorld(); let signal = world.signal(done: .approved)
        let first = world.workingTask(signal: signal), second = world.workingTask(signal: signal)
        world.state.updateSignalTask(second) { $0.phase = .watching(.approved) }
        world.state.signals[0].collapsed = true
        let entries = SidebarModel.entries(state: world.state, sessions: [tab(first, .idle)], branchByCwd: [:], projectBranch: [:])
        let section = try #require(SignalSidebar(state: world.state, entries: entries).signals.first)
        let heading = SignalHeadingValue(section)
        #expect(heading.counts == [StatusCount(status: .waiting, count: 2)])
        #expect(SidebarModel.statusCountsLabel(heading.counts) == "2 waiting")
    }
    @Test func theOperatorRowAndTheDockBadgeDoNotCountAWaitingTask() throws {
        var world = SignalWorld(); let signal = world.signal(done: .approved), id = world.workingTask(signal: signal)
        let worker = tab(id, .idle)
        let operatorRow = SignalOperatorRowValue.make(state: world.state, sessions: [worker])
        #expect(operatorRow.status == .idle)
        #expect(operatorRow.line.text == "watching 1 task in 1 signal")
        let entries = SidebarModel.entries(state: world.state, sessions: [worker], branchByCwd: [:], projectBranch: [:])
        let sidebar = SignalSidebar(state: world.state, entries: entries)
        #expect(sidebar.signals[0].tasks[0].status == .waiting)
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        controller.live.handle(.sessionOpened(worker))
        #expect(controller.rows.projectsNeedingAttention.isEmpty)
        #expect(!sidebar.signals[0].tasks.contains { $0.status.needsAttention })
    }
}
