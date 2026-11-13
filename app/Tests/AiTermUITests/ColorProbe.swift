import SwiftUI
import AppKit
@testable import AiTermUI

/// Resolves a `Color` to plain values so a test can compare colours by their rendered result
/// rather than by identity. Every colour is resolved under a forced `.darkAqua` appearance — AiTerm
/// is dark-only, and inheriting the process appearance instead would make a test's outcome depend
/// on the machine's system setting — or under the appearance a test names: Increase Contrast's
/// `.accessibilityHighContrastDarkAqua`.
///
/// Test-only: this is not part of the design system's public surface, only a way for
/// `SurfaceTests` and `PaletteDistinctionTests` to ask "what colour does this actually resolve to."
///
@MainActor
enum ColorProbe {
    /// `color` in sRGB, resolved under the appearance `name` names. AppKit will not build an
    /// accessibility appearance by name, so Increase Contrast's is resolved through
    /// `IncreaseContrast.forced`, over the dark appearance it heightens.
    static func resolved(_ color: Color, in name: NSAppearance.Name = .darkAqua) -> NSColor? {
        let highContrast = name == .accessibilityHighContrastDarkAqua
        let appearance = NSAppearance(named: highContrast ? .darkAqua : name) ?? NSAppearance.currentDrawing()
        var out: NSColor?
        IncreaseContrast.$forced.withValue(highContrast) {
            appearance.performAsCurrentDrawingAppearance {
                out = NSColor(color).usingColorSpace(.sRGB)
            }
        }
        return out
    }

    /// Alpha matters for the washes (`badge`, `row-hover`, `spinner-track`), which are drawn over
    /// another colour rather than replacing it.
    static func rgba(_ color: Color, in name: NSAppearance.Name = .darkAqua) -> String {
        guard let srgb = resolved(color, in: name) else { return "rgba(0, 0, 0, 1)" }
        return String(format: "rgba(%d, %d, %d, %.3f)",
                      Int((srgb.redComponent * 255).rounded()),
                      Int((srgb.greenComponent * 255).rounded()),
                      Int((srgb.blueComponent * 255).rounded()),
                      srgb.alphaComponent)
    }

    static func alpha(_ color: Color, in name: NSAppearance.Name = .darkAqua) -> Double {
        Double(resolved(color, in: name)?.alphaComponent ?? 1)
    }
}
