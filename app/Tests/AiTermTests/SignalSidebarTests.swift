import Foundation
import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalSidebarTests {
    @Test func projectMovementEdgesChangeAfterTakeOverWithoutReorderingSignalTasks() throws {
        var world = SignalWorld()
        let signal = world.signal()
        let held = world.workingTask(signal: signal), otherHeld = world.workingTask(signal: signal)
        let own = TaskItem.make(project: world.project.id)
        world.state.tasks.append(own)
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        let rows = try #require(controller.rows.sections.first?.tasks)
        #expect(rows.count == 1 && !rows[0].canMove(.up) && !rows[0].canMove(.down))
        let signalRows = try #require(controller.rows.signalSections.first?.tasks)
        #expect(signalRows.map(\.id) == [held, otherHeld])
        for row in signalRows {
            #expect(!TaskRowView(row: row, controller: controller).commands(removing: false)
                .flatMap { $0 }.contains { $0.title == "Move Up" || $0.title == "Move Down" })
        }
        #expect(!controller.projects.move(taskId: held, .down))
        controller.workspace.mutate { $0.takeOver(held) }
        let takenOver = try #require(controller.rows.sections.first?.tasks)
        #expect(takenOver.map(\.id) == [held, own.id])
        #expect(takenOver.map { [$0.canMove(.up), $0.canMove(.down)] } == [[false, true], [true, false]])
        #expect(controller.projects.move(taskId: held, .down))
        #expect(controller.rows.sections.first?.tasks.map(\.id) == [own.id, held])
        #expect(controller.rows.signalSections.first?.tasks.map(\.id) == [otherHeld])
    }

    @Test(arguments: [false, true])
    func foldingASignalHandsItsSelectedTaskToTheHeading(removed: Bool) throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        world.state.operatorOpen = true
        if removed { world.state.signals = [] }
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        let daemon = RecordingDaemon(); controller.helper.setDaemonClient(daemon)
        controller.focus.browse(.task(task))
        controller.toggleCollapsed(try #require(controller.rows.signalSections.first).signal)
        #expect(controller.focus.selection == .signal(signal))
        #expect(controller.rows.signalSections.first?.collapsed == true)
        #expect(daemon.requests.isEmpty, "handing selection to a heading raises and marks nothing")
    }

    @Test(arguments: [false, true])
    func aTaskSelectedFromElsewhereSurvivesDerivationUntilReveal(removed: Bool) throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        world.state.operatorOpen = true
        if removed { world.state.signals = [] }
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        controller.toggleCollapsed(try #require(controller.rows.signalSections.first).signal)
        controller.focus.browse(.task(task))
        controller.workspace.mutate { $0.tasks[0].title = "Selected by notification" }
        #expect(controller.focus.selection == .task(task))
        #expect(controller.rows.signalSections.first?.collapsed == true)
        controller.reveal(.task(task))
        #expect(controller.focus.selection == .task(task))
        #expect(controller.rows.signalSections.first?.collapsed == false)
    }

    @Test(arguments: [false, true])
    func anOperatorRowThatDisappearsOrFoldsClearsSelection(fold: Bool) async throws {
        var world = SignalWorld(); _ = world.workingTask(signal: world.signal())
        world.state.operatorOpen = true
        let prompter = ScriptedPrompter(answering: "Cancel")
        let controller = AppController(preferences: .scratch(), prompter: prompter)
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        let daemon = RecordingDaemon(); controller.helper.setDaemonClient(daemon)
        #expect(controller.rows.signalOperator.shown)
        controller.focus.browse(.operatorChat)
        if fold { controller.toggleOperatorOpen() }
        else { controller.workspace.mutate { $0.tasks = []; $0.operatorSession = nil } }
        #expect(controller.focus.selection == nil)
        #expect(controller.rows.usageRow(for: controller.focus.selection) == nil)
        #expect(controller.activateSelection() == nil)
        await controller.removeSelection()
        #expect(daemon.requests.isEmpty)
        #expect(prompter.asked.isEmpty)
    }

    @Test func openingOperatorClearsASelectedProjectTask() throws {
        var world = SignalWorld(); _ = world.signal()
        let task = TaskItem.make(project: world.project.id, worktreePath: "/synthetic/task")
        world.state.tasks = [task]
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        controller.focus.browse(.task(task.id))
        controller.toggleOperatorOpen()
        #expect(controller.rows.operatorOpen)
        #expect(controller.focus.selection == nil)
    }

    @Test func takingOverASelectedDrivenTaskClearsItWhileProjectsAreFolded() throws {
        var world = SignalWorld(); let task = world.workingTask(signal: world.signal())
        world.state.operatorOpen = true
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        controller.focus.browse(.task(task))
        controller.workspace.mutate { $0.takeOver(task) }
        #expect(controller.focus.selection == nil)
        #expect(controller.rows.sections.first?.tasks.map(\.id) == [task])
    }

    @Test func signalHeadingsProjectRowsAndRemovalAgreeOnWhichTasksAreUnderTheOperator() async throws {
        var world = SignalWorld()
        let signal = world.signal(), working = world.workingTask(signal: signal), done = world.workingTask(signal: signal)
        world.state.updateSignalTask(done) { $0.phase = .done }
        let ordinary = TaskItem.make(project: world.project.id, worktreePath: "/synthetic/ordinary")
        world.state.tasks.append(ordinary)
        let prompter = ScriptedPrompter(answering: "Cancel", "Cancel", "Cancel")
        let controller = AppController(preferences: .scratch(), prompter: prompter)
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }

        let entries = SidebarModel.entries(state: controller.state, sessions: [], branchByCwd: [:], projectBranch: [:])
        let sidebar = SignalSidebar(state: controller.state, entries: entries)
        #expect(sidebar.signals.map(\.id) == [signal])
        #expect(sidebar.signals[0].tasks.map(\.id) == [working, done])
        let projectTasks = sidebar.projects.flatMap { entry -> [TaskRow] in
            if case .project(let section) = entry { return section.tasks }; return []
        }
        #expect(projectTasks.map(\.id) == [ordinary.id])
        #expect(controller.projects.hasRows(world.project))
        await controller.projects.confirmRemove(project: world.project)

        controller.workspace.mutate { $0.tasks.removeAll { $0.id == ordinary.id } }
        #expect(!controller.projects.hasRows(world.project))
        controller.workspace.mutate { state in
            state.tasks[state.tasks.firstIndex { $0.id == working }!].worktreePath = ""
            state.signals = []
        }
        #expect(controller.focus.row(id: signal) == .signal(signal))
        await controller.projects.confirmRemove(project: world.project)
        controller.workspace.mutate { state in
            state.tasks[state.tasks.firstIndex { $0.id == done }!].worktreePath = ""
        }
        await controller.projects.confirmRemove(project: world.project)

        #expect(prompter.asked.map(\.detail) == [
            "Removes the project and its 3 tasks from AiTerm. Files, worktrees and windows are kept. 2 worktrees are run by signals.",
            "Removes the project and its 2 tasks from AiTerm. Files, worktrees and windows are kept. 1 worktree is run by signals.",
            "Removes the project and its 2 tasks from AiTerm. Files, worktrees and windows are kept.",
        ])
        #expect(controller.state.project(id: world.project.id) != nil, "Cancel keeps the project.")
    }

    @Test func aSignalTaskKeepsTheOrdinaryTasksTwoLineHeight() throws {
        let controller = AppController(preferences: .scratch()); try controller.workspace.load()
        defer { controller.shutdown() }
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        controller.workspace.mutate { $0 = world.state }
        _ = controller.signalController.activity.begin(task: id, act: "answering its worker")
        let driven = try #require(controller.rows.signalSections.first?.tasks.first)
        func height(_ row: TaskRow) -> CGFloat {
            NSHostingView(rootView: TaskRowView(row: row, controller: controller)
                .frame(width: Size.sidebarWidth).environment(\.motionStill, .snapshot).surface(.sidebar)).fittingSize.height
        }
        let drivenHeight = height(driven)
        controller.workspace.mutate { $0.takeOver(id) }
        let ordinary = try #require(controller.rows.sections.flatMap(\.tasks).first { $0.id == id })
        #expect(drivenHeight == height(ordinary))
        #expect(drivenHeight == Size.row)
    }

    @Test func removedSignalHeadingsAreNotPausedButSwitchedOffLiveSignalsAre() throws {
        var world = SignalWorld(); let id = world.signal(); _ = world.workingTask(signal: id)
        world.state.signals[0].enabled = false
        let live = SignalSidebar(state: world.state, entries: [])
        #expect(HeadingValue(try #require(live.signals.first)).kind == .signal(source: world.state.signals[0].start.source, removed: false, paused: true, canMoveUp: false, canMoveDown: false))
        world.state.signals = []
        let removed = SignalSidebar(state: world.state, entries: [])
        #expect(HeadingValue(try #require(removed.signals.first)).kind == .signal(source: world.state.tasks[0].signalTask!.current.configuration.start.source, removed: true, paused: false, canMoveUp: false, canMoveDown: false))
    }

    /// Only live signals move: a removed signal's heading is drawn after the last live one and is no
    /// neighbour, so the last live heading cannot move down; a switched-off signal still moves and counts.
    @Test func signalHeadingsMoveAmongLiveSignalsOnly() throws {
        var world = SignalWorld()
        let first = world.signal(name: "First"), off = world.signal(name: "Off"), last = world.signal(name: "Last")
        let gone = world.signal(name: "Gone")
        world.workingTask(signal: gone)
        world.state.signals.removeAll { $0.id == gone }
        world.state.signals[1].enabled = false
        let sections = SignalSidebar(state: world.state, entries: []).signals
        #expect(sections.map(\.id) == [first, off, last, gone])
        #expect(sections.map { [$0.canMoveUp, $0.canMoveDown] } == [[false, true], [true, true], [true, false], [false, false]])
        #expect(HeadingValue(sections[1]).kind == .signal(source: .jira, removed: false, paused: true, canMoveUp: true, canMoveDown: true))
        world.state.signals = [world.state.signals[0]]
        let alone = try #require(SignalSidebar(state: world.state, entries: []).signals.first)
        #expect(!alone.canMoveUp && !alone.canMoveDown)
    }

    @Test func aRemovedSignalsFoldIsRuntimeOnlyAndStartsOpen() throws {
        var world = SignalWorld(); let id = world.signal()
        _ = world.workingTask(signal: id); _ = world.workingTask(signal: id)
        world.state.tasks[0].signalTask?.current.configuration.collapsed = true
        world.state.signals = []
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(controller.state.tasks)
        var section = try #require(controller.rows.signalSections.first)
        #expect(!section.collapsed, "saved configuration does not fold a removed signal")
        controller.toggleCollapsed(section.signal)
        section = try #require(controller.rows.signalSections.first)
        #expect(section.collapsed)
        #expect(try encoder.encode(controller.state.tasks) == before)
        controller.toggleCollapsed(section.signal)
        #expect(controller.rows.signalSections.first?.collapsed == false)
        #expect(try encoder.encode(controller.state.tasks) == before)
        controller.toggleCollapsed(section.signal)
        let fresh = SidebarProjection(workspace: controller.workspace, live: controller.live, checkouts: controller.checkouts)
        #expect(fresh.signalSections.first?.collapsed == false, "a new projection starts open")
    }

    @Test(arguments: [false, true])
    func revealingATaskOpensItsSignalAndLeavesItsProjectFolded(removed: Bool) throws {
        var world = SignalWorld(); let id = world.signal(), task = world.workingTask(signal: id)
        if removed { world.state.signals = [] }
        var project = world.project; project.collapsed = true
        world.state.items = [.project(project)]
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        controller.toggleCollapsed(try #require(controller.rows.signalSections.first).signal)
        #expect(controller.rows.signalSections.first?.collapsed == true)
        controller.reveal(.task(task))
        #expect(controller.rows.signalSections.first?.collapsed == false)
        #expect(controller.state.project(id: world.project.id)?.collapsed == true)
        controller.reveal(.task(task))
        #expect(controller.state.project(id: world.project.id)?.collapsed == true, "an already-open signal still owns the task")
    }

    @Test func aSignalsHeadingNamesItsQueriesAndWhyItCannotRun() {
        var world = SignalWorld(); _ = world.signal()
        let help = HeadingValue(SignalSidebar(state: world.state, entries: []).signals[0]).help
        #expect(help.hasPrefix("Starts: labels = operator\nDone: status = Done") && !help.contains("cannot run"))
        world.state.signals[0].start.source = .unknown("future")
        let sidebar = SignalSidebar(state: world.state, entries: [])
        #expect(HeadingValue(sidebar.signals[0]).help.contains("cannot run"))
    }
    /// A schedule's heading reads its cron in words and its next run, its last skipped run by time, and an Operator Done
    /// its guidance, never an empty Done line.
    @Test func aScheduledSignalsHeadingNamesItsScheduleNextRunAndLastSkip() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        var world = SignalWorld()
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 8))!
        let id = world.scheduled(from: monday)
        world.state.signals[0].done.description = "A merge request is open"
        let run = SignalRunRef(signal: id, at: calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9))!)
        world.state.signalSeen.append(SignalSeen(signal: id, item: .run(run), disposition: .skipped, at: monday,
                                                 reason: "The last run is still unfinished."))
        let runs = SignalSidebar.nextRuns(in: world.state, now: monday, calendar: calendar)
        let sidebar = SignalSidebar(state: world.state, entries: [], skipped: SignalSidebar.skipped(in: world.state, calendar: calendar), nextRuns: runs)
        let section = sidebar.signals[0]
        #expect(HeadingValue.triggers(section.signal, nextRun: section.nextRun, calendar: calendar)
                == ["Starts: At 09:00 on Monday (0 9 * * 1)", "Next run: 23 Nov 2026 09:00", "Done: The Operator decides (A merge request is open)"])
        #expect(section.skipped == ["Run of 16 Nov 2026 09:00: The last run is still unfinished."])
        world.state.signals[0].done.description = ""
        #expect(HeadingValue.triggers(world.state.signals[0], nextRun: nil).last == "Done: The Operator decides")
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
        world.state.signals[0].start = SignalTrigger(source: .gitHub, query: "user-review-requested:@me")
        world.state.signals[0].finish = SignalFinish(mergesWhenReady: true)
        controller.workspace.mutate { $0 = world.state }
        #expect(!controller.backpack.operatorCanStartWork, "An unsupported saved signal cannot start work.")
    }
    @Test func theOperatorsOwnPermissionPromptOutranksItsTaskAct() {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let own = OperatorServiceFixtures.session("operator", tag: world.state.operatorSession!.id, state: .needsInput)
        world.state.operatorSession = .open(id: world.state.operatorSession!.id, createdAt: world.now, window: own.windowId)
        let act = OperatorAct(task: id, words: "consulting the Oracle")
        #expect(SignalOperatorRowValue.make(state: world.state, sessions: [own], latestAct: act).status == .needsInput)
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
            state.operatorSession = .open(createdAt: Date())
        }
        controller.helper.setDaemonClient(RecordingDaemon())
        controller.signalController.ports.notifications.onOpen?(.operatorWindow)
        #expect(controller.focus.selection == .operatorChat)
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
        world.state.takeOver(id)
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
        #expect(controller.focus.row(id: OperatorSession.rowID) == .operatorChat)
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
        #expect(controller.rows.operatorHeading.folds && controller.rows.operatorHeading.folded)
        #expect(controller.rows.projectsHeading == SectionFold(folds: true, folded: false, counts: []), "open: no counts")

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

    /// Folded, OPERATOR draws the Operator's own chip; needing you, its click, or a row selected from elsewhere, opens it.
    @Test func aRowNeedingYouInTheFoldedSectionIsCountedAndRevealed() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let asked = world.now
        world.state.operatorSession?.questions = [OperatorSession.Question(id: "q", task: id, text: "Which locale?", openedAt: asked)]
        controller.workspace.mutate { $0 = world.state }
        #expect(controller.rows.operatorHeading.operatorChip == OperatorChip(mark: .status(.needsInput), tasks: 1),
                "the Operator's row says it waits on you, counting its one task")
        #expect(controller.rows.operatorHeading.counts.isEmpty, "no per-status chips under OPERATOR")
        controller.openSection(.operator, at: .operatorState)
        #expect(controller.rows.operatorOpen)
        #expect(controller.focus.selection == .operatorChat, "the row its mark comes from")
        #expect(controller.rows.operatorHeading.operatorChip == nil, "open, the rows say it themselves")

        controller.reveal(.project(world.project.id))
        #expect(!controller.rows.operatorOpen, "a project row opens the projects")
        controller.reveal(.operatorChat)
        #expect(controller.rows.operatorOpen, "the Operator's row opens its section")
    }
    /// Folded, OPERATOR draws one chip: the most urgent state among the Operator and the tasks it runs, whether their
    /// signal is folded or open, counting its tasks; its click opens the section at the row that state comes from,
    /// unfolding its signal.
    @Test func aFoldedOperatorDrawsItsMostUrgentStateAndItsChipOpensThatRow() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        var world = SignalWorld()
        let open = world.signal(name: "Open"), folded = world.signal(name: "Folded")
        let asking = world.workingTask(signal: open), working = world.workingTask(signal: folded), ended = world.workingTask(signal: folded)
        for (index, id) in [asking, working, ended].enumerated() {
            if let at = world.state.tasks.firstIndex(where: { $0.id == id }) { world.state.tasks[at].windowId = "worker-\(index)" }
        }
        world.state.signals[1].collapsed = true
        controller.workspace.mutate { $0 = world.state }
        controller.live.sessions = [SessionInfo.make("a", window: "worker-0", task: asking, state: .needsInput),
                                    SessionInfo.make("w", window: "worker-1", task: working, state: .working),
                                    SessionInfo.make("d", window: "worker-2", task: ended, state: .done)]
        #expect(controller.rows.operatorHeading.operatorChip == OperatorChip(mark: .status(.needsInput), tasks: 3),
                "a worker asking outranks working and waiting; every task counts")
        #expect(controller.rows.operatorHeading.counts.isEmpty && controller.rows.operatorHeading.finished == 0)
        #expect(controller.rows.projectsHeading.counts.isEmpty, "the open section counts nothing")
        #expect(controller.rows.firstRow(in: .operator, chip: .operatorState) == .task(asking))

        controller.live.sessions[0] = SessionInfo.make("a", window: "worker-0", task: asking, state: .idle)
        #expect(controller.rows.operatorHeading.operatorChip == OperatorChip(mark: .status(.working), tasks: 3),
                "with nobody asking, a working worker outranks the waiting ones")
        controller.openSection(.operator, at: .operatorState)
        #expect(controller.rows.operatorOpen)
        #expect(controller.focus.selection == .task(working), "the first working row")
        #expect(controller.state.signal(id: folded)?.collapsed == false, "its signal unfolds")
        #expect(controller.rows.isDrawn(.task(working)))
    }
    /// The Operator chip's other states: paused while it holds work, every task waiting, a question with no task (the
    /// amber mark alone), and nothing at all without work or a question.
    @Test func theOperatorChipIsPausedWaitingOrAQuestionAlone() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .watching }
        controller.workspace.mutate { $0 = world.state }
        #expect(controller.rows.operatorHeading.operatorChip == OperatorChip(mark: .status(.waiting), tasks: 1), "its merge request waits")
        #expect(controller.rows.operatorHeading.operatorChip?.label == "1 task, waiting")

        controller.workspace.mutate { $0.operatorSession?.paused = true }
        #expect(controller.rows.operatorHeading.operatorChip == OperatorChip(mark: .pauseSign, tasks: 1))
        #expect(controller.rows.firstRow(in: .operator, chip: .operatorState) == .operatorChat)

        controller.workspace.mutate { state in
            state.operatorSession?.paused = false
            state.updateSignalTask(id) { $0.phase = .done; $0.thenApplied = true }
        }
        #expect(controller.rows.operatorHeading.operatorChip == nil, "no work, nothing asking: no Operator chip")
        let asked = world.now
        controller.workspace.mutate { $0.operatorSession?.questions = [.init(id: "q", task: nil, text: "Pause on Fridays?", openedAt: asked)] }
        #expect(controller.rows.operatorHeading.operatorChip == OperatorChip(mark: .status(.needsInput), tasks: 0))
        #expect(controller.rows.operatorHeading.operatorChip?.label == "needs you")
    }

    /// A finished task (done, its closeout through) is counted in the green chip, apart from the Operator's, even once
    /// the Operator row has gone; the chip opens at it. A folded signal counts it there too, beside its other statuses.
    @Test func finishedTasksHaveTheirOwnChipOnBothFoldedHeadings() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        var world = SignalWorld(); let signal = world.signal()
        let waiting = world.workingTask(signal: signal), finished = world.workingTask(signal: signal)
        world.state.updateSignalTask(waiting) { $0.phase = .watching }
        world.state.updateSignalTask(finished) { $0.phase = .done; $0.thenApplied = true }
        world.state.signals[0].collapsed = true
        controller.workspace.mutate { $0 = world.state }
        #expect(controller.rows.operatorHeading.operatorChip == OperatorChip(mark: .status(.waiting), tasks: 1), "the finished one is not workload")
        #expect(controller.rows.operatorHeading.finished == 1)
        let heading = HeadingValue(try #require(controller.rows.signalSections.first))
        #expect(heading.counts == [StatusCount(status: .waiting, count: 1)] && heading.finished == 1, "the folded signal")

        controller.workspace.mutate { $0.updateSignalTask(waiting) { $0.phase = .done; $0.thenApplied = true } }
        #expect(!controller.rows.signalOperator.shown, "no work left: the Operator's row has gone")
        #expect(controller.rows.operatorHeading.operatorChip == nil && controller.rows.operatorHeading.finished == 2)
        controller.openSection(.operator, at: .finished)
        #expect(controller.rows.operatorOpen)
        #expect(controller.focus.selection == .task(waiting) || controller.focus.selection == .task(finished), "its first finished row")
        #expect(controller.rows.isDrawn(try #require(controller.focus.selection)))
    }

    /// A finished task kept by its Then can be continued: while its worker asks or works it is counted by what its row
    /// draws, never hidden in the green chip, and a prompt in it turns the Operator chip amber (found in review, 20 Nov 2026).
    @Test func aFinishedTaskYouContinueIsCountedByWhatItsRowDraws() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .done; $0.thenApplied = true }
        if let at = world.state.tasks.firstIndex(where: { $0.id == id }) { world.state.tasks[at].windowId = "kept" }
        world.state.signals[0].collapsed = true
        controller.workspace.mutate { $0 = world.state }
        controller.live.sessions = [SessionInfo.make("k", window: "kept", task: id, state: .needsInput)]
        #expect(controller.rows.operatorHeading.operatorChip == OperatorChip(mark: .status(.needsInput), tasks: 0), "its prompt needs you")
        #expect(controller.rows.operatorHeading.finished == 0, "not hidden in the green chip")
        #expect(controller.rows.firstRow(in: .operator, chip: .operatorState) == .task(id))
        var heading = HeadingValue(try #require(controller.rows.signalSections.first))
        #expect(heading.counts == [StatusCount(status: .needsInput, count: 1)] && heading.finished == 0, "the folded signal")

        controller.live.sessions = [SessionInfo.make("k", window: "kept", task: id, state: .working)]
        heading = HeadingValue(try #require(controller.rows.signalSections.first))
        #expect(controller.rows.operatorHeading.operatorChip == OperatorChip(mark: .status(.working), tasks: 0), "its worker runs again")
        #expect(controller.rows.operatorHeading.finished == 0 && heading.counts == [StatusCount(status: .working, count: 1)])
        #expect(controller.rows.firstRow(in: .operator, chip: .operatorState) == .task(id))

        controller.live.sessions = [SessionInfo.make("k", window: "kept", task: id, state: .idle)]
        heading = HeadingValue(try #require(controller.rows.signalSections.first))
        #expect(controller.rows.operatorHeading.operatorChip == nil && controller.rows.operatorHeading.finished == 1, "settled again")
        #expect(heading.counts.isEmpty && heading.finished == 1)
    }

    /// With PROJECTS folded, a terminal first in its status opens the projects and unfolds its collapsed project.
    @Test func aChipOnTheFoldedProjectsUnfoldsATerminalsProject() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.focus.cancel(); controller.shutdown() }
        var world = SignalWorld(); _ = world.workingTask(signal: world.signal())
        var project = world.project; project.collapsed = true
        world.state.items = [.project(project)]
        let shell = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "shell-window", createdAt: Date())
        world.state.terminals = [shell]
        world.state.operatorOpen = true
        controller.workspace.mutate { $0 = world.state }
        controller.live.sessions = [SessionInfo.make("shell", window: "shell-window", state: .needsInput)]
        #expect(controller.rows.projectsHeading.counts == [StatusCount(status: .needsInput, count: 1)])

        controller.openSection(.projects, at: .status(.needsInput))
        #expect(!controller.rows.operatorOpen)
        #expect(controller.state.project(id: project.id)?.collapsed == false, "the terminal's project unfolds")
        #expect(controller.focus.selection == .terminal(shell.id))
        #expect(controller.rows.isDrawn(.terminal(shell.id)))
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
        #expect(controller.rows.operatorPath == [.operatorChat, .signal(signal), .task(task)])

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
        var world = SignalWorld(); let signal = world.signal(done: SignalTrigger(source: .gitLab, description: "When a reviewer is asked", query: "reviewer:any")); let id = world.workingTask(signal: signal)
        func row(acts: [UUID: String] = [:]) throws -> TaskRow {
            let entries = SidebarModel.entries(state: world.state, sessions: [], branchByCwd: [:], projectBranch: [:])
            return try #require(SignalSidebar(state: world.state, entries: entries, acts: acts).signals.first?.tasks.first)
        }
        #expect(try row(acts: [id: "answering its worker"]).operatorLine == OperatorLine("Operator answering its worker", look: .acting))
        let questionAt = world.now
        world.state.operatorSession?.questions = [OperatorSession.Question(id: "locale", task: id, text: "Which locale?", openedAt: questionAt)]
        #expect(try row().operatorLine?.text == "waiting on you")
        #expect(try row().status == .needsInput)
        world.state.operatorSession?.questions = []
        world.state.updateSignalTask(id) { $0.phase = .watching }
        #expect(try row().operatorLine?.text == "When a reviewer is asked")
        #expect(try row().status == .waiting)
        world.state.signals[0].enabled = false
        #expect(try row().operatorLine == .paused)
        #expect(try row().mark == .pauseSign)
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
        let session = SessionInfo.make("shell", window: "window", state: .needsInput)
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
    /// The Operator's row needs you only while it needs input: a question for you; paused, it draws the pause sign.
    @Test func theOperatorRowWithAQuestionNeedsYou() {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let watching = SignalOperatorRowValue.make(state: world.state, sessions: [])
        #expect(!watching.needsYou && watching.mark == .status(.idle))
        let askedAt = world.now
        world.state.operatorSession?.questions = [.init(id: "q", task: id, text: "Which locale?", openedAt: askedAt)]
        let asking = SignalOperatorRowValue.make(state: world.state, sessions: [])
        #expect(asking.needsYou && asking.mark == .status(.needsInput))
        world.state.operatorSession?.questions = []
        world.state.operatorSession?.paused = true
        let paused = SignalOperatorRowValue.make(state: world.state, sessions: [])
        #expect(!paused.needsYou && paused.mark == .pauseSign)
    }
    @Test func theOperatorNamesItsActAndCountsTheSignalsStillHoldingTasks() throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        world.state.tasks[0].jira = JiraRef(key: "PAY-1", summary: "Retries", url: "https://jira.example/browse/PAY-1")
        let acting = SignalOperatorRowValue.make(state: world.state, sessions: [], latestAct: OperatorAct(task: id, words: "answering its worker"))
        #expect(acting.line.text.contains("answering") && acting.line.text.contains("PAY-1"))
        world.state.signals = []
        let resting = SignalOperatorRowValue.make(state: world.state, sessions: [])
        #expect(resting.title == "1 task · 1 signal" && resting.line.text == "watching")
    }
    /// The row's title is its workload, never a second "Operator" under the heading that already says it.
    @Test func theOperatorTitleCountsItsTasksAndSignals() throws {
        var world = SignalWorld()
        #expect(SignalOperatorRowValue.make(state: world.state, sessions: []).title == "No tasks")
        #expect(SignalOperatorRowValue.empty.title == "No tasks")
        let first = world.signal(name: "Plan tickets"), second = world.signal(name: "Review requests")
        world.workingTask(signal: first)
        #expect(SignalOperatorRowValue.make(state: world.state, sessions: []).title == "1 task · 1 signal")
        world.workingTask(signal: first); world.workingTask(signal: second)
        let value = SignalOperatorRowValue.make(state: world.state, sessions: [])
        #expect(value.title == "3 tasks · 2 signals" && value.line.text == "watching")
        world.state.operatorSession?.lifecycle = .closing(then: .renew)
        #expect(SignalOperatorRowValue.make(state: world.state, sessions: []).line.text == "starting fresh")
    }

}
