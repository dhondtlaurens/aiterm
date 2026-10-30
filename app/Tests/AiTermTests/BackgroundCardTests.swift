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

    @Test func itSaysTheTurnEndedAndCountsSeveralJobs() {
        #expect(BackgroundCard(jobs: [tests]).heading == "Turn ended · running in the background")
        #expect(BackgroundCard(jobs: [tests, server, ci]).heading == "Turn ended · 3 running in the background")
        #expect(BackgroundCard(jobs: [tests, ci]).spoken
                == "Turn ended, running in the background: scripts/test.sh all, Watch CI on !45 until the pipeline ends")
        #expect(BackgroundCard.glyph(.shell) == "apple.terminal")
        #expect(BackgroundCard.glyph(.monitor) == "eye" && BackgroundCard.glyph(.task) == "eye")
    }

    /// Lets every task the hover started run to its end.
    private func settle() async { for _ in 0..<10 { await Task.yield() } }

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
    @Test(arguments: [1, 3]) func theOpenCardLeavesTheRowItsSize(jobs: Int) async throws {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        let task = TaskItem(id: UUID(), projectId: UUID(), title: "FE-1783 Dependency updates: patch", branch: "feat/fe-1783",
                            worktreePath: "/wt", baseBranch: "main", jira: nil, agent: .claude, model: "sonnet", reasoning: nil,
                            firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w-1")
        let row = TaskRow(id: task.id, title: task.title, jiraKey: "FE-1783", jiraUrl: nil, mr: nil,
                          branch: BranchLabel(name: task.branch, extra: 0, drifted: false, detail: ""),
                          avatars: AvatarGroup(marks: [.claude], overflow: 0), status: .background,
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
