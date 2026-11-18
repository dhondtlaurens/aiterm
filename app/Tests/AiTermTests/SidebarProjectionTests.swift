import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The sidebar's rows are derived once, for the list, the Dock badge and Focus and List View, and
/// only when a row could have changed: not for a session event that moved a fill, a model or a
/// title, nor for a sidebar move or a remembered choice, which the workspace saves but no row draws.
@MainActor
@Suite(.blocking) struct SidebarProjectionTests {
    private let project = Project.make(name: "repo", path: "/repo", provider: .gitlab, addedAt: Date())
    private var task: TaskItem {
        TaskItem.make(id: Self.taskId, project: project.id, title: "a", branch: "feat/a", worktreePath: "/repo/a",
            model: "opus", appendTicket: true, createdAt: Date(), windowId: "w")
    }
    private nonisolated static let taskId = UUID()

    private func tab(_ state: SessionState = .working) -> SessionInfo {
        SessionInfo.make(window: "w", task: Self.taskId, state: state, cwd: "/repo/a")
    }

    private func controller(scan: @escaping CheckoutMonitor.Scanner = { _, _, _, _, _, _ in
        WorkspaceScan(branchByCwd: [:], projectBranch: [:], missingCheckouts: [], removedTasks: [], remotes: [:])
    }) throws -> AppController {
        let controller = AppController(preferences: .scratch(), scan: scan)
        try controller.workspace.load()
        controller.workspace.mutate { [project, task] state in
            state.append(project: project)
            state.tasks = [task]
        }
        controller.live.handle(.sessionOpened(tab()))
        return controller
    }

