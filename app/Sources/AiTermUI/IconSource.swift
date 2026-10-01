import SwiftUI
import AppKit

/// One way to name any mark AiTerm draws, so a component that shows an icon does not care which
/// kind it is. `Icon` and `Badge` both take one of these.
public enum IconSource: Sendable, Equatable {
    /// An SF Symbol, by name.
    case symbol(String)
    /// A single-colour vendor mark, in its brand colour unless tinted. Adding a vendor is one
    /// `Brand`, usable everywhere.
    case brand(Brand)
    /// A full-colour SVG document, drawn as it is: it has no one colour a tint could replace, so a
    /// tint reaches only `fallback` — what is drawn instead if the document will not decode.
    indirect case artwork(svg: String, fallback: IconSource)
}

public extension IconSource {
    /// GitLab's four-colour tanuki, drawn for a light ground; the single-colour mark if it will not
    /// decode.
    static let gitlabTanuki = IconSource.artwork(svg: Logos.gitlabFourColourSVG, fallback: .brand(Palette.gitlab))
    /// Pi's white badge, drawn for `VendorMark`'s black disc.
    static let piBadge = IconSource.artwork(svg: Logos.piBadgeSVG, fallback: .symbol("square.grid.2x2.fill"))
}

/// Draws an `IconSource` at a size, optionally overriding its ink. A brand or an artwork fills a
/// `size` × `size` box; a symbol keeps its glyph's own width at that point size, which is what the
/// Settings check chips are measured by.
///
/// A brand keeps its vendor colour unless `tint` overrides it — which is what a selected row does,
/// where a brand colour on the accent would read as a mistake. A symbol with no tint takes the ink
/// of the surface it sits on, so it turns white on the accent by itself.
public struct Icon: View {
    private let source: IconSource
    private let size: CGFloat
    private let tint: Color?
    @Environment(\.surface) private var surface

    public init(_ source: IconSource, size: CGFloat, tint: Color? = nil) {
        self.source = source
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        switch source {
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(tint ?? surface.ink)
        case let .brand(brand):
            LogoGlyph(path: brand.path,
                      fill: tint.map(Self.hexString) ?? brand.hex,
                      fallback: brand.fallbackSymbol,
                      size: size,
                      evenOdd: brand.evenOdd)
        case let .artwork(svg, fallback):
            if let image = Logos.image(svg: svg) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                    .accessibilityHidden(true)
            } else {
                Icon(fallback, size: size, tint: tint)
            }
        }
    }

    /// `LogoGlyph` builds an SVG document, so it needs the fill as text rather than a `Color`.
    ///
    /// Resolved under a forced `.darkAqua` appearance — AiTerm is dark-only, and inheriting the
    /// process appearance instead would make the glyph's fill depend on a system setting the app
    /// doesn't otherwise honour.
    ///
    /// `app/Tests/AiTermUITests/ColorProbe.swift` resolves colours the same way, for tests rather
    /// than for an SVG fill. The two are kept separate deliberately (production vs. test-only), but
    /// they duplicate this exact `.darkAqua`/sRGB dance — if one changes, check the other.
    @MainActor
    private static func hexString(_ color: Color) -> String {
        var hex = "#000000"
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            hex = String(format: "#%02X%02X%02X",
                         Int((srgb.redComponent * 255).rounded()),
                         Int((srgb.greenComponent * 255).rounded()),
                         Int((srgb.blueComponent * 255).rounded()))
        }
        return hex
    }
}
