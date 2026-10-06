import SwiftUI

/// A vertical stack whose earlier children draw over its later ones.
///
/// Anything that hangs off a child — a picker's results, the prompt's completion popup — extends
/// past that child over the children after it, and a plain `VStack` draws a later sibling on top
/// of what hangs out of an earlier one. Ordering by position makes that the rule rather than a
/// `zIndex` each caller must remember at every level of the sheet. Layout is a leading `VStack`'s
/// own: a form's rows all start at its edge, so no other alignment is offered.
public struct FrontToBackStack<Content: View>: View {
    let spacing: CGFloat?
    let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    subview.zIndex(Double(subviews.count - index))
                }
            }
        }
    }
}
