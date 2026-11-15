import SwiftUI
import AiTermUI

/// The last block of every creation sheet: what its primary button does with the current picks.
struct CreationClosingBlock<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug, content: content)
            .padding(Space.inset).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.well))
    }
}
