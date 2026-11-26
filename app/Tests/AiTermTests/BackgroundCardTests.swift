import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The card a background mark opens (proposal Background work on your own tasks B, and A of its several jobs, 22 Oct
/// 2026): what it says, when it opens and closes, and that it lies over its row without growing it.
@MainActor
struct BackgroundCardTests {
    private let tests = BackgroundJob(kind: .shell, text: "scripts/test.sh all")
    private let server = BackgroundJob(kind: .shell, text: "npm run dev")
    private let ci = BackgroundJob(kind: .monitor, text: "Watch CI on !45 until the pipeline ends")

    @Test func itDescribesWorkWithoutClaimingTheTurnEnded() {
        #expect(BackgroundCard(jobs: [tests]).heading == "Background work")
        #expect(BackgroundCard(jobs: [tests, server, ci]).heading == "Background work · 3 jobs")
        #expect(BackgroundCard(jobs: [tests, ci]).spoken
                == "Background work: scripts/test.sh all, Watch CI on !45 until the pipeline ends")
    }

    /// Proposal Background work with vendor avatars (A, B2, C1; 26 Nov 2026): agent work wears the vendor of the tab it
    /// runs in, everything else the terminal mark, every one at `Size.vendorMark`.
    @Test func agentWorkWearsItsVendorAndToolsTheTerminal() {
        #expect(BackgroundCard.mark(tests) == .shell && BackgroundCard.mark(ci) == .shell)
        #expect(BackgroundCard.mark(BackgroundJob(kind: .task, text: "Indexing the docs")) == .shell)
        #expect(BackgroundCard.mark(BackgroundJob(kind: .subagent, text: "Inspect fixture", agent: .codex)) == .codex)
        #expect(BackgroundCard.mark(BackgroundJob(kind: .agent, text: "Review changes", agent: .claude)) == .claude)
        // Only Claude Code sends agent work without a tab to name it: a fixture, or a test run.
        #expect(BackgroundCard.mark(BackgroundJob(kind: .subagent, text: "Review the fix")) == .claude)
        // An idle teammate keeps its vendor; its corner says it sleeps.
        #expect(BackgroundCard.mark(BackgroundJob(kind: .subagent, text: "Build skin A", idle: true)) == .claude)
    }

    /// From two agents at work the heading carries them as the task row's avatar group; idle teammates and tools
    /// do not count.
    @Test func theHeadingGroupsTwoOrMoreAgentsAtWork() {
        let claude = BackgroundJob(kind: .subagent, text: "Review the fix", agent: .claude)
        let codex = BackgroundJob(kind: .subagent, text: "Inspect fixture", agent: .codex)
        let workflow = BackgroundJob(kind: .agent, text: "Review changes", agent: .claude)
        let asleep = BackgroundJob(kind: .subagent, text: "Build skin A", idle: true, agent: .claude)
        #expect(BackgroundCard(jobs: [claude, tests, asleep]).agents == nil)
        #expect(BackgroundCard(jobs: [claude, codex, tests]).agents == AvatarGroup(marks: [.claude, .codex], overflow: 0))
        #expect(BackgroundCard(jobs: [claude, codex, workflow, asleep]).agents == AvatarGroup(marks: [.claude], overflow: 2))
    }

    /// The daemon sends agent work that is no counted child (a workflow, a cloud session, a dream) as `agent`; the card
    /// names each line's vendor from its tab, which status and the Operator never read.
    @Test func displayJobsCarryTheirTabsVendor() throws {
        var session = SessionInfo.make("s", agent: .codex, state: .done)
        session.work = try JSONDecoder().decode([WorkItem].self, from: Data(
            #"[{"kind":"agent","text":"Review changes","holdsTurn":true},{"kind":"subagent","text":"Inspect fixture","holdsTurn":true}]"#.utf8))
        #expect(session.work.map(\.kind) == [.agent, .subagent])
        #expect(SidebarModel.displayJobs(of: [session]).map(\.agent) == [.codex, .codex])
        #expect(SidebarModel.backgroundJobs(of: [session]).allSatisfy { $0.agent == nil })
    }

    /// Eight named teammates that delivered their reports and wait for messages: the daemon sends them idle, holding
    /// nothing. The row is done, its mark does not spin, and the card counts no running job but still lists them.
    @Test func onlyIdleTeammatesSpinNothingAndCountNoJob() throws {
        let items = (1...8).map { #"{"kind":"subagent","text":"Build skin \#($0)","holdsTurn":false,"idle":true}"# }
        var session = SessionInfo.make("s", state: .done)
        session.work = try JSONDecoder().decode([WorkItem].self, from: Data(("[" + items.joined(separator: ",") + "]").utf8))
        #expect(session.work.allSatisfy { $0.idle && !$0.holdsTurn })
        #expect(SidebarModel.backgroundJobs(of: [session]).isEmpty)
        #expect(SidebarModel.aggregate(tabs: [session]) == .done)
        let card = BackgroundCard(jobs: SidebarModel.displayJobs(of: [session]))
        #expect(card.running.isEmpty && card.idle.count == 8)
        #expect(card.heading == "Background work · none running")
        #expect(card.lines.count == 8)
    }

    /// Running work keeps its count and comes first; idle teammates follow, under no heading of their own.
    @Test func idleTeammatesFollowTheRunningWorkWithoutCounting() {
        let reviewer = BackgroundJob(kind: .task, text: "Review the fix", idle: true)
        let card = BackgroundCard(jobs: [reviewer, tests, server])
        #expect(card.heading == "Background work · 2 jobs")
        #expect(card.lines == [tests, server, reviewer])
        #expect(card.spoken == "Background work: scripts/test.sh all, npm run dev. Idle, can be messaged: Review the fix")
        #expect(BackgroundCard(jobs: [tests, reviewer]).heading == "Background work")
    }

    /// A teammate a message woke holds the turn again: the row is back in the background, its card counts it.
    @Test func aWokenTeammateRunsAgain() throws {
        var session = SessionInfo.make("s", state: .done)
        session.work = try JSONDecoder().decode([WorkItem].self, from: Data(
            #"[{"kind":"subagent","text":"Build skin A","holdsTurn":true},{"kind":"subagent","text":"Build skin B","holdsTurn":false,"idle":true}]"#.utf8))
        #expect(SidebarModel.aggregate(tabs: [session]) == .background)
        #expect(SidebarModel.backgroundJobs(of: [session]) == [BackgroundJob(kind: .subagent, text: "Build skin A")])
        #expect(BackgroundCard(jobs: SidebarModel.displayJobs(of: [session])).heading == "Background work")
    }

    @Test func nativeDisplayLabelsLeaveWorkerTextAndReadinessAlone() throws {
        let data = Data(#"[{"kind":"shell","text":"scripts/test.sh","holdsTurn":true,"displayLabel":"Run the gate"},{"kind":"subagent","text":"default","holdsTurn":false,"displayLabel":"Review checkout"}]"#.utf8)
        var session = SessionInfo.make("s", state: .done)
        session.work = try JSONDecoder().decode([WorkItem].self, from: data)
        let jobs = SidebarModel.displayJobs(of: [session])
        #expect(BackgroundCard(jobs: jobs).spoken == "Background work: Run the gate, Review checkout")
        #expect(SidebarModel.backgroundJobs(of: [session]) == [BackgroundJob(kind: .shell, text: "scripts/test.sh")])
        #expect(session.work.map(\.text) == ["scripts/test.sh", "default"])
        #expect(SidebarModel.aggregate(tabs: [session]) == .background)
        #expect(BackgroundCard(jobs: jobs).accessibilityValue(status: .working, detail: "Running scripts/test.sh")
                == "Working. Running scripts/test.sh. Background work: Review checkout")
    }

    /// Hovering known work opens the same card for every active status.
    @Test(arguments: [TaskStatus.background, .working, .needsInput])
    func hoveringTheMarkOpensTheExistingCard(status: TaskStatus) async throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        let task = TaskItem.make(project: UUID(), title: "A task with background work", worktreePath: "/wt", model: "sonnet",
            createdAt: Date(), windowId: "w")
        let row = TaskRow(id: task.id, title: task.title, jiraKey: nil, jiraUrl: nil, mr: nil, branch: .none,
                          avatars: AvatarGroup(marks: [.claude], overflow: 0), status: status, background: [tests, ci],
                          mark: .status(status))
        let changed = try await cardSurfaceChange(TaskRowView(row: row, controller: controller))
        #expect(changed > 1000, "the same card opens: \(changed) pixels")
    }

    @Test(arguments: [TaskStatus.background, .working, .needsInput], [false, true])
    func terminalRowsUseTheSameCardAndEmptyListsOfferNone(status: TaskStatus, empty: Bool) async throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        let project = Project.make(name: "Repo", path: "/repo", addedAt: Date())
        let row = TerminalRow(id: UUID(), name: "Claude terminal", branch: .none,
                              avatars: AvatarGroup(marks: [.claude], overflow: 0), status: status, background: empty ? [] : [tests])
        let changed = try await cardSurfaceChange(TerminalRowView(row: row, terminal: nil, project: project, controller: controller))
        #expect(empty ? changed == 0 : changed > 1000, "known work opens the existing terminal card: \(changed) pixels")
    }

    private func cardSurfaceChange(_ content: some View) async throws -> Int {
        let hover = BackgroundCardHover(sleep: { _ in })
        func bitmap() throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: content
                .environment(\.seededHover, SeededHover(backgroundCard: hover))
                .environment(\.motionStill, .snapshot).frame(width: 320).background(Palette.sidebar))
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let closed = try bitmap()
        hover.mark(true)
        await settle()
        let opened = try bitmap()
        var changed = 0
        for y in 0..<closed.pixelsHigh {
            for x in 0..<closed.pixelsWide {
                let a = try #require(closed.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let b = try #require(opened.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let difference = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                if difference > 0.1 { changed += 1 }
            }
        }
        return changed
    }

    /// Lets every task the hover started run to its end.
    private func settle() async { for _ in 0..<10 { await Task.yield() } }

    @Test func accessibilityKeepsInputStatusAndNamesWorkOnce() {
        let card = BackgroundCard(jobs: [tests, ci])
        #expect(card.accessibilityValue(status: .needsInput, detail: "Permission requested")
                == "Needs input. Permission requested. Background work: scripts/test.sh all, Watch CI on !45 until the pipeline ends")
        #expect(card.accessibilityValue(status: .working, detail: card.spoken) == "Working. " + card.spoken)
    }

    @Test func itOpensOnTheMarkAndStaysWhileThePointerCrossesToIt() async {
        let hover = BackgroundCardHover(sleep: { _ in })
        hover.mark(true)
        await settle()
        #expect(hover.isOpen)
        // Off the mark and onto the card before the close lands: it stays open.
        hover.mark(false)
        hover.card(true)
        await settle()
        #expect(hover.isOpen)
        hover.card(false)
        await settle()
        #expect(!hover.isOpen)
    }

    @Test func aPointerPassingOverTheMarkOpensNothing() async {
        let hover = BackgroundCardHover(sleep: { _ in })
        hover.mark(true)
        hover.mark(false)
        await settle()
        #expect(!hover.isOpen)
    }

    /// A driven task that ended is yours again: work left running keeps its own mark, not the Operator's check.
    @Test func anEndedTaskInTheBackgroundKeepsItsMark() {
        let ended = OperatorLine("done", look: .ended)
        #expect(TaskRowMark(status: .background, line: ended) == .status(.background))
        #expect(TaskRowMark(status: .done, line: ended) == .ended)
    }

    @Test(arguments: InterfaceScale.all)
    func jobLabelsLineUpAfterDifferentGlyphs(scale: InterfaceScale) throws {
        let jobs = [BackgroundJob.Kind.shell, .monitor, .subagent, .agent].map {
            BackgroundJob(kind: $0, text: "work", displayLabel: "Check the results", agent: $0 == .agent ? .codex : nil)
        }
        let renderer = ImageRenderer(content: BackgroundCardView(card: BackgroundCard(jobs: jobs))
            .interfaceScale(scale).frame(width: 300).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let stride = Int((scale(Size.chip) + scale(Space.tight)) * renderer.scale)
        let top = Int(scale(Space.base) * renderer.scale) + stride
        let labelStarts = try jobs.indices.map { index in
            let y = top + index * stride
            // Past every mark's column: the vendor marks carry white ink of their own.
            let afterMark = Int((scale(Space.gap) + scale(Size.vendorMark)) * renderer.scale) + 1
            return try #require((afterMark..<bitmap.pixelsWide).first { x in
                (y..<(y + Int(scale(Size.chip) * renderer.scale))).contains { row in
                    guard let pixel = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { return false }
                    return pixel.redComponent > 0.83
                }
            })
        }
        #expect(Set(labelStarts).count == 1, "label ink starts at \(labelStarts)")
    }

    @Test(arguments: [1, 3, 5, 7], InterfaceScale.all)
    func itGrowsToFiveSingleLineJobsBeforeScrolling(count: Int, scale: InterfaceScale) {
        let jobs = (0..<count).map { BackgroundJob(kind: .shell, text: "command-\($0)") }
        let size = NSHostingController(rootView: BackgroundCardView(card: BackgroundCard(jobs: jobs)).interfaceScale(scale))
            .sizeThatFits(in: CGSize(width: 300, height: 1000))
        let rows = CGFloat(min(count, 5))
        let height = 2 * scale(Space.base) + scale(Size.chip) + rows * (scale(Size.chip) + scale(Space.tight))
        #expect(size == CGSize(width: 300, height: height))
    }

    /// Open, the card covers the row and does not grow it, however many jobs it lists.
    @Test(arguments: [1, 3], [TaskStatus.background, .working, .needsInput])
    func theOpenCardLeavesTheRowItsSize(jobs: Int, status: TaskStatus) async throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        let task = TaskItem.make(project: UUID(), title: "FE-1783 Dependency updates: patch", branch: "feat/fe-1783",
            worktreePath: "/wt", model: "sonnet", createdAt: Date(), windowId: "w-1")
        let row = TaskRow(id: task.id, title: task.title, jiraKey: "FE-1783", jiraUrl: nil, mr: nil,
                          branch: BranchLabel(name: task.branch, extra: 0, drifted: false, detail: ""),
                          avatars: AvatarGroup(marks: [.claude], overflow: 0), status: status,
                          background: Array([tests, server, ci].prefix(jobs)), mark: .status(status))
        let closed = NSHostingController(rootView: TaskRowView(row: row, controller: controller))
            .sizeThatFits(in: CGSize(width: 320, height: 400))
        let hover = BackgroundCardHover(sleep: { _ in })
        hover.mark(true)
        await settle()
        let open = NSHostingController(rootView: TaskRowView(row: row, controller: controller)
            .environment(\.seededHover, SeededHover(backgroundCard: hover)))
            .sizeThatFits(in: CGSize(width: 320, height: 400))
        #expect(hover.isOpen)
        #expect(open == closed, "open \(open) vs closed \(closed)")
    }

    // -- the signal card (step 11) ---------------------------------------------------

    /// A row as `SidebarModel.taskRow` and `presentingOperator` would give it, its `status` and Operator `line`.
    private func row(_ id: UUID, status: TaskStatus = .working, line: OperatorLine? = nil) -> TaskRow {
        TaskRow(id: id, title: "Work", jiraKey: nil, jiraUrl: nil, mr: nil, branch: .none,
                avatars: AvatarGroup(marks: [.claude], overflow: 0), status: status, operatorLine: line)
    }

    private func card(_ world: SignalWorld, _ id: UUID, status: TaskStatus = .working, line: OperatorLine? = nil) throws -> SignalCard {
        let task = try #require(world.state.task(id: id))
        return try #require(SignalCard.make(task: task, row: row(id, status: status, line: line), state: world.state))
    }

    /// The Operator's task: its heading and one step are its signal, and its last line the Operator's act, or what its
    /// line says, with the line's whole sentence as help.
    @Test func anOperatorTasksCardSaysItsActOrItsLine() throws {
        var world = SignalWorld()
        let signal = world.signal(name: "Plan tickets")
        let id = world.workingTask(signal: signal)
        let acting = try card(world, id, line: OperatorLine("Operator answering its worker", look: .acting))
        #expect(acting.heading == "Plan tickets")
        #expect(acting.steps == [SignalCard.Step(name: "Plan tickets", at: world.now, isCurrent: true)])
        #expect(acting.current == SignalCard.Current(text: "Operator answering its worker"))
        let waiting = try card(world, id, status: .waiting, line: OperatorLine("status = Done", tooltip: "Waits until: status = Done"))
        #expect(waiting.current == SignalCard.Current(text: "status = Done", help: "Waits until: status = Done"))
        #expect(try card(world, id, status: .needsInput).current.text == "Needs input", "a worker asking has no line")
        let mine = try #require(world.state.task(id: id).map { task -> TaskItem in var task = task; task.signalTask = nil; return task })
        #expect(SignalCard.make(task: mine, row: row(id), state: world.state) == nil, "a task you made has no card")
    }

    /// A project signal's task in each state: its prompt owed with no window, owed to a worker in its window (held, the
    /// helper's refusal as help), at work, and done, kept or archived, with why an archive did not happen.
    @Test func aProjectTasksCardSaysWhatItsWorkWaitsFor() throws {
        var world = SignalWorld()
        let signal = world.projectSignal(name: "Reviews for me", then: .archive)
        let id = world.markedTask(signal: signal)
        let index = try #require(world.state.tasks.firstIndex { $0.id == id })
        let item = try #require(world.state.tasks[index].signalOrigin?.item), now = world.now

        world.state.tasks[index].signalOrigin?.owed = OwedPrompt(text: "/review", at: now, kind: .launch)
        world.state.tasks[index].windowId = nil
        #expect(try card(world, id, status: .idle).current == SignalCard.Current(text: "waiting for your pause to open its window"))

        world.state.tasks[index].windowId = "task-window"
        world.state.tasks[index].signalOrigin?.owed = OwedPrompt(text: "/review", at: now, kind: .delivery)
        #expect(try card(world, id, status: .done).current == SignalCard.Current(text: "waiting for its worker to be idle"))
        world.state.signalSeen = [SignalSeen(signal: signal, item: item, disposition: .skipped, at: world.now,
                                             reason: "Its prompt couldn’t be typed: the session is read-only.")]
        #expect(try card(world, id, status: .done).current
                == SignalCard.Current(text: "waiting for its worker to be idle", help: "Its prompt couldn’t be typed: the session is read-only."))

        world.state.tasks[index].signalOrigin?.owed = nil
        #expect(try card(world, id, status: .working).current == SignalCard.Current(text: "Working"))
        #expect(try card(world, id, status: .needsInput).current == SignalCard.Current(text: "Needs input"))

        world.state.tasks[index].signalOrigin?.doneAt = now
        #expect(try card(world, id, status: .done).current == SignalCard.Current(text: "Done · archived"))
        world.state.tasks[index].signalOrigin?.thenNote = "Its worktree has unsaved changes."
        #expect(try card(world, id, status: .done).current
                == SignalCard.Current(text: "Done · kept", help: "Its worktree has unsaved changes."))
        world.state.signals[0].finish.then = .keep
        world.state.tasks[index].signalOrigin?.thenNote = nil
        #expect(try card(world, id, status: .done).current == SignalCard.Current(text: "Done · kept"))
    }

    /// A chain of three, oldest first, each with when, the earlier ones not current; a signal since removed is named
    /// as removed, in the chain and as the heading; a task taken over keeps its chain and says its status.
    @Test func aChainOfThreeAndARemovedSignal() throws {
        var world = SignalWorld()
        let triage = world.signal(name: "Triage"), plan = world.signal(name: "Plan tickets")
        let reviews = world.projectSignal(name: "Reviews for me")
        let id = world.markedTask(signal: reviews)
        let index = try #require(world.state.tasks.firstIndex { $0.id == id }), now = world.now
        world.state.tasks[index].signalOrigin?.earlier = [SignalStep(signal: triage, name: "Triage then", at: now - 7200),
                                                         SignalStep(signal: plan, name: "Plan tickets", at: now - 3600)]
        world.state.removeSignal(id: triage)
        let chain = try card(world, id)
        #expect(chain.heading == "Reviews for me")
        #expect(chain.steps == [SignalCard.Step(name: "Triage then (removed)", at: world.now - 7200, isCurrent: false),
                                SignalCard.Step(name: "Plan tickets", at: world.now - 3600, isCurrent: false),
                                SignalCard.Step(name: "Reviews for me", at: world.now, isCurrent: true)])
        world.state.removeSignal(id: reviews)
        #expect(try card(world, id).heading == "Reviews for me (removed)")

        let held = world.workingTask(signal: plan)
        world.state.takeOver(held)
        let takenOver = try card(world, held, status: .idle)
        #expect(takenOver.heading == "Plan tickets" && takenOver.steps.count == 1)
        #expect(takenOver.current == SignalCard.Current(text: "Idle"))
    }

    @Test func aStepSaysWhenItsSignalStartedOnTheTask() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_773_230_400)  // Wednesday 11 Mar 2026, 12:00 UTC
        #expect(SignalCard.when(now - 300, now: now, calendar: calendar) == "11:55")
        #expect(SignalCard.when(now - 86_400, now: now, calendar: calendar) == "Tue 12:00")
        #expect(SignalCard.when(now - 6 * 86_400, now: now, calendar: calendar) == "Thu 12:00")
        #expect(SignalCard.when(now - 7 * 86_400, now: now, calendar: calendar) == "4 Mar")
    }

    /// The disc's hover is a second `BackgroundCardHover`, on the same delays: resting on the disc opens its card after
    /// `openDelay` and leaves the trailing mark's alone; leaving both closes it after `closeDelay`.
    @Test func theDiscsHoverOpensAndClosesOnItsOwnDelays() async {
        let slept = SleepLog()
        let disc = BackgroundCardHover(sleep: { await slept.record($0) }), mark = BackgroundCardHover(sleep: { await slept.record($0) })
        disc.mark(true)
        await settle()
        #expect(disc.isOpen && !mark.isOpen)
        disc.mark(false)
        disc.card(true)
        await settle()
        #expect(disc.isOpen, "crossing to the card keeps it")
        disc.card(false)
        await settle()
        #expect(!disc.isOpen && !mark.isOpen)
        let durations = await slept.durations
        #expect(durations.first == BackgroundCardHover.openDelay && durations.last == BackgroundCardHover.closeDelay)
        #expect(Set(durations) == [BackgroundCardHover.openDelay, BackgroundCardHover.closeDelay])
    }

    private actor SleepLog {
        var durations: [Duration] = []
        func record(_ duration: Duration) { durations.append(duration) }
    }

    /// A task row a signal started opens its card from the disc's seeded hover, over the row without growing it; a row
    /// you made has no disc and opens nothing.
    @Test(arguments: [false, true])
    func theDiscOpensTheSignalCardOverItsRow(started: Bool) async throws {
        var world = SignalWorld()
        let signal = world.projectSignal(name: "Reviews for me")
        let id = world.markedTask(signal: signal)
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        let state = world.state
        controller.workspace.mutate { $0 = state }
        if !started { controller.workspace.mutate { $0.tasks[0].signalOrigin = nil } }
        let row = try #require(controller.rows.sections.flatMap(\.tasks).first { $0.id == id })
        #expect((row.startedBySignal != nil) == started)
        let hover = BackgroundCardHover(isOpen: true)
        func image(_ open: Bool) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: TaskRowView(row: row, controller: controller)
                .environment(\.seededHover, open ? SeededHover(signalCard: hover) : nil)
                .environment(\.motionStill, .snapshot).frame(width: 320, height: 160, alignment: .top).background(Palette.sidebar))
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let closed = try image(false), opened = try image(true)
        var changed = 0
        for y in 0..<closed.pixelsHigh {
            for x in 0..<closed.pixelsWide {
                let a = try #require(closed.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let b = try #require(opened.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) > 0.1 { changed += 1 }
            }
        }
        #expect(started ? changed > 1000 : changed == 0, "\(changed) pixels")
        let size = { (open: Bool) in
            NSHostingController(rootView: TaskRowView(row: row, controller: controller)
                .environment(\.seededHover, open ? SeededHover(signalCard: hover) : nil))
                .sizeThatFits(in: CGSize(width: 320, height: 400))
        }
        #expect(size(true) == size(false), "the open card leaves the row its size")
    }
}
