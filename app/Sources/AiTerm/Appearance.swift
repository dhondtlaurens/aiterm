import AppKit

/// AiTerm supports dark appearance only. Applying it to the application makes windows,
/// sheets, native controls, and startup alerts inherit the same appearance.
@MainActor
enum Appearance {
    static func apply() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }
}