    /// The rows waiting on you, `skipping` being on their way out: their teardown under way.
    private func attention(_ state: AppState, sessions: [SessionInfo], skipping: Set<UUID> = []) throws -> [RowID] {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = state }
        for session in sessions { controller.live.handle(.sessionOpened(session)) }
        for id in skipping { controller.teardown.seedSnapshotState(.removing, of: id) }
        return controller.rows.projectsNeedingAttention
    }

    private func attentionState(tasks: [TaskItem], terminals: [TerminalItem] = []) -> AppState {
        var state = AppState.empty
        state.append(project: project); state.tasks = tasks; state.terminals = terminals
        return state
    }

    @Test func nothingWaitingGivesNoAttentionRows() throws {
        #expect(try attention(attentionState(tasks: [task]), sessions: [tab(.working),
            SessionInfo.make("idle", window: "w", task: Self.taskId, state: .idle)]).isEmpty)
        #expect(try attention(attentionState(tasks: [task]), sessions: [
            SessionInfo.make("unknown", window: "elsewhere", task: UUID(), state: .needsInput),
            SessionInfo.make("stray", window: "stray-window", state: .done)]).isEmpty)
    }

    @Test func aTaskCountsOnceHoweverManyTabsWaitAndDoneCountsToo() throws {
        var second = task; second.id = UUID(); second.windowId = "second-window"
        var firstTab = tab(.needsInput); firstTab.taskId = Self.taskId.uuidString.lowercased()
        let sessions = [firstTab, SessionInfo.make("another", window: "w", task: Self.taskId, state: .needsInput),
                        SessionInfo.make("second", window: "second-window", task: second.id, state: .done)]
        #expect(try attention(attentionState(tasks: [task, second]), sessions: sessions) == [.task(Self.taskId), .task(second.id)])
    }

    @Test func attentionFollowsProjectsInOrderWithTerminalsBeforeTasksAndSkipsLeavingTasks() throws {
        let shell = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "terminal-window", createdAt: Date())
        var later = task; later.id = UUID(); later.windowId = "later-window"
        let busyProject = Project.make(name: "Busy", path: "/busy")
        let busy = TaskItem.make(project: busyProject.id, windowId: "busy-window")
        var state = attentionState(tasks: [busy, task, later], terminals: [shell])
        state.items.insert(.project(busyProject), at: 0)
        let sessions = [tab(.done), SessionInfo.make("later", window: "later-window", task: later.id, state: .needsInput),
                        SessionInfo.make("shell", window: "terminal-window", state: .needsInput),
                        SessionInfo.make("busy", window: "busy-window", task: busy.id, state: .working)]
        #expect(try attention(state, sessions: sessions) == [.terminal(shell.id), .task(Self.taskId), .task(later.id)])
        #expect(try attention(state, sessions: sessions, skipping: [Self.taskId, shell.id]) == [.terminal(shell.id), .task(later.id)])
        state.terminals = []
        #expect(try attention(state, sessions: sessions).first == .task(Self.taskId))
        #expect(try attention(state, sessions: sessions, skipping: [Self.taskId]).first == .task(later.id))
    }

    @Test func operatorAttentionRowsComeBeforeProjectRows() throws {
        var world = SignalWorld(); let signal = world.signal(), driven = world.workingTask(signal: signal)
        let askedAt = world.now
        world.state.operatorSession?.questions = [.init(id: "q", task: driven, text: "Which locale?", openedAt: askedAt)]
        world.state.append(project: project); world.state.tasks.append(task)
        let sessions = [tab(.done), SessionInfo.make("worker", window: "worker-window", task: driven, state: .needsInput)]
        #expect(try attention(world.state, sessions: sessions) == [.operatorChat, .task(driven), .task(Self.taskId)])
        #expect(try attention(world.state, sessions: sessions, skipping: [driven]) == [.operatorChat, .task(Self.taskId)])
    }

    /// A task on its way out waits on no one: the Dock badge, Focus View and the folded heading's count all pass over
    /// it, and count it again once its teardown stopped.
    @Test func aLeavingTaskIsNotWaitingOnYouNorCountedUnderAFoldedHeading() throws {
        var world = SignalWorld(); let signal = world.signal(), driven = world.workingTask(signal: signal)
        world.state.append(project: project); world.state.tasks.append(task)
        world.state.operatorOpen = true
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        controller.workspace.mutate { $0 = world.state }
        controller.live.handle(.sessionOpened(tab(.done)))
        controller.live.handle(.sessionOpened(SessionInfo.make("worker", window: "worker-window", task: driven, state: .needsInput)))
        try #require(controller.rows.projectsHeading == SectionFold(folds: true, folded: true, attention: 1))
        try #require(controller.rows.projectsNeedingAttention.contains(.task(Self.taskId)))

        controller.teardown.seedSnapshotState(.removing, of: Self.taskId)
        #expect(!controller.rows.projectsNeedingAttention.contains(.task(Self.taskId)))
        #expect(controller.rows.projectsHeading.attention == 0)

        controller.teardown.seedSnapshotState(.stopped(note: "Not removed"), of: Self.taskId)
        #expect(controller.rows.projectsNeedingAttention.contains(.task(Self.taskId)))
        #expect(controller.rows.projectsHeading.attention == 1)
    }

    /// What the list draws from: a write that changes none of it redraws no row.
    private func readsTheList(_ rows: SidebarProjection) -> () -> Void {
        { _ = rows.entries; _ = rows.signalSections; _ = rows.terminals }
    }

    /// A host read that found only what a merge lacks changes the waiting task's line, and nothing else.
    @Test func mergeBlockersAloneRedrawTheWaitingLine() throws {
        let controller = try controller(); defer { controller.shutdown() }
        let signal = Signal(name: "Requests", createdAt: Date(), start: SignalTrigger(source: .jira, query: "labels = operator"), done: SignalTrigger(source: .jira, query: "status = Done"), work: SignalWork(prompt: "Work"),
            agents: [.init(agent: .claude, model: "opus", reasoning: nil)], finish: SignalFinish(then: .keep, mergesWhenReady: true))
        var record = SignalTask.make(signal: signal, item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        record.phase = .watching
        controller.workspace.mutate { $0.signals = [signal]; $0.tasks[0].signalTask = record }
        let rows = controller.rows
        func line() -> String? { rows.signalSections.first?.tasks.first?.operatorLine?.text }
        #expect(line() == "status = Done")
        controller.workspace.mutate { $0.updateSignalTask(Self.taskId) { $0.waitingOn = SignalWaitFacts(mergeBlockers: [.approval]) } }
        #expect(line() == "waiting to merge · approval")
        controller.workspace.mutate { $0.updateSignalTask(Self.taskId) { $0.waitingOn = SignalWaitFacts(mergeBlockers: [.checks]) } }
        #expect(line() == "waiting to merge · checks")
    }
    /// Each fact a driven row draws, changed alone, derives the rows once and changes that row: its blocked reason,
    /// what it waits on, a question for it, and its window closing with its worker's conversation saved.
    @Test func eachDrawnDrivenFactDerivesOnceAndChangesItsRow() throws {
        let controller = try controller(); defer { controller.shutdown() }
        let signal = Signal(name: "Requests", createdAt: Date(), start: SignalTrigger(source: .jira, query: "labels = operator"), done: SignalTrigger(source: .jira, query: "status = Done"), work: SignalWork(prompt: "Work"),
            agents: [.init(agent: .claude, model: "opus", reasoning: nil)], finish: SignalFinish(then: .keep, mergesWhenReady: true))
        var record = SignalTask.make(signal: signal, item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        record.phase = .blocked; record.blockedReason = "Pick a project."
        controller.workspace.mutate { $0.signals = [signal]; $0.tasks[0].signalTask = record; $0.operatorSession = OperatorSession(createdAt: Date()) }
        controller.live.handle(.sessionChanged(tab(.idle)))
        let rows = controller.rows
        func row() throws -> TaskRow { try #require(rows.signalSections.first?.tasks.first) }
        func changesOnce(_ change: () -> Void) throws -> (before: TaskRow, after: TaskRow) {
            let before = try row(), start = rows.derivations
            change()
            #expect(rows.derivations == start + 1)
            return (before, try row())
        }

        let blocked = try changesOnce { controller.workspace.mutate { $0.updateSignalTask(Self.taskId) { $0.blockedReason = "Pick an agent." } } }
        #expect(blocked.before.operatorLine?.tooltip == "Pick a project." && blocked.after.operatorLine?.tooltip == "Pick an agent.")

        controller.workspace.mutate { $0.updateSignalTask(Self.taskId) { $0.phase = .watching } }
        let waiting = try changesOnce {
            controller.workspace.mutate { $0.updateSignalTask(Self.taskId) { $0.waitingOn = SignalWaitFacts(mergeBlockers: [.approval]) } }
        }
        #expect(waiting.before.operatorLine?.text == "status = Done" && waiting.after.operatorLine?.text == "waiting to merge · approval")

        let asked = try changesOnce {
            controller.workspace.mutate { $0.operatorSession?.questions = [.init(id: "q", task: Self.taskId, text: "Which locale?", openedAt: Date())] }
        }
        #expect(!asked.before.needsYou && asked.after.needsYou && asked.after.operatorLine?.tooltip == "Which locale?")
        let reworded = try changesOnce {
            controller.workspace.mutate { $0.operatorSession?.questions = [.init(id: "q", task: Self.taskId, text: "Which currency?", openedAt: Date())] }
        }
        #expect(reworded.after.operatorLine?.tooltip == "Which currency?", "another question in the same count")
        controller.workspace.mutate { $0.operatorSession?.questions = [] }

        controller.workspace.mutate { $0.updateSignalTask(Self.taskId) { $0.phase = .working } }
        let start = rows.derivations
        controller.workspace.mutate { $0.tasks[0].conversations = [TaskConversation(agent: .claude, id: "c1")] }
        #expect(rows.derivations == start, "a conversation saved while its window is open draws nothing")
        let closed = try changesOnce { controller.workspace.mutate { $0.tasks[0].windowId = nil } }
        #expect(closed.before.operatorLine != .windowClosed && closed.after.operatorLine == .windowClosed)
    }
    @Test func journalAndReplyIntentsDoNotDeriveOrInvalidateDrawnRows() throws {
        let controller = try controller(); defer { controller.shutdown() }
        let signal = Signal(name: "Tickets", createdAt: Date(), start: SignalTrigger(source: .jira, query: "labels = operator"), done: SignalTrigger(source: .jira, query: "status = Done"), work: SignalWork(prompt: "Work"),
            agents: [.init(agent: .claude, model: "opus", reasoning: nil)], finish: SignalFinish(then: .keep))
        var record = SignalTask.make(signal: signal, item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date()); record.phase = .working
        controller.workspace.mutate { $0.signals = [signal]; $0.updateSignalTask(Self.taskId) { $0 = record } }
        // The ordinary row initially has no SignalTask to update.
        controller.workspace.mutate { $0.tasks[0].signalTask = record }
        let rows = controller.rows, before = rows.derivations, at = Date()
        #expect(!invalidates(readsTheList(rows)) {
            controller.workspace.mutate { $0.updateSignalTask(Self.taskId) {
                $0.journal.append(.init(at: at, stage: 1, text: .ours("A saved decision.")))
                $0.pendingReplies = ["main": .init(at: at, fingerprint: "record")]
            } }
        })
        #expect(rows.derivations == before)
    }
    @Test func aDisplayOnlyJobInvalidatesItsRowWithoutChangingItsStatus() throws {
        let controller = try controller()
        defer { controller.shutdown() }
        let rows = controller.rows
        let before = rows.sections.flatMap(\.tasks).first { $0.id == Self.taskId }?.status
        var event = tab()
        event.work = [WorkItem(kind: .subagent, text: "Review", holdsTurn: false)]
        #expect(invalidates(readsTheList(rows)) { controller.live.handle(.sessionChanged(event)) })
        let row = rows.sections.flatMap(\.tasks).first { $0.id == Self.taskId }
        #expect(row?.status == before)
        #expect(row?.background == [BackgroundJob(kind: .subagent, text: "Review")])
    }

    /// Context fills, sidebar moves, remembered choices and menu validation do not derive the rows again.
    @Test func onlyAChangeToARowDerivesTheRowsAgain() throws {
        let controller = try controller()
        let rows = controller.rows
        let start = rows.derivations

        var event = tab()
        #expect(!invalidates(readsTheList(rows)) {
            for n in 1...10 {
                event.contextPercent = n
                controller.live.handle(.sessionChanged(event))
            }
        }, "a context fill draws no row")
        #expect(rows.derivations == start)

        #expect(!invalidates(readsTheList(rows)) {
            for n in 1...10 { controller.workspace.mutate { $0.sidebarFrame = CGRect(x: n, y: 0, width: 300, height: 800) } }
        }, "a sidebar move draws no row")
        #expect(rows.derivations == start)

        #expect(!invalidates(readsTheList(rows)) {
            for n in 1...10 {
                controller.workspace.mutate { $0.lastAgentByProject[project.id] = n.isMultiple(of: 2) ? .claude : .codex }
                controller.workspace.mutate { $0.lastModelByAgent[.claude] = "model-\(n)" }
            }
        }, "a remembered choice draws no row")
        #expect(rows.derivations == start)

        #expect(!invalidates(readsTheList(rows)) {
            controller.workspace.mutate { $0.tasks[0].conversations = [TaskConversation(agent: .claude, id: "c1")] }
        }, "a remembered conversation draws no row")
        #expect(rows.derivations == start)

        for _ in 1...10 { _ = controller.canShowFocusView; _ = controller.canShowListView }
        #expect(rows.derivations == start, "the menus read the rows the list draws")

        event.state = .needsInput
        #expect(invalidates(readsTheList(rows)) { controller.live.handle(.sessionChanged(event)) })
        #expect(rows.derivations == start + 1, "a status change derives the rows once")
        #expect(rows.sections.first?.tasks.first?.status == .needsInput)
    }

    /// The rows are the list's whole model: what `SidebarModel.entries` makes of the workspace,
    /// the tabs as the rows read them and the checkouts on disk, kept as each of them changes.
    @Test func theRowsFollowTheWorkspaceTheTabsAndTheCheckouts() async throws {
        let controller = try controller(scan: { _, _, _, _, _, _ in
            WorkspaceScan(branchByCwd: ["/repo/a": "feat/moved"], projectBranch: [:], missingCheckouts: [],
                          removedTasks: [], remotes: [:], diffByTask: [Self.taskId: DiffStat(added: 3, removed: 1)])
        })
        func expected() -> [SidebarEntry] {
            SidebarModel.entries(state: controller.state, sessions: controller.live.rowSessions,
                                 branchByCwd: controller.checkouts.branchByCwd, projectBranch: controller.checkouts.projectBranch,
                                 diffByTask: controller.checkouts.diffByTask)
        }
        #expect(controller.rows.entries == expected())
        #expect(controller.rows.sections.first?.tasks.first { $0.id == Self.taskId }?.title == "a")

        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "t", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal]; $0.append(divider: SidebarDivider(id: UUID(), name: "")) }
        #expect(controller.rows.entries == expected())
        #expect(controller.rows.terminals[terminal.id] == terminal)

        await controller.checkouts.refresh().value
        let row = try #require(controller.rows.sections.first?.tasks.first)
        #expect(row.branch.name == "feat/moved" && row.branch.drifted, "a pass that moved the branch redraws the row")
        #expect(row.diff?.stat == DiffStat(added: 3, removed: 1))
        #expect(controller.rows.entries == expected())
    }

    /// The Dock badge counts the rows the list draws: it moves with a status, and not with a fill
    /// or a sidebar move.
    @Test func theBadgeCountsTheDerivedRows() throws {
        var written: [String?] = []
        let controller = AppController(preferences: .scratch(), setBadge: { written.append($0) })
        try controller.workspace.load()
        controller.workspace.mutate { [project, task] state in
            state.append(project: project)
            state.tasks = [task]
        }
        controller.live.handle(.sessionOpened(tab(.done)))
        #expect(written == ["1"])
        var event = tab(.done)
        for n in 1...5 { event.contextPercent = n; controller.live.handle(.sessionChanged(event)) }
        controller.workspace.mutate { $0.sidebarFrame = CGRect(x: 0, y: 0, width: 300, height: 800) }
        #expect(written == ["1"])
        event.state = .idle
        controller.live.handle(.sessionChanged(event))
        #expect(written == ["1", nil])
    }

    /// A removal that starts passes its task over, as Focus View does, and the task's going leaves
    /// the badge clear: its row is gone from the sections before its removal's entry goes, so the
    /// badge never counts it again in between.
    @Test func aRemovedTaskLeavesTheBadgeOnce() async throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: realpath(raw, nil).map { defer { free($0) }; return String(cString: $0) } ?? raw)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRunner.hermetic(), repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo.path)
        let checkout = repo.appendingPathComponent(".worktrees/work").path
        try git.run(["worktree", "add", "-q", "-b", "feat/work", checkout], in: repo.path)
        let project = Project.make(name: "Repo", path: repo.path, addedAt: Date())
        let task = TaskItem.make(id: Self.taskId, project: project.id, worktreePath: checkout, model: "opus", createdAt: Date(),
            windowId: "w")

        var written: [String?] = []
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       prompter: ScriptedPrompter(answering: "Remove"), setBadge: { written.append($0) }, git: git)
        // The task has the window its tab is in, as the row would have taken it, and a helper to close it with.
        controller.helper.setDaemonClient(RecordingDaemon())
        try controller.workspace.load()
        controller.workspace.mutate { $0.append(project: project); $0.tasks = [task] }
        controller.live.handle(.sessionOpened(tab(.done)))
        #expect(written == ["1"])

        try await controller.teardown.remove(task, consent: .ask)
        #expect(controller.state.tasks.isEmpty, "the task is removed")
        #expect(written == ["1", nil])
    }

    /// The footer's context row reads the rows' tabs and the fills: a session event that moved a fill
    /// redraws it; a sidebar move does not.
    @Test func theContextRowRedrawsForAFillAlone() throws {
        let controller = try controller()
        controller.focus.browse(.task(Self.taskId))
        let footer = SelectedRowSidebarFooter(controller: controller, vendors: [])
        var event = tab()
        event.contextPercent = 40
        #expect(invalidates({ _ = footer.body }) { controller.live.handle(.sessionChanged(event)) })
        #expect(controller.rows.usageRow(for: .task(Self.taskId))?.context?.percent == 40)
        #expect(!invalidates({ _ = footer.body }) {
            controller.workspace.mutate { $0.sidebarFrame = CGRect(x: 0, y: 0, width: 300, height: 800) }
        })
    }

}
