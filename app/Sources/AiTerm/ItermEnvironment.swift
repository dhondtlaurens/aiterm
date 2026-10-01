import AppKit
import AiTermCore

/// What Settings learns about iTerm2 without asking the helper, read each time the card is tested.
struct ItermEnvironment: Equatable {
    var installed: Bool
    var pythonAPIEnabled: Bool

    static func current() -> ItermEnvironment {
        ItermEnvironment(
            installed: NSWorkspace.shared.urlForApplication(withBundleIdentifier: ItermPreferences.bundleIdentifier) != nil,
            pythonAPIEnabled: ItermPreferences.pythonAPIEnabled())
    }
}
