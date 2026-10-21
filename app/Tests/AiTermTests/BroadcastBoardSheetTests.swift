import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The broadcast's board as the sidebar presents it (spec §4, §4.2, §9, §13): a card's click, the footer at
/// each moment, the sheet slot it opens in, and what its buttons ask of the app.
@MainActor
struct BroadcastBoardSheetTests {
    private func board(_ run: OperatorRun, _ tasks: [TaskItem] = []) -> BroadcastBoard {
        var state = AppState()
        state.runs = [run]
        state.tasks = tasks
        return BroadcastBoard.make(run: run, state: state, acting: .none, requests: [])
    }

    /// The sheet closes first, then what the card opens comes forward; a Todo card is not a button.
    @Test func clickingACardDismissesFirst() {
        var moments: [String] = []
        let task = UUID()
        let actions = BoardActions(open: { opens in
            switch opens {
            case .taskWindow(let id): moments.append(id == task ? "open the task's window" : "open another window")
            case .tab(_, let session): moments.append("bring tab \(session)")
            case .operatorWindow: moments.append("open the Operator's window")
            case .sidebarBanner(let issue): moments.append("show the banner's \(issue)")
            case .nothing: moments.append("open nothing")
            }
        })
        for opens: BroadcastBoard.Opens in [.taskWindow(task), .tab(task: task, sessionId: "s2"), .operatorWindow,
                                            .sidebarBanner(issue: "issue-7"), .nothing] {
            BroadcastBoardSheet.choose(opens, dismiss: { moments.append("dismiss") }, actions: actions)
        }
        #expect(moments == ["dismiss", "open the task's window", "dismiss", "bring tab s2", "dismiss", "open the Operator's window",
                            "dismiss", "show the banner's issue-7"], "a Todo card does nothing, not even close the sheet")
        #expect(!BroadcastBoardSheet.isButton(.nothing) && BroadcastBoardSheet.isButton(.operatorWindow))
    }

    /// A card's tab line brings that tab forward: the task's row selected and its window raised as a row's click
    /// raises it, then that tab selected in the window.
    @Test func aTabLineBringsItsTab() async throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let daemon = RecordingDaemon()
        controller.helper.setDaemonClient(daemon)
        let run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-web")
        let task = OperatorUIFixtures.task("Footer", project: project.id, windowId: "w1",
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.runs = [run]; state.tasks = [task] }
        controller.open(.tab(task: task.id, sessionId: "s2"), run: run.id)
        #expect(controller.focus.selection == .task(task.id))
        #expect(await eventually(describing: "the tab brought forward") { !daemon.requests("session.activate").isEmpty })
        #expect(daemon.requests("session.activate").map { $0.params["sessionId"] as? String } == ["s2"])
        #expect(daemon.requests.map(\.method).filter { $0.hasSuffix(".activate") } == ["window.activate", "session.activate"],
                "its window raised first, then the tab selected in it")
    }

    @Test func theFooterOffersWhatTheMomentAllows() {
        func shown(_ footer: BoardFooter) -> ([String], String?, String?) {
            (footer.leading.map(\.title), footer.primary?.title, footer.notice?.title)
        }
        let running = BoardFooter(board(OperatorUIFixtures.run()), reopenFailed: false)
        #expect(shown(running) == (["Pause Broadcast", "End Broadcast…"], nil, nil))
        #expect(running.secondary == "Close")
        #expect(shown(BoardFooter(board(OperatorUIFixtures.run(state: .paused)), reopenFailed: false))
                == (["Resume Broadcast", "End Broadcast…"], nil, nil))
        #expect(shown(BoardFooter(board(OperatorUIFixtures.run(state: .operatorOffline)), reopenFailed: false))
                == (["Resume Broadcast", "End Broadcast…"], nil, nil))

        let complete = OperatorUIFixtures.run(state: .complete)
        let done = OperatorUIFixtures.task("Footer", project: UUID(),
                                           operated: OperatorUIFixtures.operated(run: complete.id, key: "a", state: .accepted, sha: "4f2a91c"))
        let finished = BoardFooter(board(complete, [done]), reopenFailed: false)
        #expect(shown(finished) == ([], "End Broadcast", nil), "a complete broadcast's End asks nothing")
        #expect(finished.secondary == "Close")

        let failed = BoardFooter(board(OperatorUIFixtures.run(state: .operatorOffline)), reopenFailed: true)
        #expect(shown(failed) == ([], "Start Fresh", "Couldn’t reopen the Operator’s window"))
        #expect(failed.notice?.description == "Its conversation couldn’t be resumed. A fresh one starts from the board and what it decided so far.")
        #expect(failed.secondary == "Close")

        // A complete broadcast outranks a failed reopening: ⌘↩ stays End Broadcast, Start Fresh a plain button by the Notice.
        let both = BoardFooter(board(complete, [done]), reopenFailed: true)
        #expect(shown(both) == (["Start Fresh"], "End Broadcast", "Couldn’t reopen the Operator’s window"))
        #expect(both.secondary == "Close")
    }

    /// An ended broadcast, read from the Shelf, is read-only: Close alone, whether or not it once reached complete,
    /// and a failed reopening is no part of it.
    @Test func aShelvedBoardsFooterIsCloseAlone() {
        for state in [OperatorRunState.stopped, .complete] {
            var run = OperatorUIFixtures.run(state: state)
            run.endedAt = OperatorUIFixtures.epoch
            let shelved = BroadcastBoard.shelved(run: run, state: { var s = AppState(); s.runs = [run]; return s }())
            for reopenFailed in [false, true] {
                let footer = BoardFooter(shelved, reopenFailed: reopenFailed)
                #expect(footer.leading == [] && footer.primary == nil && footer.notice == nil)
                #expect(footer.secondary == "Close")
            }
        }
    }

    @Test func eachButtonDoesItsOneThing() {
        var moments: [String] = []
        let actions = BoardActions(pause: { moments.append("pause") }, resume: { moments.append("resume") },
                                   end: { moments.append($0 ? "end…" : "end") }, startFresh: { moments.append("fresh") })
        for button: BoardFooter.Button in [.pause, .resume, .endConfirm, .end, .startFresh] { button.perform(actions) }
        #expect(moments == ["pause", "resume", "end…", "end", "fresh"])
    }

    /// A Summary left selected when a new plan makes the broadcast active again shows the Board, as the tab bar does;
    /// the other tabs stay where they are.
    @Test func aSummaryNoLongerReachedShowsTheBoard() {
        let active = board(OperatorUIFixtures.run())
        #expect(active.summary == .notYet)
        #expect(BroadcastBoardSheet.shownTab(.summary, on: active) == .board)
        #expect(BroadcastBoardSheet.shownTab(.activity, on: active) == .activity)
        #expect(BroadcastBoardSheet.shownTab(.board, on: active) == .board)
        var complete = OperatorUIFixtures.run(state: .complete)
        complete.completedAt = OperatorUIFixtures.epoch
        complete.summary = "Done."; complete.summaryAt = OperatorUIFixtures.epoch
        #expect(BroadcastBoardSheet.shownTab(.summary, on: board(complete)) == .summary)
    }

    /// Settings' width, whichever tab it is on.
    @Test func theSheetIsSettingsWidth() {
        let sheet = BroadcastBoardSheet(board: board(OperatorUIFixtures.run()), reopenFailed: false, actions: BoardActions(), activity: nil)
        let host = NSHostingView(rootView: sheet)
        #expect(host.fittingSize.width == Sheet.width)
    }

    /// An Activity row's time, `HH:mm` in the calendar it is read in.
    @Test func anActivityRowsTimeIsHoursAndMinutes() {
        let at = Snapshots.clock.now.addingTimeInterval(2 * 3600 + 35 * 60)
        #expect(BroadcastActivityView.timeText(at: at, calendar: Snapshots.clock.calendar) == "14:35")
        #expect(BroadcastActivityView.timeText(at: Snapshots.clock.now.addingTimeInterval(-11 * 3600 - 55 * 60),
                                               calendar: Snapshots.clock.calendar) == "00:05")
    }

    /// Only what did not go through says so first: a refusal and a failure in amber, a challenge muted.
    @Test func onlyACallThatDidNotGoThroughIsLabelled() {
        #expect(BroadcastActivityView.label(for: .refused) == "Refused")
        #expect(BroadcastActivityView.label(for: .failed) == "Failed")
        #expect(BroadcastActivityView.label(for: .challenged) == "Challenged")
        #expect(BroadcastActivityView.label(for: .ok) == nil)
        #expect(BroadcastActivityView.label(for: .repeated) == nil)
    }

    /// Activity's day headings: Today, then the day.
    @Test func activityIsHeadedByItsDays() {
        let calendar = Snapshots.clock.calendar, now = Snapshots.clock.now
        func entry(_ offset: TimeInterval) -> ActivityEntry {
            ActivityEntry(at: now.addingTimeInterval(offset), tool: "run_status", task: nil, taskLabel: nil, arguments: .null,
                          outcome: .ok, result: "", line: "Checked the broadcast’s status", reason: nil)
        }
        let entries = [entry(-60), entry(-3600), entry(-86_400), entry(-86_400 - 60)]
        let days = BroadcastActivityView.days(entries, calendar: calendar)
        #expect(days.map(\.entries.count) == [2, 2])
        #expect(days.map { BroadcastActivityView.dayTitle($0.start, now: now, calendar: calendar) } == ["Today", "10 Mar"])
    }

    /// The summary's byline, and what the Summary tab says while there is no summary to show.
    @Test func theSummarySaysWhoWroteItAndWhyThereIsNone() {
        #expect(BroadcastSummaryView.byline(at: Snapshots.clock.now.addingTimeInterval(4 * 3600 + 5 * 60), calendar: Snapshots.clock.calendar)
                == "Written by the Operator at 16:05")
        #expect(BroadcastSummaryView.placeholder(for: .writing) == "The Operator is writing its summary.")
        #expect(BroadcastSummaryView.placeholder(for: .notComing) == "The Operator didn’t write a summary.")
        #expect(BroadcastSummaryView.placeholder(for: .endedEarly) == "Ended before it finished. The Operator didn’t write a summary.")
        #expect(BroadcastSummaryView.placeholder(for: .written(text: "Done.", at: Snapshots.clock.now)) == nil)
        #expect(BroadcastSummaryView.paragraphs("First.\nStill first.\n\n  \nSecond.\n\n") == ["First.\nStill first.", "Second."])
    }

    /// Worked around in AiTerm comes after Left for you, only when the Operator reported a snag. Each item's Copy says
    /// what it puts on the clipboard, and what AiTerm showed and how the Operator got unstuck, on screen nowhere else,
    /// are its tooltip and what VoiceOver reads as its value.
    @Test func theSummaryListsSnagsAfterLeftForYou() {
        let snag = OperatorSnag(key: "prompt", title: "Waiting on you showed a task with no prompt open",
                                showed: "run_status listed PAY-232 under promptsWaitingOnYou.",
                                actual: "No prompt was open: read_task what: prompt was null and Codex had ended its turn.",
                                workaround: "Read the task's screen, saw the finished turn and checked the work.",
                                appVersion: "0.28.1", at: Snapshots.clock.now)
        #expect(BroadcastSummaryView.lists(leftForYou: ["File the finds"], snags: [snag]) == [.leftForYou, .workedAround])
        #expect(BroadcastSummaryView.lists(leftForYou: [], snags: [snag]) == [.workedAround])
        #expect(BroadcastSummaryView.lists(leftForYou: ["File the finds"], snags: []) == [.leftForYou], "left out with none")
        #expect(BroadcastSummaryView.lists(leftForYou: [], snags: []).isEmpty)
        #expect(BroadcastSummaryView.SummaryList.workedAround.title == "Worked around in AiTerm")
        #expect(BroadcastSummaryView.SummaryList.leftForYou.title == "Left for you")

        #expect(BroadcastSummaryView.details(of: snag) == """
            AiTerm showed: run_status listed PAY-232 under promptsWaitingOnYou.
            The Operator: Read the task's screen, saw the finished turn and checked the work.
            """)
        #expect(BroadcastSummaryView.copyLabel(of: snag)
                == "Copy “Waiting on you showed a task with no prompt open” as a complete Markdown fix task for AiTerm")
        #expect(BroadcastSummaryView.copyHelp == "Copy a complete Markdown fix task for AiTerm")
        #expect(BroadcastSummaryView.copyAllHelp == "Copy every one as a complete Markdown fix task for AiTerm")
        #expect(BroadcastSummaryView.copied == "Copied" && BroadcastSummaryView.copiedFor == .seconds(2))
    }

    @Test func theBoardOpensInTheSheetSlotForALiveBroadcastOnly() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        controller.presentOverview(run: run.id)
        #expect(controller.sheet == nil, "no such broadcast")
        controller.workspace.mutate { $0.runs = [run] }
        controller.presentOverview(run: run.id)
        guard case .broadcastBoard(let id) = controller.sheet else { Issue.record("no board"); return }
        #expect(id == run.id)
        #expect(controller.sheet?.id == "board-\(run.id)")
    }

    /// What a card opens, as the app performs it: a task's window, the Operator's window, or nothing more
    /// than the banner already showing the problem.
    @Test func eachCardOpensItsPlace() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-web")
        let task = OperatorUIFixtures.task("Footer", project: project.id, windowId: "w1",
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.runs = [run]; state.tasks = [task] }
        var chosen: [UUID] = []
        controller.focus.onChoosingOperationWithoutWindow { id in chosen.append(id); return nil }
        controller.open(.taskWindow(task.id), run: run.id)
        #expect(controller.focus.selection == .task(task.id))
        controller.open(.sidebarBanner(issue: "issue-7"), run: run.id)
        #expect(controller.focus.selection == .task(task.id), "the banner is already up: nothing else moves")
        controller.workspace.mutate { $0.runs[0].operatorWindowId = nil }
        controller.open(.operatorWindow, run: run.id)
        #expect(controller.focus.selection == .operation(run.id))
        #expect(chosen == [run.id], "its window is asked back when it is closed")
    }

    /// A card never acts on a broadcast that is no longer the active one: ended, or being ended.
    @Test func aCardOfAnEndedBroadcastOpensNothing() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run(windowId: nil)
        let project = OperatorUIFixtures.project("pluto-web")
        let task = OperatorUIFixtures.task("Footer", project: project.id, windowId: "w1",
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.runs = [run]; state.tasks = [task] }
        var chosen: [UUID] = []
        controller.focus.onChoosingOperationWithoutWindow { id in chosen.append(id); return nil }
        controller.workspace.mutate { $0.runs[0].intent = .stopped }
        controller.open(.taskWindow(task.id), run: run.id)
        controller.open(.operatorWindow, run: run.id)
        #expect(controller.focus.selection == nil)
        #expect(chosen.isEmpty)
        var paused = false
        controller.boardActions(for: run.id, dismiss: { paused = true }).end(false)
        #expect(!paused, "nor does a button")
    }

    /// The board is the projection's, written only when it differs: a change it draws nothing of — another
    /// project's task, the sidebar's frame — re-runs neither the board's body nor a card's; a change to its
    /// run re-runs the board and the card that moved, not the others.
    @Test func theBoardRedrawsForItsRunAlone() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let web = OperatorUIFixtures.project("pluto-web"), other = OperatorUIFixtures.project("other")
        let run = OperatorUIFixtures.run(projectIds: [web.id])
        let moving = OperatorUIFixtures.task("Footer", project: web.id,
                                             operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        let waiting = OperatorUIFixtures.task("Header", project: web.id,
                                              operated: OperatorUIFixtures.operated(run: run.id, key: "b", state: .queued))
        controller.workspace.mutate { state in
            state.append(project: web); state.append(project: other); state.runs = [run]; state.tasks = [moving, waiting]
        }
        let counter = RowBodyCounter()
        let host = NSHostingView(rootView: BroadcastBoardHost(runId: run.id, controller: controller).environment(\.rowBodyCounter, counter))
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        let window = testWindow(contentRect: host.frame, styleMask: [.titled])
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil) }
        settle(host) { counter.counts[run.id] != nil && counter.counts[waiting.id] != nil }
        settle(host, for: 0.1)

        counter.reset()
        controller.workspace.mutate { state in
            state.tasks.append(OperatorUIFixtures.task("Elsewhere", project: other.id, operated: nil))
            state.sidebarFrame = CGRect(x: 10, y: 10, width: 400, height: 800)
        }
        settle(host, for: 0.2)
        #expect(counter.counts.isEmpty, "nothing the board draws: redrawn \(counter.counts)")

        controller.workspace.mutate { $0.tasks[0].operated?.state = .noChange }
        settle(host) { counter.counts[run.id] != nil }
        settle(host, for: 0.1)
        #expect(counter.counts[run.id] != nil, "its run changed: the board redraws")
        #expect(counter.counts[moving.id] != nil, "the card that moved is drawn again")
        #expect(counter.counts[waiting.id] == nil, "a card that did not change is not")
    }

    @Test func endingAsksFirstWithCancelOnEscape() {
        let end = OperatorAlerts.endBroadcast(OperatorUIFixtures.run(), unstarted: 0, running: 2)
        #expect(end.message == "End “Newsletter signup”?")
        #expect(end.detail == "2 running tasks finish their turn and become yours. Worktrees and MRs stay.")
        #expect(end.buttons == ["End Broadcast", "Cancel"] && end.escapeButton == 1 && !end.defaultDeletes)
    }

    @Test func cancellingEndLeavesTheBroadcastRunning() async throws {
        let prompter = ScriptedPrompter(answering: "⎋")
        let controller = AppController(preferences: .scratch(), prompter: prompter)
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        #expect(await !controller.confirmEnd(run))
        #expect(prompter.asked == [controller.operatorController.endPrompt(run: run)])
        #expect(controller.state.runs.first?.state == .active)
    }

    /// The board closes once the broadcast ended, from either End; a failed end keeps it up, the failure
    /// reported and the broadcast as it was.
    @Test(arguments: [true, false]) func theBoardClosesOnlyOnceTheEndSucceeded(confirming: Bool) async throws {
        for failing in [false, true] {
            let controller = AppController(preferences: .scratch(), prompter: ScriptedPrompter(answering: "End Broadcast"))
            defer { controller.shutdown() }
            try controller.loadWorkspace()
            let run = OperatorUIFixtures.run()
            controller.workspace.mutate { $0.runs = [run] }
            #expect(controller.workspace.flush())
            if failing {
                // Saving fails from now on: the backup's place is a folder.
                try FileManager.default.createDirectory(at: controller.workspace.file.backupURL, withIntermediateDirectories: false)
            }
            var dismissed = false
            controller.boardActions(for: run.id, dismiss: { dismissed = true }).end(confirming)
            if failing {
                await eventually(describing: "the failure to be reported") { controller.notices.issue != nil }
                try await Task.sleep(for: .milliseconds(50))
                #expect(!dismissed, "the end failed: the board stays up")
                #expect(controller.state.runs.first?.state == .active, "the broadcast is as it was")
            } else {
                await eventually(describing: "the board to close") { dismissed }
                #expect(controller.state.runs.first?.state == .stopped)
            }
        }
    }

    /// A notification's click (spec §13): the summary is ready, so the board opens, once.
    @Test func aNotificationsClickOpensTheBoard() async throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run(state: .complete)
        controller.workspace.mutate { $0.runs = [run] }
        controller.openNote(.overview(run.id))
        await eventually(describing: "the board in the sheet slot") {
            if case .broadcastBoard(run.id) = controller.sheet { true } else { false }
        }
        #expect(controller.operatorController.presentOverview == nil, "presented once, then cleared")
    }

    /// A request already there when the app starts watching — a click that launched it — is presented too.
    @Test func aRequestMadeBeforeTheWatchIsPresented() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        controller.operatorController.presentOverview = run.id
        controller.presentRequestedOverview()
        guard case .broadcastBoard(let id) = controller.sheet else { Issue.record("no board"); return }
        #expect(id == run.id)
        #expect(controller.operatorController.presentOverview == nil)
    }

    /// Rename… is the `NameSheet` every other rename is, with the broadcast's own copy.
    @Test func renamingABroadcastOpensTheNameSheet() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        controller.perform(.rename, on: run)
        guard case .rename(let target) = controller.sheet else { Issue.record("no rename sheet"); return }
        #expect(target == .broadcast(run))
        #expect(target.title == "Rename broadcast" && target.fieldLabel == "Broadcast name" && target.name == "Newsletter signup")
        #expect(target.subtitle == "Renames its row and its overview; the Operator’s window and its tasks keep theirs.")
    }

    /// What the operator controller refuses reaches the banner, named after what it was for, and is never dropped.
    @Test func whatTheOperatorControllerRefusesLandsInTheBanner() async throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        controller.rename(run: run, to: "Other")
        await eventually(describing: "the rename's banner") { controller.notices.issue != nil }
        #expect(controller.notices.issue?.title == "Couldn’t rename “Newsletter signup”.")
        #expect(controller.notices.issue?.reason == "This broadcast is no longer in AiTerm.")
        controller.notices.dismissIssue()
        controller.pause(run)
        await eventually(describing: "the pause's banner") { controller.notices.issue != nil }
        #expect(controller.notices.issue?.title == "Couldn’t pause “Newsletter signup”.")
    }
}
