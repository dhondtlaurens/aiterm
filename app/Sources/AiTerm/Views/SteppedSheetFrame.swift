import SwiftUI
import AiTermUI

/// The stepped sheets' frame, independent of their models, loading and navigation rules: the title row
/// with its `SheetStepper`, one height for every step so the sheet does not jump between them — New Task's
/// and New Review's `Sheet.creationHeight`, New Broadcast's `Sheet.height` — and the footer.
/// Earlier content keeps its dropdowns above the command and destination lines after it.
struct SteppedSheetFrame<Content: View, Footer: View>: View {
    let title: String
    let height: CGFloat
    let step: Int
    let stepNames: [String]
    let onBackgroundTap: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        SheetLayout(title: title, height: .fixed(height), onBackgroundTap: onBackgroundTap) {
            SheetStepper(step: step, names: stepNames)
        } header: {
            EmptyView()
        } content: {
            FrontToBackStack(spacing: Space.block, content: content)
        } footer: {
            footer()
        }
    }
}
