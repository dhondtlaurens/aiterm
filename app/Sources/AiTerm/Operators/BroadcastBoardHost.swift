import SwiftUI
import AiTermUI
import AiTermCore

/// The board as the sidebar presents it: the projection's board (`SidebarProjection.board`), derived again
/// with the rows and written only when it differs, so a card moves right while the sheet is open and the
/// every card sits in Done once every task is done, while a change it draws nothing of redraws nothing.
/// A broadcast ended meanwhile closes it. A failed reopening behind it (`OperatorController.reopenFailed`)
/// puts its Notice in the footer. The sheet is compared by what it draws alone, its actions left out.
struct BroadcastBoardHost: View {
    let runId: UUID
    let controller: AppController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let board = controller.rows.board, board.runId == runId {
            BroadcastBoardSheet(board: board, reopenFailed: controller.operatorController.reopenFailed.contains(runId),
                                actions: controller.boardActions(for: runId, dismiss: { dismiss.afterThisEvent() }))
                .equatable()
        } else {
            Color.clear.frame(width: Sheet.boardWidth, height: Size.control).onAppear { dismiss.afterThisEvent() }
        }
    }
}
