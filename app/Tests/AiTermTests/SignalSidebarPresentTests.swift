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
        return try #require(SignalSidebar(state: world.state, entries: entries, acts: acts).operatorSections.first?.tasks.first)
    }
    private func tab(_ id: UUID, _ state: SessionState) -> SessionInfo {
        SessionInfo.make("worker", window: "worker-window", task: id, state: state)
    }
    private func watching(_ done: SignalTrigger, facts: SignalWaitFacts? = nil) -> (SignalWorld, UUID) {
        var world = SignalWorld(); let signal = world.signal(done: done), id = world.workingTask(signal: signal)
        world.state.tasks[0].mr = .init(iid: 102, title: "Work", url: "https://git.example/shop/web/-/merge_requests/102")
        world.state.updateSignalTask(id) { $0.phase = .watching; $0.waitingOn = facts }
        return (world, id)
    }
    private static let approved = SignalTrigger(source: .gitLab, query: "reviewer:@me review-state:approved")

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
        world.state.updateSignalTask(id) { $0.phase = .watching }
        #expect(try row(world, sessions: [tab(id, .working)]).status == .working)
    }

    // MARK: - A task watching its Done trigger

    /// The line is the Done trigger's description when the person wrote one, else its query, with the waiting ring.
    @Test func aWatchingTaskSaysItsDoneTriggersDescriptionElseItsQuery() throws {
        let (query, _) = watching(Self.approved)
        #expect(try row(query).status == .waiting)
        #expect(try row(query).operatorLine?.text == "reviewer:@me review-state:approved")
        #expect(try row(query).operatorLine?.tooltip == "Waiting for its Done trigger: reviewer:@me review-state:approved")
        var described = Self.approved; described.description = "When I’ve approved it"
        let (words, _) = watching(described)
        #expect(try row(words).operatorLine?.text == "When I’ve approved it")
        var blank = Self.approved; blank.description = "  "
        #expect(try row(watching(blank).0).operatorLine?.text == "reviewer:@me review-state:approved", "blank words are no description")
    }
    @Test func aLongLineIsCutToFortyCharactersAndTheTooltipKeepsItAll() {
        let query = #"status = "Ready for Acceptance Testing" AND labels = operator"#
        let long = OperatorLine.waiting(for: SignalTrigger(source: .jira, query: query), facts: nil)
        #expect(long.text == "status = \"Ready for Acceptance Testing\"…" && long.text.count == OperatorLine.maxLength)
        #expect(long.tooltip == "Waiting for its Done trigger: " + query)
    }
    @Test func aTaskHeldForItsMergeSaysWhatTheMergeLacks() throws {
        let (held, _) = watching(Self.approved, facts: SignalWaitFacts(mergeBlockers: [.checks]))
        #expect(try row(held).status == .waiting)
        #expect(try row(held).operatorLine?.text == "waiting to merge · checks")
        #expect(try row(held).operatorLine?.tooltip == "!102 merges once it has green checks.")
        let all = OperatorLine.waiting(for: Self.approved, facts: SignalWaitFacts(mergeBlockers: [.approval, .checks, .threads, .push]))
        #expect(all.text == "waiting to merge · approval, checks, th…" && all.text.count == OperatorLine.maxLength)
        #expect(all.tooltip == "The request merges once it has an approval, green checks, every thread resolved and its local commits pushed.")
        #expect(OperatorLine.waiting(for: Self.approved, facts: SignalWaitFacts(mergeBlockers: [])).text == "waiting to merge")
        let host = OperatorLine.waiting(for: Self.approved, facts: SignalWaitFacts(mergeBlockers: [.host]), request: "!102")
        #expect(host.text == "waiting to merge · host check")
        #expect(host.tooltip == "!102 merges once it has the host’s go-ahead (no conflicts, nothing else it waits on).")
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
        #expect(try row(world).operatorLine == .paused && row(world).status == .idle && row(world).mark == .pauseSign)
    }

    // MARK: - Finished is past pausing

    /// A finished task (done, its Then applied, nothing pending) is past pausing: under a paused Operator or a switched-off
    /// signal it still says "done" with the finished mark and counts as finished. A done task whose closeout is still
    /// outstanding is workload, so the pause holds it: paused, not finished (found in the plan's review, 20 Nov 2026).
    @Test func aFinishedTaskStaysDoneUnderAPauseAndOnlyItCountsAsFinished() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .done; $0.thenApplied = true }
        #expect(try row(world).finished && row(world).mark == .ended && row(world).operatorLine?.text == "done")
        world.state.operatorSession?.paused = true
        #expect(try row(world).finished && row(world).mark == .ended && row(world).operatorLine?.text == "done", "a paused Operator")
        world.state.operatorSession?.paused = false
        world.state.signals[0].enabled = false
        #expect(try row(world).finished && row(world).mark == .ended, "a switched-off signal")

        world.state.signals[0].enabled = true
        world.state.updateSignalTask(id) { $0.thenApplied = nil }
        #expect(try !row(world).finished && row(world).mark == .ended, "its closeout outstanding: workload, not finished")
        world.state.operatorSession?.paused = true
        #expect(try !row(world).finished && row(world).mark == .pauseSign && row(world).operatorLine == .paused,
                "the pause holds its closeout")
        world.state.updateSignalTask(id) { $0.phase = .watching }
        #expect(try !row(world).finished)
    }

    // MARK: - Counted as waiting, never as working

    @Test func aFoldedSectionCountsWaitingTasksAsWaiting() throws {
        var world = SignalWorld(); let signal = world.signal(done: Self.approved)
        let first = world.workingTask(signal: signal), second = world.workingTask(signal: signal)
        world.state.updateSignalTask(second) { $0.phase = .watching }
        world.state.operatorFolded = [world.project.id]
        let entries = SidebarModel.entries(state: world.state, sessions: [tab(first, .idle)], branchByCwd: [:], projectBranch: [:])
        let section = try #require(SignalSidebar(state: world.state, entries: entries).operatorSections.first)
        let heading = HeadingValue(operatorSection: section)
        #expect(heading.counts == [StatusCount(status: .waiting, count: 2)])
        #expect(SidebarModel.statusCountsLabel(heading.counts) == "2 waiting")
    }
    @Test func theOperatorRowAndTheDockBadgeDoNotCountAWaitingTask() throws {
        var world = SignalWorld(); let signal = world.signal(done: Self.approved), id = world.workingTask(signal: signal)
        let worker = tab(id, .idle)
        let operatorRow = SignalOperatorRowValue.make(state: world.state, sessions: [worker])
        #expect(operatorRow.status == .idle)
        #expect(operatorRow.line.text == "watching")
        let entries = SidebarModel.entries(state: world.state, sessions: [worker], branchByCwd: [:], projectBranch: [:])
        let sidebar = SignalSidebar(state: world.state, entries: entries)
        #expect(sidebar.operatorSections[0].tasks[0].status == .waiting)
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        controller.live.handle(.sessionOpened(worker))
        #expect(controller.rows.projectsNeedingAttention.isEmpty)
        #expect(!sidebar.operatorSections[0].tasks.contains { $0.needsYou })
    }
}
