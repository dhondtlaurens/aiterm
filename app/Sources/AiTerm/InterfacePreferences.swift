import Foundation
import AiTermCore

/// The Interface tab's preferences as the running app holds them: read once from `defaults` and
/// saved there on every write, so a caller changes a preference with one assignment. What a
/// change does elsewhere — the sidebar window resizing, iTerm2's background — is its caller's.
@MainActor
@Observable
final class InterfacePreferences {
    /// Also where Backpack Mode keeps its settings, so a test's scratch preferences cover both.
    @ObservationIgnored let defaults: UserDefaults

    /// Which sidebar badges print their detail.
    var badgeDetails: BadgeDetails {
        didSet { InterfaceSettings.saveBadgeDetails(badgeDetails, defaults: defaults) }
    }
    /// How large the sidebar is drawn.
    var interfaceSize: InterfaceSize {
        didSet { InterfaceSettings.saveInterfaceSize(interfaceSize, defaults: defaults) }
    }
    /// Whether iTerm2's windows take the sidebar's background.
    var matchItermBackground: Bool {
        didSet { InterfaceSettings.saveMatchItermBackground(matchItermBackground, defaults: defaults) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        badgeDetails = InterfaceSettings.badgeDetails(defaults: defaults)
        interfaceSize = InterfaceSettings.interfaceSize(defaults: defaults)
        matchItermBackground = InterfaceSettings.matchItermBackground(defaults: defaults)
    }
}
