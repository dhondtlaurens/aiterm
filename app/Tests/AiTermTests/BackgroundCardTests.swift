import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm

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
        #expect(BackgroundCard.glyph(.shell) == "apple.terminal")
        #expect(BackgroundCard.glyph(.monitor) == "eye" && BackgroundCard.glyph(.task) == "eye")
    }

    /// The seeded hover drives the production row/overlay. Before the active-status gate is
    /// removed, hovering changes no pixel of a working or needs-input row.
    @Test(arguments: [TaskStatus.background, .working, .needsInput], [false, true])
    func hoveringTheMarkOpensTheExistingCard(status: TaskStatus, queued: Bool) async throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        let task = TaskItem(id: UUID(), projectId: UUID(), title: "A task with background work", branch: "feat/work",
                            worktreePath: "/wt", baseBranch: "main", jira: nil, agent: .claude, model: "sonnet", reasoning: nil,
                            firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w")
        let row = TaskRow(id: task.id, title: task.title, jiraKey: nil, jiraUrl: nil, mr: nil, branch: .none,
                          avatars: AvatarGroup(marks: [.claude], overflow: 0), status: status, queued: queued, background: [tests, ci])
        let changed = try await cardSurfaceChange(TaskRowView(row: row, task: task, controller: controller))
        #expect(queued ? changed == 0 : changed > 1000, "the same card opens except on a queued mark: \(changed) pixels")
    }

    @Test(arguments: [TaskStatus.background, .working, .needsInput], [false, true])
    func terminalRowsUseTheSameCardAndEmptyListsOfferNone(status: TaskStatus, empty: Bool) async throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        defer { controller.shutdown() }
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil,
                              addedAt: Date(), collapsed: false)
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
        #expect(TaskRowMark(status: .background, line: ended, removing: false) == .status(.background))
        #expect(TaskRowMark(status: .done, line: ended, removing: false) == .ended)
    }

    /// Offered its row's pill up to the mark, the card fills it however many jobs it lists, the rest scrolling.
    @Test func itFillsWhatItIsOffered() {
        func size(_ jobs: [BackgroundJob]) -> CGSize {
            NSHostingController(rootView: BackgroundCardView(card: BackgroundCard(jobs: jobs)))
                .sizeThatFits(in: CGSize(width: 300, height: Size.row))
        }
        #expect(size([tests]) == CGSize(width: 300, height: Size.row))
        #expect(size([tests, server, ci]) == CGSize(width: 300, height: Size.row))
    }

    /// Open, the card covers the row and does not grow it, however many jobs it lists.
    @Test(arguments: [1, 3], [TaskStatus.background, .working, .needsInput])
    func theOpenCardLeavesTheRowItsSize(jobs: Int, status: TaskStatus) async throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        let task = TaskItem(id: UUID(), projectId: UUID(), title: "FE-1783 Dependency updates: patch", branch: "feat/fe-1783",
                            worktreePath: "/wt", baseBranch: "main", jira: nil, agent: .claude, model: "sonnet", reasoning: nil,
                            firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w-1")
        let row = TaskRow(id: task.id, title: task.title, jiraKey: "FE-1783", jiraUrl: nil, mr: nil,
                          branch: BranchLabel(name: task.branch, extra: 0, drifted: false, detail: ""),
                          avatars: AvatarGroup(marks: [.claude], overflow: 0), status: status,
                          background: Array([tests, server, ci].prefix(jobs)))
        let closed = NSHostingController(rootView: TaskRowView(row: row, task: task, controller: controller))
            .sizeThatFits(in: CGSize(width: 320, height: 400))
        let hover = BackgroundCardHover(sleep: { _ in })
        hover.mark(true)
        await settle()
        let open = NSHostingController(rootView: TaskRowView(row: row, task: task, controller: controller)
            .environment(\.seededHover, SeededHover(backgroundCard: hover)))
            .sizeThatFits(in: CGSize(width: 320, height: 400))
        #expect(hover.isOpen)
        #expect(open == closed, "open \(open) vs closed \(closed)")
    }
}
