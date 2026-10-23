import SwiftUI

/// An SF Symbol in the vendor discs’ recipe: mark ink on mark paper.
/// The caller scales the size it passes.
public struct SymbolMark: View {
    let symbol: String
    let size: CGFloat
    /// The glyph's optical size inside the disc. A symbol's ink box is not a logo's, so `LogoFit`
    /// does not apply, and no `Size` step fits.
    private static let glyphRatio: CGFloat = 0.5

    public init(symbol: String, size: CGFloat) {
        self.symbol = symbol
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(Palette.markPaper)
            Icon(.symbol(symbol), size: size * Self.glyphRatio, tint: Palette.markInk)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
