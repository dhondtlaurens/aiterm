import SwiftUI
import AiTermUI
import AiTermCore

/// The board as the sidebar presents it: made again from the workspace whenever it changes, so a card
/// moves right while the sheet is open and the board becomes the debrief once every task is done; a
/// broadcast ended meanwhile closes it. A failed reopening behind it (`OperatorController.reopenFailed`)
/// puts its Notice in the footer.
struct BroadcastBoardHost: View {
    let runId: UUID
    let controller: AppController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let run = controller.rows.runs[runId], !run.hasEnded {
            let state = controller.state
            BroadcastBoardSheet(
                board: .make(run: run, state: state, acting: controller.rows.acting,
                             requests: OperatorRequests.open(run: run, state: state, prompts: [:])),
                reopenFailed: controller.operatorController.reopenFailed.contains(runId),
                actions: controller.boardActions(for: run, dismiss: { dismiss.afterThisEvent() }))
        } else {
            Color.clear.frame(width: Sheet.boardWidth, height: Size.control).onAppear { dismiss.afterThisEvent() }
        }
    }
}
