import Foundation
import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalSidebarTests {
    @Test func aSignalTaskKeepsTheOrdinaryTasksTwoLineHeight() throws {
        let controller = AppController(preferences: .scratch()); try controller.workspace.load()
        defer { controller.shutdown() }
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.currentAct = "answering its worker" }
        controller.workspace.mutate { $0 = world.state }
        let driven = try #require(controller.rows.signalSections.first?.tasks.first)
        let task = try #require(controller.state.task(id: id))
        func height(_ row: TaskRow, _ item: TaskItem) -> CGFloat {
            NSHostingView(rootView: TaskRowView(row: row, task: item, controller: controller)
                .frame(width: Size.sidebarWidth).environment(\.motionStill, .snapshot).surface(.sidebar)).fittingSize.height
        }
        let drivenHeight = height(driven, task)
        controller.workspace.mutate { $0.updateSignalTask(id) { $0.takenOver = true } }
        let ordinary = try #require(controller.rows.sections.flatMap(\.tasks).first { $0.id == id })
        #expect(drivenHeight == height(ordinary, try #require(controller.state.task(id: id))))
        #expect(drivenHeight == Size.row)
    }

    @Test func unsupportedSavedSignalsExplainWhyTheyCannotRunInTheirHeading() {
        var world = SignalWorld(); _ = world.signal()
        world.state.signals[0].source = .gitHub(RequestConditions(event: .unknown("future")))
        let sidebar = SignalSidebar(state: world.state, entries: [])
        #expect(SignalHeadingValue(sidebar.signals[0]).help.contains("cannot run"))
    }
    @Test func backpackModeWaitsForOrphanedStagesButNotUnsupportedSources() throws {
        let controller = AppController(preferences: .scratch()); try controller.workspace.load()
        defer { controller.shutdown() }
        var world = SignalWorld(); let signal = world.signal(); _ = world.workingTask(signal: signal)
        world.state.signals = []
        controller.workspace.mutate { $0 = world.state }
        #expect(controller.backpack.operatorCanStartWork, "A removed source's current stage still carries on.")
        controller.workspace.mutate { $0.operatorSession?.paused = true }
        #expect(!controller.backpack.operatorCanStartWork)
        world.state.tasks = []; _ = world.signal()
        world.state.signals[0].source = .gitHub(RequestConditions(event: .reviewRequested))
        world.state.signals[0].finish = SignalFinish(doneWhen: .approved, mergesWhenReady: true)
        controller.workspace.mutate { $0 = world.state }
        #expect(!controller.backpack.operatorCanStartWork, "An unsupported saved signal cannot start work.")
    }
    @Test func theOperatorsOwnPermissionPromptOutranksItsTaskAct() {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.currentAct = "consulting the Oracle" }
        let own = OperatorServiceFixtures.session("operator", tag: world.state.operatorSession!.id, state: .needsInput)
        world.state.operatorSession?.window = own.windowId
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
    /// The projects are the default: with nothing to fold, OPERATOR is a heading and its "+"; once a signal exists the
    /// two sections fold into each other, the Operator's folded until it is opened, which folds the projects.
    @Test func theOperatorAndTheProjectsFoldIntoEachOtherTheProjectsOpenByDefault() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        let (host, window) = HostedSidebar.make(controller, size: CGSize(width: 420, height: 600))
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTableView.self)?.numberOfRows == 3 }
        let list = try #require(host.firstDescendant(NSTableView.self))
        #expect(list.numberOfRows == 3, "Operator heading, Projects heading and empty state: no signal, no Operator row")
        #expect(!controller.rows.operatorHeading.folds)
        controller.toggleOperatorOpen()
        #expect(!controller.state.operatorOpen, "Nothing to fold: the projects stay open")

        var world = SignalWorld(); _ = world.signal(); _ = world.workingTask(signal: world.state.signals[0].id)
        controller.workspace.mutate { $0 = world.state }
        settle(host) { list.numberOfRows == 3 }
        #expect(list.numberOfRows == 3, "Operator heading folded, Projects heading, the project")
        #expect(controller.rows.operatorHeading == SectionFold(folds: true, folded: true, attention: 0))
        #expect(controller.rows.projectsHeading == SectionFold(folds: true, folded: false, attention: 0))

        controller.toggleOperatorOpen()
        settle(host) { list.numberOfRows == 5 }
        #expect(list.numberOfRows == 5, "Operator heading, its row, the signal and its task, Projects heading folded")
        #expect(controller.state.operatorOpen, "kept with the workspace")
        controller.toggleCollapsed(world.state.signals[0])
        settle(host) { list.numberOfRows == 4 }
        #expect(list.numberOfRows == 4)
        controller.toggleCollapsed(world.state.signals[0])
        controller.toggleOperatorOpen()
        settle(host) { list.numberOfRows == 3 }
        #expect(list.numberOfRows == 3)
    }

    /// Folded, a section counts what needs you once; its count, or a row selected from elsewhere, opens it.
    @Test func aRowNeedingYouInTheFoldedSectionIsCountedAndRevealed() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let asked = world.now
        world.state.operatorSession?.questions = [OperatorSession.Question(id: "q", task: id, text: "Which locale?", openedAt: asked)]
        controller.workspace.mutate { $0 = world.state }
        #expect(controller.rows.operatorHeading.attention == 2, "the Operator's row says it waits on you, and so does the task")
        controller.openOperatorAttention()
        #expect(controller.rows.operatorOpen)
        #expect(controller.focus.selection == .operation(OperatorSession.rowID), "its first row that needs you")
        #expect(controller.rows.operatorHeading.attention == 0, "open, the rows say it themselves")

        controller.reveal(.project(world.project.id))
        #expect(!controller.rows.operatorOpen, "a project row opens the projects")
        controller.reveal(.operation(OperatorSession.rowID))
        #expect(controller.rows.operatorOpen, "the Operator's row opens its section")
    }
    /// ↓ on the Operator's last row reaches the first project, folding the Operator; ↑ on the first project reaches
    /// the Operator's last row, folding the projects. Anywhere else the list moves on its own.
    @Test func theArrowsCrossTheFoldAtTheEdgeOfEachSection() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        var world = SignalWorld(); let signal = world.signal(); let task = world.workingTask(signal: signal)
        let second = Project.make(name: "docs", path: "/synthetic/docs"); world.state.append(project: second)
        world.state.operatorOpen = true
        controller.workspace.mutate { $0 = world.state }
        #expect(controller.rows.operatorPath == [.operation(OperatorSession.rowID), .signal(signal), .task(task)])

        controller.focus.browse(.signal(signal))
        #expect(!controller.crossSections(down: true), "the signal's task is still below it")
        #expect(!controller.crossSections(down: false))
        controller.focus.browse(.task(task))
        #expect(!controller.crossSections(down: false), "↑ leaves the Operator's section only from the projects")
        #expect(controller.crossSections(down: true))
        #expect(controller.focus.selection == .project(world.project.id))
        #expect(!controller.rows.operatorOpen, "the projects open, the Operator folds")

        #expect(!controller.crossSections(down: true), "↓ on a project stays with the list")
        controller.focus.browse(.project(second.id))
        #expect(!controller.crossSections(down: false), "only the first project crosses")
        controller.focus.browse(.project(world.project.id))
        #expect(controller.crossSections(down: false))
        #expect(controller.focus.selection == .task(task), "the Operator's last row")
        #expect(controller.rows.operatorOpen, "the Operator opens, the projects fold")

        controller.toggleCollapsed(world.state.signals[0])
        #expect(controller.rows.operatorPath.last == .signal(signal), "a folded signal's heading is its last row")
        controller.focus.browse(.signal(signal))
        #expect(controller.crossSections(down: true))
        #expect(controller.crossSections(down: false))
        #expect(controller.focus.selection == .signal(signal))
    }

    /// The real key: a plain ↓ on the sidebar's list, at the edge, is taken before the table; ⇧↓ and a ↓ inside a
    /// section are left to it.
    @Test func aDownArrowOnTheListCrossesIntoTheProjects() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        var world = SignalWorld(); let task = world.workingTask(signal: world.signal())
        world.state.operatorOpen = true
        controller.workspace.mutate { $0 = world.state }
        let (host, window) = HostedSidebar.make(controller, size: CGSize(width: 420, height: 600), key: true)
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTableView.self)?.numberOfRows == 5 }
        let list = try #require(host.firstDescendant(NSTableView.self))
        #expect(window.makeFirstResponder(list))
        func press(_ modifiers: NSEvent.ModifierFlags = []) throws {
            NSApp.sendEvent(try #require(keyDown("\u{F701}", code: 125, modifiers: modifiers.union([.numericPad, .function]), in: window)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        controller.focus.browse(.task(task))
        settle(host, describing: "the task selected in the table") { list.selectedRow == 3 }
        try press(.shift)
        #expect(controller.rows.operatorOpen, "⇧↓ is the table's")
        #expect(controller.focus.selection == .task(task))
        try press()
        #expect(controller.focus.selection == .project(world.project.id))
        #expect(!controller.rows.operatorOpen)
        settle(host) { list.numberOfRows == 3 }
        #expect(list.numberOfRows == 3, "Operator heading folded, Projects heading, the project")
        #expect(SectionCrossing.direction(of: try #require(keyDown("\u{F700}", code: 126, modifiers: [.numericPad, .function], in: window))) == false)
        #expect(SectionCrossing.direction(of: try #require(keyDown("a", code: 0, in: window))) == nil)
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
        #expect(try row().operatorLine?.text == "waiting for a reviewer")
        #expect(try row().status == .waiting)
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
    /// Configured signals watch without a chat; unfinished work or real attention shows its row.
    @Test func theOperatorRowIsLeftOutWhileItHasNothingToWatch() throws {
        #expect(!SignalOperatorRowValue.make(state: AppState(), sessions: []).shown)
        var paused = AppState(); var session = OperatorSession(createdAt: Date()); session.paused = true; paused.operatorSession = session
        #expect(!SignalOperatorRowValue.make(state: paused, sessions: []).shown, "paused with nothing to watch")
        #expect(SignalOperatorRowValue.make(state: AppState(), sessions: [], issue: "The Operator could not sign in.").shown)

        var world = SignalWorld(); let signal = world.signal()
        #expect(!SignalOperatorRowValue.make(state: world.state, sessions: []).shown, "a signal with no task yet")
        _ = world.workingTask(signal: signal); world.state.signals = []
        #expect(SignalOperatorRowValue.make(state: world.state, sessions: []).shown, "a task left from a removed signal")
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
