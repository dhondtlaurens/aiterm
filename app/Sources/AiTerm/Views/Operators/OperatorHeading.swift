import SwiftUI
import AiTermUI
import AiTermCore

/// `OPERATOR`, above `PROJECTS` (spec §3, §13): a `SidebarHeading` whose "+" — an `AddMenu` with New
/// Broadcast… — is the one way to start a broadcast, so it is drawn with no broadcast at all. While one
/// exists the "+" is absent and the broadcast row sits under the heading: one broadcast at a time.
struct OperatorHeading: View {
    let controller: AppController
    @Environment(\.interfaceScale) private var scale

    /// Whether the heading offers New Broadcast…: only while there is no broadcast.
    static func offersNewBroadcast(_ broadcast: BroadcastRow?) -> Bool { broadcast == nil }

    var body: some View {
        HStack {
            SidebarHeading("Operator")
            Spacer()
            if Self.offersNewBroadcast(controller.rows.broadcast) {
                AddMenu(help: "New broadcast", enabled: controller.canChangeWorkspace) {
                    OperatorMenuButtons(items: OperatorMenus.headingPlus) { _ in controller.presentNewOperation() }
                }
            }
        }
        // `PROJECTS`' anatomy (`SidebarHeader`), so the two headings line up with and without the "+".
        .frame(height: scale(Size.menuRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
    }
}
