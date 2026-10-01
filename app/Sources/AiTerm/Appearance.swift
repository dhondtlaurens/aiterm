import AppKit

/// AiTerm supports dark appearance only. Applying it to the application makes windows,
/// sheets, native controls, and startup alerts inherit the same appearance.
@MainActor
enum Appearance {
    static func apply(defaults: UserDefaults = .standard) {
        // Discard the retired preference on upgrade; appearance is no longer user-configurable.
        defaults.removeObject(forKey: "appearance")
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }
}
