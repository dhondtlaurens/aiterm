import SwiftUI
import AppKit

/// Resolves a `Color` to plain values so a test can compare colours by their rendered result
/// rather than by identity. Every colour is resolved under a forced `.darkAqua` appearance — AiTerm
/// is dark-only, and inheriting the process appearance instead would make a test's outcome depend
/// on the machine's system setting.
///
/// Test-only: this is not part of the design system's public surface, only a way for
/// `SurfaceTests` and `PaletteDistinctionTests` to ask "what colour does this actually resolve to."
///
@MainActor
enum ColorProbe {
    /// Alpha matters for the washes (`badge`, `row-hover`, `spinner-track`), which are drawn over
    /// another colour rather than replacing it.
    static func rgba(_ color: Color) -> String {
        var out = "rgba(0, 0, 0, 1)"
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            out = String(format: "rgba(%d, %d, %d, %.3f)",
                         Int((srgb.redComponent * 255).rounded()),
                         Int((srgb.greenComponent * 255).rounded()),
                         Int((srgb.blueComponent * 255).rounded()),
                         srgb.alphaComponent)
        }
        return out
    }

    static func alpha(_ color: Color) -> Double {
        var a = 1.0
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            a = Double(NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? 1)
        }
        return a
    }
}
