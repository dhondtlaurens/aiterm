import SwiftUI
import AiTermUI
import AiTermCore

/// The broadcast's sheet as the sidebar presents it, from one of two sources. Live: the projection's board
/// (`SidebarProjection.board`), derived again with the rows and written only when it differs, so a card moves right
/// while the sheet is open and every card sits in Done once every task is done, while a change it draws nothing of
/// redraws nothing; a failed reopening behind it (`OperatorController.reopenFailed`) puts its Notice in the footer, and
/// its Activity follows the run's log: read as the sheet opens and again after each line the Operator's calls write
/// (`OperatorController.activityGeneration(of:)`). Shelved, opened from the Shelf (`SheetKind.shelvedBroadcast`): an
/// ended broadcast's board as it ended (`BroadcastBoard.shelved`), cards that open nothing, Close alone, opening on
/// Summary, its Activity read once as the sheet opens, since an ended broadcast's log no longer grows. A broadcast
/// ended (live) or removed (shelved) meanwhile closes it. The sheet is compared by what it draws alone, its actions
/// left out.
struct BroadcastBoardHost: View {
    /// Where the board comes from.
    enum Source { case live, shelved }

    let runId: UUID
    let source: Source
    let controller: AppController
    /// Made with the first `init` of a presentation and kept across redraws.
    private var _feed: State<ActivityFeed>
    private var feed: ActivityFeed { _feed.wrappedValue }
    @Environment(\.dismiss) private var dismiss

    init(runId: UUID, source: Source = .live, controller: AppController) {
        self.runId = runId; self.source = source; self.controller = controller
        _feed = State(initialValue: ActivityFeed(runFolder: controller.operatorController.folder(of: runId)))
    }

    var body: some View {
        Group {
            if let sheet {
                sheet.equatable()
            } else {
                Color.clear.frame(width: Sheet.width, height: Size.control).onAppear { dismiss.afterThisEvent() }
            }
        }
        .task(id: activityGeneration) { await feed.refresh() }
    }

    /// The sheet for the board its source has now; nil once there is none to show.
    private var sheet: BroadcastBoardSheet? {
        switch source {
        case .live:
            guard let board = controller.rows.board, board.runId == runId else { return nil }
            return BroadcastBoardSheet(board: board, reopenFailed: controller.operatorController.reopenFailed.contains(runId),
                                       actions: controller.boardActions(for: runId, dismiss: { dismiss.afterThisEvent() }), activity: feed)
        case .shelved:
            guard let run = controller.state.run(id: runId), run.hasEnded else { return nil }
            return BroadcastBoardSheet(board: .shelved(run: run, state: controller.state), reopenFailed: false, actions: BoardActions(),
                                       activity: feed)
        }
    }

    /// What reads the Activity again: each line the Operator's calls write, for a live board; nothing after the first
    /// read, for a shelved one.
    private var activityGeneration: Int {
        source == .live ? controller.operatorController.activityGeneration(of: runId) : 0
    }
}
