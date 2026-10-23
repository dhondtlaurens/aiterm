import AppKit

/// AiTerm supports dark appearance only. Applying it to the application makes windows,
/// sheets, native controls, and startup alerts inherit the same appearance.
@MainActor
enum Appearance {
    static func apply(defaults: UserDefaults = .standard) {
        // Discard preferences retired by the dark-only UI and the shared Operator profile.
        for key in ["appearance", "fixer", "fixerIsOn", "modelDefaults.grok"] {
            defaults.removeObject(forKey: key)
        }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }
}
