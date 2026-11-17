import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// A task row's trailing mark: its status's `StatusMark`, the green check once the Operator's work on the task
/// is over, or the pause sign while paused.
@Suite struct TaskRowMarkTests {
    let ended = OperatorLine("merged · 9b3e07d", look: .ended)

    @Test func anEndedTaskShowsTheCheckInPlaceOfItsIdleSessionOrItsUnseenTurn() {
        #expect(TaskRowMark(status: .idle, line: ended) == .ended)
        #expect(TaskRowMark(status: .done, line: ended) == .ended, "the last turn is the Operator's to read")
    }

    @Test func aSessionInUseAndEveryOtherLineKeepTheirOwnMark() {
        #expect(TaskRowMark(status: .working, line: ended) == .status(.working))
        #expect(TaskRowMark(status: .needsInput, line: ended) == .status(.needsInput))
        #expect(TaskRowMark(status: .background, line: ended) == .status(.background))
        #expect(TaskRowMark(status: .idle, line: OperatorLine("failed · the tests fail")) == .status(.idle))
        #expect(TaskRowMark(status: .done, line: OperatorLine("left for you · 4f2a91c", look: .needsYou)) == .status(.done))
        #expect(TaskRowMark(status: .done, line: nil) == .status(.done), "a task of your own")
    }

    @Test func aTaskPausedByYouShowsThePauseSign() {
        #expect(TaskRowMark(status: .idle, line: .paused, paused: true) == .pauseSign)
    }
}

/// The mark and "needs you" each row carries, decided where its status is: a task of your own or a terminal needs you
/// when done or needing input; a driven task only when it needs input.
@Suite struct RowNeedsYouTests {
    private func tab(_ id: UUID, _ state: SessionState) -> SessionInfo {
        SessionInfo.make("worker", window: "worker-window", task: id, state: state)
    }
    private func projectRow(_ state: AppState, _ id: UUID, sessions: [SessionInfo]) throws -> TaskRow {
        let sections = SidebarModel.sections(state: state, sessions: sessions, branchByCwd: [:], projectBranch: [:])
        return try #require(sections.flatMap(\.tasks).first { $0.id == id })
    }
    /// The driven row as the sidebar draws it: its project row, presented under the Operator.
    private func drivenRow(_ world: SignalWorld, _ id: UUID, sessions: [SessionInfo] = []) throws -> TaskRow {
        let task = try #require(world.state.task(id: id))
        return try projectRow(world.state, id, sessions: sessions).presentingOperator(task: task, state: world.state, act: nil)
    }

    @Test func aTaskOfYourOwnNeedsYouWhenDoneOrNeedingInput() throws {
        var state = AppState.empty
        let project = Project.make(name: "repo", path: "/repo", addedAt: Date())
        let task = TaskItem.make(project: project.id, worktreePath: "/repo/a", model: "opus", createdAt: Date(), windowId: "worker-window")
        state.append(project: project); state.tasks = [task]
        for status in [SessionState.done, .needsInput] {
            let row = try projectRow(state, task.id, sessions: [tab(task.id, status)])
            #expect(row.needsYou, "\(status)")
            #expect(row.mark == .status(TaskStatus(status)))
        }
        for status in [SessionState.idle, .working] {
            #expect(try !projectRow(state, task.id, sessions: [tab(task.id, status)]).needsYou, "\(status)")
        }
    }

    @Test func aTerminalNeedsYouWhenDone() throws {
        var state = AppState.empty
        let project = Project.make(name: "repo", path: "/repo", addedAt: Date())
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "t", createdAt: Date())
        state.append(project: project); state.terminals = [terminal]
        func row(_ status: SessionState) -> TerminalRow? {
            SidebarModel.sections(state: state, sessions: [SessionInfo.make("shell", window: "t", state: status)],
                                  branchByCwd: [:], projectBranch: [:]).first?.terminals.first
        }
        #expect(row(.done)?.needsYou == true)
        #expect(row(.needsInput)?.needsYou == true)
        #expect(row(.working)?.needsYou == false)
    }

    @Test func aDrivenTaskWaitingIdleOrDoneDoesNotNeedYou() throws {
        var world = SignalWorld(); let signal = world.signal(done: .approved), id = world.workingTask(signal: signal)
        let waiting = try drivenRow(world, id, sessions: [tab(id, .done)])
        #expect(waiting.status == .waiting && !waiting.needsYou, "a turn its worker ended is the Operator's to read")
        world.state.updateSignalTask(id) { $0.phase = .watching(.approved) }
        #expect(try !drivenRow(world, id, sessions: [tab(id, .idle)]).needsYou)
        world.state.updateSignalTask(id) { $0.phase = .watching(.unknown(["kind": "future"])) }
        let idle = try drivenRow(world, id, sessions: [tab(id, .idle)])
        #expect(idle.status == .idle && !idle.needsYou)
        world.state.updateSignalTask(id) { $0.phase = .done }
        #expect(try !drivenRow(world, id, sessions: [tab(id, .done)]).needsYou)
    }

    @Test func aDrivenTaskWithAQuestionBlockedOrAskingNeedsYou() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let asking = try drivenRow(world, id, sessions: [tab(id, .needsInput)])
        #expect(asking.needsYou && asking.mark == .status(.needsInput), "a permission prompt keeps its status mark")
        let askedAt = world.now
        world.state.operatorSession?.questions = [.init(id: "q", task: id, text: "Which locale?", openedAt: askedAt)]
        #expect(try drivenRow(world, id).needsYou)
        world.state.operatorSession?.questions = []
        world.state.updateSignalTask(id) { $0.phase = .blocked; $0.blockedReason = "Pick a project." }
        #expect(try drivenRow(world, id).needsYou)
    }

    @Test func aPausedDrivenRowHasThePauseSignIsIdleAndDoesNotNeedYou() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.operatorSession?.paused = true
        let row = try drivenRow(world, id, sessions: [tab(id, .idle)])
        #expect(row.mark == .pauseSign && row.status == .idle && !row.needsYou)
    }

    @Test func aDoneStageHasTheCheckWhileIdleAndItsStatusMarkWhileItsWorkerWorks() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .done }
        #expect(try drivenRow(world, id, sessions: [tab(id, .idle)]).mark == .ended)
        #expect(try drivenRow(world, id, sessions: [tab(id, .done)]).mark == .ended)
        #expect(try drivenRow(world, id, sessions: [tab(id, .working)]).mark == .status(.working))
    }
}
