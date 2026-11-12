import SwiftUI
import AiTermUI

/// The stepped sheets' frame, independent of their models, loading and navigation rules.
/// Earlier content keeps its dropdowns above the command and destination lines after it.
struct SteppedSheetFrame<Content: View, Footer: View>: View {
    let title: String
    let step: Int
    let stepNames: [String]
    let onBackgroundTap: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        SheetLayout(title: title, height: Sheet.height, onBackgroundTap: onBackgroundTap) {
            StepBar(step: step, names: stepNames)
        } content: {
            FrontToBackStack(spacing: Space.block, content: content)
        } footer: {
            footer()
        }
    }
}
