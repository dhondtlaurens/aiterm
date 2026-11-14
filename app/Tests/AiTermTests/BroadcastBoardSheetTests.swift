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

    /// The sheet closes first, then what the row opens comes forward; a Todo task's row is not a button.
    @Test func clickingARowDismissesFirst() {
        var moments: [String] = []
        let task = UUID()
        let actions = BoardActions(open: { opens in
            switch opens {
            case .taskWindow(let id): moments.append(id == task ? "open the task's window" : "open another window")
            case .prompt(_, let tab): moments.append("bring the prompt's tab \(tab)")
            case .operatorWindow: moments.append("open the Operator's window")
            case .sidebarBanner(let issue): moments.append("show the banner's \(issue)")
            case .nothing: moments.append("open nothing")
            }
        })
        for opens: BroadcastBoard.Opens in [.taskWindow(task), .prompt(task: task, tab: "e2e"), .operatorWindow,
                                            .sidebarBanner(issue: "issue-7"), .nothing] {
            BroadcastBoardSheet.choose(opens, dismiss: { moments.append("dismiss") }, actions: actions)
        }
        #expect(moments == ["dismiss", "open the task's window", "dismiss", "bring the prompt's tab e2e",
                            "dismiss", "open the Operator's window",
                            "dismiss", "show the banner's issue-7"], "a Todo task's row does nothing, not even close the sheet")
        #expect(!BroadcastBoardSheet.isButton(.nothing) && BroadcastBoardSheet.isButton(.operatorWindow))
    }

    /// A row whose task has a question answered in the sheet shows that question instead of opening a window; a prompt,
    /// answered in its own window, leaves the row its window; an answered question no longer takes the click.
    @Test func aWaitingRowShowsItsQuestion() throws {
        var run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-web")
        let asked = OperatorUIFixtures.task("Footer", project: project.id, windowId: "w1",
                                            operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        let prompted = OperatorUIFixtures.task("Header", project: project.id, windowId: "w2",
                                               operated: OperatorUIFixtures.operated(run: run.id, key: "b", state: .working))
        let prompt = OperatorUIFixtures.question("Claude asks to run npm install.", id: OperatorQuestion.promptPrefix + "b", task: prompted.id)
        #expect(prompt.kind == .prompt)
        run.questions = [OperatorUIFixtures.question("Keep the footer's links?", id: "a-links", task: asked.id), prompt]
        func board(_ run: OperatorRun) -> BroadcastBoard {
            var state = AppState()
            state.append(project: project); state.runs = [run]; state.tasks = [asked, prompted]
            return BroadcastBoard.make(run: run, state: state, acting: .none, requests: OperatorRequests.open(run: run, state: state))
        }
        #expect(BroadcastBoardSheet.shows(asked.id, on: board(run)) == "a-links")
        #expect(BroadcastBoardSheet.shows(prompted.id, on: board(run)) == nil, "a prompt is answered in its window")
        let card = try #require(board(run).stages.flatMap(\.cards).first { $0.id == asked.id })
        #expect(BoardRow.isButton(card, showsQuestion: true))
        #expect(BoardRow.hint(card, showsQuestion: true) == "Shows its question under Waiting on you.")
        #expect(BoardRow.hint(card, showsQuestion: false) == BoardRow.hint(opens: card.opens))
        // A second question of the same task is the row's next click: the row is another row once the first is answered.
        run.questions.append(OperatorUIFixtures.question("And its icons?", id: "a-icons", task: asked.id))
        let first = BoardRow(card: card, question: BroadcastBoardSheet.shows(asked.id, on: board(run)), actions: BoardActions(), click: {})
        run.questions[0].answeredHere = "Keep them"
        #expect(BroadcastBoardSheet.shows(asked.id, on: board(run)) == "a-icons")
        let second = BoardRow(card: card, question: BroadcastBoardSheet.shows(asked.id, on: board(run)), actions: BoardActions(), click: {})
        #expect(first != second, "the click's question changed: the row is drawn again with it")
        run.questions[2].answeredHere = "Them too"
        #expect(BroadcastBoardSheet.shows(asked.id, on: board(run)) == nil, "all answered: the row is its window's again")
    }

    /// The row's mark is its sidebar row's: the pause sign while it is queued, the check once the Operator's work on it
    /// is over, else its status.
    @Test func aRowsMarkIsItsSidebarRows() {
        var card = BroadcastBoard.Card(id: UUID(), title: "Footer", avatars: AvatarGroup(marks: [AgentKind.claude.session], overflow: 0),
                                       status: .working, ticket: nil, ticketSummary: nil, mr: nil, mrHost: nil, mrTitle: nil, project: nil,
                                       line: OperatorLine("Operator watching", look: .acting), takenOver: false, needsYou: false,
                                       opens: .nothing, modelTooltip: nil, result: nil)
        #expect(BoardRow.mark(of: card) == .status(.working))
        #expect(!BoardRow.isButton(card, showsQuestion: false), "not started: no button")
        card.queued = true
        #expect(BoardRow.mark(of: card) == .pauseSign)
        card.queued = false; card.status = .idle; card.line = OperatorLine("merged · 9b3e07d", look: .ended)
        #expect(BoardRow.mark(of: card) == .ended)
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

    /// The pager: it opens on the oldest question that still waits, shows one asked for, moves on after an answer to the
    /// next that still waits, and keeps an answered one in view when nothing else does.
    @Test func thePagerShowsTheOldestThatStillWaits() {
        func question(_ key: String, answered: String? = nil) -> BroadcastBoard.ListedQuestion {
            BroadcastBoard.ListedQuestion(key: key, task: nil, ticket: nil, title: "The broadcast", askedAt: OperatorUIFixtures.epoch,
                                          from: "The Operator asks", text: key, answer: .here(choices: [], field: true), answered: answered)
        }
        let questions = [question("a", answered: "yes"), question("b"), question("c")]
        #expect(QuestionPager.shown(nil, in: questions)?.key == "b", "the oldest that still waits")
        #expect(QuestionPager.shown("c", in: questions)?.key == "c", "the one asked for")
        #expect(QuestionPager.shown("gone", in: questions)?.key == "b", "resolved meanwhile: the oldest that still waits")
        #expect(QuestionPager.shown(nil, in: [question("a", answered: "yes")])?.key == "a", "all answered: the oldest")
        #expect(QuestionPager.shown(nil, in: []) == nil)

        #expect(QuestionPager.afterAnswering("b", in: questions) == "c")
        #expect(QuestionPager.afterAnswering("c", in: questions) == "b", "none after it: the first before it that waits")
        let last = [question("a", answered: "yes"), question("b")]
        #expect(QuestionPager.afterAnswering("b", in: last) == "b", "nothing else waits: it stays")
        #expect(QuestionPager.shown(QuestionPager.afterAnswering("b", in: last), in: [last[0], question("b", answered: "no")])?.key == "b",
                "and says what was answered, an older answer not taking its place")

        #expect(QuestionPager.step(1, from: "a", in: questions) == "b" && QuestionPager.step(-1, from: "b", in: questions) == "a")
        #expect(QuestionPager.step(-1, from: "a", in: questions) == nil && QuestionPager.step(1, from: "c", in: questions) == nil)
        #expect(QuestionPager.position(of: "b", in: questions) == "2 of 3")
    }

    /// Activity lists what changed and offers Show everything only while a call is folded away; with everything, Show
    /// what changed.
    @Test func activityFoldsTheLookingAwayBehindItsLink() {
        func entry(_ tool: String) -> ActivityEntry {
            ActivityEntry(at: OperatorUIFixtures.epoch, tool: tool, task: nil, taskLabel: nil, arguments: [:], outcome: .ok, result: "",
                          line: tool, reason: nil)
        }
        let mixed = [entry("mark_task"), entry("run_status"), entry("shell"), entry("ask_you")]
        #expect(BroadcastActivityView.listed(mixed, everything: false).map(\.tool) == ["mark_task", "ask_you"])
        #expect(BroadcastActivityView.listed(mixed, everything: true) == mixed)
        #expect(BroadcastActivityView.link(mixed, everything: false) == "Show everything")
        #expect(BroadcastActivityView.link(mixed, everything: true) == "Show what changed")
        #expect(BroadcastActivityView.link([entry("mark_task")], everything: false) == nil, "nothing folded away: no link")
        #expect(BroadcastActivityView.listed([entry("run_status")], everything: false).isEmpty)
        #expect(BroadcastActivityView.nothingChanged == "Nothing changed yet.")
    }

    /// A question's answers are buttons: its choices, or the one that opens where it waits; the line trailing its head
    /// says who asks and how long ago.
    @Test func aQuestionAnsweredElsewhereHasOneButton() {
        let task = UUID()
        #expect(QuestionBlock.elsewhere(.here(choices: ["Keep it"], field: true)) == nil)
        let window = QuestionBlock.elsewhere(.window(task: task, tab: "e2e-tests"))
        #expect(window?.title == "Open Its Window" && window?.opens == .prompt(task: task, tab: "e2e-tests"))
        let chat = QuestionBlock.elsewhere(.chat)
        #expect(chat?.title == "Open the Operator’s Chat" && chat?.opens == .operatorWindow)
        let question = BroadcastBoard.ListedQuestion(key: "k", task: task, ticket: "PAY-232", title: "Payment provider switch",
                                                     askedAt: OperatorUIFixtures.epoch, from: "The Operator asks", text: "Keep the gate?",
                                                     answer: .here(choices: [], field: true))
        #expect(QuestionBlock.asker(question, now: OperatorUIFixtures.epoch.addingTimeInterval(24 * 60)) == "The Operator asks · 24 min")
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

    /// The Tasks tab's sections are named once each. A snag's Copy says what it puts on the clipboard, and what AiTerm
    /// showed and how the Operator got unstuck, on screen nowhere else, are its tooltip and what VoiceOver reads as its value.
    @Test func theSummarysSectionsAndASnagsCopy() {
        let snag = OperatorSnag(key: "prompt", title: "Waiting on you showed a task with no prompt open",
                                showed: "run_status listed PAY-232 under promptsWaitingOnYou.",
                                actual: "No prompt was open: read_task what: prompt was null and Codex had ended its turn.",
                                workaround: "Read the task's screen, saw the finished turn and checked the work.",
                                appVersion: "0.28.1", at: Snapshots.clock.now)
        #expect(BroadcastSummaryView.title == "Summary")
        #expect(LeftForYouList.title == "Left for you")
        #expect(WorkedAroundList.title == "Worked around in AiTerm")

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
        try controller.workspace.load()
        let run = OperatorUIFixtures.run()
        controller.presentBoard(run: run.id)
        #expect(controller.sheet == nil, "no such broadcast")
        controller.workspace.mutate { $0.runs = [run] }
        controller.presentBoard(run: run.id)
        guard case .broadcastBoard(let id) = controller.sheet else { Issue.record("no board"); return }
        #expect(id == run.id)
        #expect(controller.sheet?.id == "board-\(run.id)")
    }

    /// What a card opens, as the app performs it: a task's window, the Operator's window, or nothing more
    /// than the banner already showing the problem.
    @Test func eachCardOpensItsPlace() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.workspace.load()
        let run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-web")
        let task = OperatorUIFixtures.task("Footer", project: project.id, windowId: "w1",
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.runs = [run]; state.tasks = [task] }
        var chosen: [UUID] = []
        controller.focus.setReopenOperatorWindow { id in chosen.append(id); return nil }
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
        try controller.workspace.load()
        let run = OperatorUIFixtures.run(windowId: nil)
        let project = OperatorUIFixtures.project("pluto-web")
        let task = OperatorUIFixtures.task("Footer", project: project.id, windowId: "w1",
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.runs = [run]; state.tasks = [task] }
        var chosen: [UUID] = []
        controller.focus.setReopenOperatorWindow { id in chosen.append(id); return nil }
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
    /// project's task, the sidebar's frame — re-runs neither the board's body nor a row's; a change to its
    /// run re-runs the board and the row that moved, not the others.
    @Test func theBoardRedrawsForItsRunAlone() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.workspace.load()
        let web = OperatorUIFixtures.project("pluto-web"), other = OperatorUIFixtures.project("other")
        let run = OperatorUIFixtures.run(projectIds: [web.id])
        let moving = OperatorUIFixtures.task("Footer", project: web.id,
                                             operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        let waiting = OperatorUIFixtures.task("Header", project: web.id,
                                              operated: OperatorUIFixtures.operated(run: run.id, key: "b", state: .queued))
        controller.workspace.mutate { state in
            state.append(project: web); state.append(project: other); state.runs = [run]; state.tasks = [moving, waiting]
        }
        controller.sheet = .broadcastBoard(run.id)
        let counter = RowBodyCounter()
        let host = testHost(BroadcastBoardHost(runId: run.id, controller: controller).environment(\.rowBodyCounter, counter), size: CGSize(width: Sheet.width, height: Sheet.boardHeight))
        let window = testWindow(contentRect: host.frame, styleMask: [.titled])

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
        #expect(counter.counts[moving.id] != nil, "the row that moved is drawn again")
        #expect(counter.counts[waiting.id] == nil, "a row that did not change is not")
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
        try controller.workspace.load()
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
            try controller.workspace.load()
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
        try controller.workspace.load()
        let run = OperatorUIFixtures.run(state: .complete)
        controller.workspace.mutate { $0.runs = [run] }
        controller.openNote(.board(run.id))
        await eventually(describing: "the board in the sheet slot") {
            if case .broadcastBoard(run.id) = controller.sheet { true } else { false }
        }
        #expect(controller.operatorController.presentBoard == nil, "presented once, then cleared")
    }

    /// A question's notification or the Operator row's click opens the board on that question: presented, and asked to
    /// show it, which the pager does while it is listed; once it is gone, the oldest that still waits.
    @Test func aQuestionsClickOpensTheBoardOnIt() async throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.workspace.load()
        var run = OperatorUIFixtures.run()
        run.questions = [OperatorUIFixtures.question("Keep the access gate for admins?", id: "t2-gate")]
        controller.workspace.mutate { $0.runs = [run] }
        controller.openNote(.question(run: run.id, key: "t2-gate"))
        await eventually(describing: "the board in the sheet slot") {
            if case .broadcastBoard(run.id) = controller.sheet { true } else { false }
        }
        #expect(controller.operatorController.boardFocus?.key == "t2-gate" && controller.operatorController.boardFocus?.run == run.id)

        let board = BroadcastBoard.make(run: run, state: controller.state, acting: .none, requests: [])
        #expect(QuestionPager.shown("t2-gate", in: board.waiting)?.key == "t2-gate")
        #expect(QuestionPager.shown("gone", in: board.waiting)?.key == "t2-gate", "resolved before the click: the oldest that waits")
        let sheet = BroadcastBoardSheet(board: board, reopenFailed: false, actions: BoardActions(), activity: nil,
                                        focus: controller.operatorController.boardFocus)
        #expect(sheet != BroadcastBoardSheet(board: board, reopenFailed: false, actions: BoardActions(), activity: nil),
                "a new focus draws again")

        // The Operator row waiting on that question shows the same one.
        let row = OperatorRow(id: OperatorRow.id(of: run.id), runId: run.id, agent: AgentKind.claude.session, title: run.name,
                              line: OperatorLine("waiting on you", look: .needsYou), status: .needsInput, question: "t2-gate")
        let before = controller.operatorController.boardFocus?.id
        #expect(controller.chooseOperatorRow(row) == nil)
        #expect(controller.operatorController.boardFocus?.key == "t2-gate" && controller.operatorController.boardFocus?.id != before)
    }

    /// A request already there when the app starts watching — a click that launched it — is presented too.
    @Test func aRequestMadeBeforeTheWatchIsPresented() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.workspace.load()
        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        controller.operatorController.presentBoard = run.id
        controller.presentRequestedBoard()
        guard case .broadcastBoard(let id) = controller.sheet else { Issue.record("no board"); return }
        #expect(id == run.id)
        #expect(controller.operatorController.presentBoard == nil)
    }

    /// Rename… is the `NameSheet` every other rename is, with the broadcast's own copy.
    @Test func renamingABroadcastOpensTheNameSheet() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.workspace.load()
        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        controller.perform(.rename, on: run)
        guard case .rename(let target) = controller.sheet else { Issue.record("no rename sheet"); return }
        #expect(target == .broadcast(run))
        #expect(target.title == "Rename broadcast" && target.fieldLabel == "Broadcast name" && target.name == "Newsletter signup")
        #expect(target.subtitle == "Renames its row and its board; the Operator’s window and its tasks keep theirs.")
    }

    /// What the operator controller refuses reaches the banner, named after what it was for, and is never dropped.
    @Test func whatTheOperatorControllerRefusesLandsInTheBanner() async throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.workspace.load()
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
