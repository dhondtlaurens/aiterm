import Foundation
import AppKit
import SwiftUI
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalSidebarTests {
    @Test func theOperatorsOwnPermissionPromptOutranksItsTaskAct() {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.currentAct = "consulting the Oracle" }
        let own = OperatorServiceFixtures.session("operator", tag: world.state.operatorSession!.id, state: .needsInput)
        #expect(SignalOperatorRowValue.make(state: world.state, sessions: [own]).status == .needsInput)
    }
    @Test func anOperatorFailureIsADrawnFactInTheProjection() throws {
        let controller = AppController(preferences: .scratch()); try controller.workspace.load()
        defer { controller.shutdown() }
        controller.rows.operatorIssue = { "The Operator could not sign in." }
        controller.rows.refresh()
        #expect(controller.rows.signalOperator.status == .needsInput)
        #expect(controller.rows.signalOperator.line.tooltip.contains("sign in"))
    }
    @Test func aQuestionNotificationSelectsTheOperatorThroughTheManagedFocusPath() throws {
        let controller = AppController(preferences: .scratch()); try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        controller.workspace.mutate { state in
            var session = OperatorSession(createdAt: Date()); session.window = "operator-window"; state.operatorSession = session
        }
        controller.helper.setDaemonClient(RecordingDaemon())
        controller.openNote(.operatorWindow)
        #expect(controller.focus.selection == .operation(OperatorSession.rowID))
    }
    @Test func headingsHoldTheSameTaskRowsAndTakeoverReturnsTheTaskToItsProject() throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let entries = SidebarModel.entries(state: world.state, sessions: [], branchByCwd: [:], projectBranch: [:])
        let sidebar = SignalSidebar(state: world.state, entries: entries)
        #expect(sidebar.signals.count == 1)
        #expect(sidebar.signals[0].tasks.map(\.id) == [id])
        let ordinary: [TaskRow] = sidebar.projects.flatMap { entry -> [TaskRow] in
            if case .project(let section) = entry { return section.tasks }; return []
        }
        #expect(ordinary.isEmpty)
        world.state.updateSignalTask(id) { $0.takenOver = true }
        let taken = SignalSidebar(state: world.state, entries: entries)
        #expect(taken.signals[0].tasks.isEmpty)
        let projectTasks: [UUID] = taken.projects.flatMap { entry -> [UUID] in
            if case .project(let section) = entry { return section.tasks.map(\.id) }; return []
        }
        #expect(projectTasks == [id])
    }
    @Test func theOperatorRowExistsAndCanBeSelectedBeforeItsFirstSession() throws {
        let folder = try ScratchFolder.make("aiterm-signal-sidebar-"); defer { try? FileManager.default.removeItem(at: folder) }
        let controller = AppController(store: StateStore(url: folder.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        #expect(controller.focus.row(id: OperatorRow.id(of: OperatorSession.rowID)) == .operation(OperatorSession.rowID))
        #expect(controller.rows.signalSections.isEmpty)
    }
    @Test func thePermanentRowAndSignalHeadersLeaveProjectsVisible() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        let (host, window) = HostedSidebar.make(controller, size: CGSize(width: 420, height: 600))
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTableView.self)?.numberOfRows == 4 }
        let list = try #require(host.firstDescendant(NSTableView.self))
        #expect(list.numberOfRows == 4, "Operator heading, permanent row, Projects heading and empty state")
        var world = SignalWorld(); _ = world.signal(); _ = world.workingTask(signal: world.state.signals[0].id)
        controller.workspace.mutate { $0 = world.state }
        settle(host) { list.numberOfRows == 6 }
        #expect(list.numberOfRows == 6, "A signal holds its task while its project remains visible")
        controller.toggleCollapsed(world.state.signals[0])
        settle(host) { list.numberOfRows == 5 }
        #expect(list.numberOfRows == 5)
        controller.toggleCollapsed(world.state.signals[0])
        settle(host) { list.numberOfRows == 6 }
        #expect(list.numberOfRows == 6)
    }
    @Test func signalRowsDescribeActsQuestionsWatchingAndTheirOwnPause() throws {
        var world = SignalWorld(); let signal = world.signal(done: .hasReviewer); let id = world.workingTask(signal: signal)
        func row() throws -> TaskRow {
            let entries = SidebarModel.entries(state: world.state, sessions: [], branchByCwd: [:], projectBranch: [:])
            return try #require(SignalSidebar(state: world.state, entries: entries).signals.first?.tasks.first)
        }
        world.state.updateSignalTask(id) { $0.currentAct = "answering its worker" }
        #expect(try row().operatorLine == OperatorLine("Operator answering its worker", look: .acting))
        world.state.updateSignalTask(id) { $0.currentAct = nil }
        let questionAt = world.now
        world.state.operatorSession?.questions = [OperatorSession.Question(id: "locale", task: id, text: "Which locale?", openedAt: questionAt)]
        #expect(try row().operatorLine?.text == "waiting on you")
        #expect(try row().status == .needsInput)
        world.state.operatorSession?.questions = []
        world.state.updateSignalTask(id) { $0.phase = .watching(.hasReviewer) }
        #expect(try row().operatorLine?.text == "waiting on a reviewer")
        #expect(try row().status == .idle)
        world.state.signals[0].enabled = false
        #expect(try row().operatorLine == .paused)
        #expect(try row().paused == true)
    }
    @Test func signalHeadersAreSelectableAndAFoldDoesNotFoldItsProject() throws {
        var world = SignalWorld(); let signal = world.signal(); _ = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let controller = AppController(store: h.file, preferences: .scratch())
        try controller.workspace.load()
        #expect(controller.focus.row(id: signal) == .signal(signal))
        controller.focus.browse(.signal(signal)); controller.activateSelection()
        #expect(controller.state.signal(id: signal)?.collapsed == true)
        #expect(controller.state.project(id: world.project.id)?.collapsed == false)
        #expect(controller.focus.selection == .signal(signal))
    }
    @Test func anOrdinaryUntaggedPermissionPromptDoesNotBecomeTheOperators() {
        let session = SessionInfo(sessionId: "shell", windowId: "window", tabIndex: 0, taskId: nil,
            projectId: nil, agent: .claude, model: nil, state: .needsInput, title: "", cwd: "/")
        #expect(SignalOperatorRowValue.make(state: AppState(), sessions: [session]) == .empty)
    }
    @Test func theOperatorNamesItsActAndCountsTheSignalsStillHoldingTasks() throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        world.state.tasks[0].jira = JiraRef(key: "PAY-1", summary: "Retries", url: "https://jira.example/browse/PAY-1")
        world.state.updateSignalTask(id) { $0.currentAct = "answering its worker" }
        let acting = SignalOperatorRowValue.make(state: world.state, sessions: [])
        #expect(acting.line.text.contains("answering") && acting.line.text.contains("PAY-1"))
        world.state.updateSignalTask(id) { $0.currentAct = nil }
        world.state.signals = []
        #expect(SignalOperatorRowValue.make(state: world.state, sessions: []).line.text == "watching 1 task in 1 signal")
    }

}
