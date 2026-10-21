import SwiftUI
import AiTermUI
import AiTermCore

/// The broadcast's sheet as the sidebar presents it: the projection's board (`SidebarProjection.board`), derived
/// again with the rows and written only when it differs, so a card moves right while the sheet is open and every
/// card sits in Done once every task is done, while a change it draws nothing of redraws nothing. A broadcast
/// ended meanwhile closes it. A failed reopening behind it (`OperatorController.reopenFailed`) puts its Notice in
/// the footer. Its Activity follows the run's log: read as the sheet opens and again after each line the
/// Operator's calls write (`OperatorController.activityGeneration(of:)`). The sheet is compared by what it draws
/// alone, its actions left out.
struct BroadcastBoardHost: View {
    let runId: UUID
    let controller: AppController
    /// Made with the first `init` of a presentation and kept across redraws.
    private var _feed: State<ActivityFeed>
    private var feed: ActivityFeed { _feed.wrappedValue }
    @Environment(\.dismiss) private var dismiss

    init(runId: UUID, controller: AppController) {
        self.runId = runId; self.controller = controller
        _feed = State(initialValue: ActivityFeed(runFolder: controller.operatorController.folder(of: runId)))
    }

    var body: some View {
        Group {
            if let board = controller.rows.board, board.runId == runId {
                BroadcastBoardSheet(board: board, reopenFailed: controller.operatorController.reopenFailed.contains(runId),
                                    actions: controller.boardActions(for: runId, dismiss: { dismiss.afterThisEvent() }), activity: feed)
                    .equatable()
            } else {
                Color.clear.frame(width: Sheet.width, height: Size.control).onAppear { dismiss.afterThisEvent() }
            }
        }
        .task(id: controller.operatorController.activityGeneration(of: runId)) { await feed.refresh() }
    }
}

/// An ended broadcast's sheet, opened from the Shelf (`SheetKind.shelvedBroadcast`): its board as it ended
/// (`BroadcastBoard.shelved`) — cards that open nothing, Close alone — opening on Summary. Its Activity is the
/// run's log read once as the sheet opens: an ended broadcast's log no longer grows. A broadcast removed
/// meanwhile closes it.
struct ShelvedBroadcastHost: View {
    let runId: UUID
    let controller: AppController
    /// Made with the first `init` of a presentation and kept across redraws.
    private var _feed: State<ActivityFeed>
    private var feed: ActivityFeed { _feed.wrappedValue }
    @Environment(\.dismiss) private var dismiss

    init(runId: UUID, controller: AppController) {
        self.runId = runId; self.controller = controller
        _feed = State(initialValue: ActivityFeed(runFolder: controller.operatorController.folder(of: runId)))
    }

    var body: some View {
        Group {
            if let run = controller.state.run(id: runId), run.hasEnded {
                BroadcastBoardSheet(board: .shelved(run: run, state: controller.state), reopenFailed: false, actions: BoardActions(),
                                    activity: feed)
                    .equatable()
            } else {
                Color.clear.frame(width: Sheet.width, height: Size.control).onAppear { dismiss.afterThisEvent() }
            }
        }
        .task { await feed.refresh() }
    }
}
