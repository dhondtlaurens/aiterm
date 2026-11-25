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
        #expect(BackgroundCard.glyph(tests) == "apple.terminal")
        #expect(BackgroundCard.glyph(ci) == "waveform.path.ecg"
                && BackgroundCard.glyph(BackgroundJob(kind: .task, text: "Workflow")) == "waveform.path.ecg")
        #expect(BackgroundCard.glyph(BackgroundJob(kind: .subagent, text: "Review the fix")) == "sparkle")
        // An idle teammate sleeps until it is messaged, whatever kind it was sent as.
        #expect(BackgroundCard.glyph(BackgroundJob(kind: .subagent, text: "Build skin A", idle: true)) == "zzz")
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
        #expect(card.lines.first == .idleHeading && card.lines.count == 9)
    }

    /// Running work keeps its count and comes first; idle teammates follow under their own heading.
    @Test func idleTeammatesFollowTheRunningWorkWithoutCounting() {
        let reviewer = BackgroundJob(kind: .task, text: "Review the fix", idle: true)
        let card = BackgroundCard(jobs: [reviewer, tests, server])
        #expect(card.heading == "Background work · 2 jobs")
        #expect(card.lines == [.job(tests), .job(server), .idleHeading, .job(reviewer)])
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
}
