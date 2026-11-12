import SwiftUI
import AiTermUI

#if DEBUG
/// The sidebar fixture renderers' column. Callers keep their own surface declaration,
/// height, vertical fitting and scaled geometry; this wrapper adds no scale of its own.
struct SnapshotColumn<Content: View>: View {
    var width: CGFloat = Size.sidebarWidth + 2 * Space.inset
    var height: CGFloat? = nil
    var spacing: CGFloat = Space.hairline
    var horizontalInset: CGFloat = Space.inset
    var verticalInset: CGFloat = 0
    var fitsVertically = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if fitsVertically { column.fixedSize(horizontal: false, vertical: true) }
            else { column }
        }
        .background(Palette.sidebar)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(.horizontal, horizontalInset).padding(.vertical, verticalInset)
            .frame(width: width, height: height)
    }
}
#endif
