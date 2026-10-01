import Foundation

/// Which sidebar badges print their detail beside their mark. A badge whose detail is off keeps its
/// mark, its click and its tooltip; it only stops spending width on the text. All on by default.
public struct BadgeDetails: Equatable, Sendable {
    /// The project key on a project header, `SHOP`.
    public var jiraProject: Bool
    /// The ticket key on a task row, `SHOP-412`.
    public var jiraTicket: Bool
    /// The merge-request number on a review row, `!87`.
    public var mergeRequest: Bool
    /// The lines changed on the VS Code badge, `+12 −3`.
    public var diff: Bool

    public init(jiraProject: Bool = true, jiraTicket: Bool = true, mergeRequest: Bool = true, diff: Bool = true) {
        self.jiraProject = jiraProject
        self.jiraTicket = jiraTicket
        self.mergeRequest = mergeRequest
        self.diff = diff
    }
}

/// How large the sidebar is drawn: Apple's own sizes, or one of two steps up. Only the
/// preference and its order live here; the factor each step draws at is the design system's
/// (`InterfaceScale`, in `AiTermUI`).
public enum InterfaceSize: String, CaseIterable, Sendable {
    case standard, large, extraLarge

    public var title: String {
        switch self {
        case .standard: "Actual Size"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    /// The next step up, or `nil` at the largest.
    public var bigger: InterfaceSize? { step(1) }
    /// The next step down, or `nil` at Actual Size.
    public var smaller: InterfaceSize? { step(-1) }

    private func step(_ delta: Int) -> InterfaceSize? {
        let all = Self.allCases, index = all.firstIndex(of: self)! + delta
        return all.indices.contains(index) ? all[index] : nil
    }
}

/// Preferences for the terminal windows AiTerm creates and the sidebar that drives them.
///
/// These live in `UserDefaults`: unlike credentials, they are not secrets and should be available
/// before the daemon has started. Every call names its `defaults` — the app's `InterfacePreferences`
/// is the one caller — so a test never reads or writes the developer's own by omission.
public enum InterfaceSettings {
    private static let matchItermBackgroundKey = "matchItermBackground"
    private static let interfaceSizeKey = "interfaceSize"
    private static let badgeDetailKeys = (jiraProject: "badgeDetail.jiraProject", jiraTicket: "badgeDetail.jiraTicket",
                                          mergeRequest: "badgeDetail.mergeRequest", diff: "badgeDetail.diff")

    /// Off by default so installing AiTerm never changes an existing iTerm2 appearance unasked.
    public static func matchItermBackground(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: matchItermBackgroundKey)
    }

    public static func saveMatchItermBackground(_ enabled: Bool, defaults: UserDefaults) {
        defaults.set(enabled, forKey: matchItermBackgroundKey)
    }

    /// A key that was never written reads as on, so the sidebar looks as it always has until a
    /// badge is turned off.
    public static func badgeDetails(defaults: UserDefaults) -> BadgeDetails {
        func read(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        return BadgeDetails(jiraProject: read(badgeDetailKeys.jiraProject), jiraTicket: read(badgeDetailKeys.jiraTicket),
                            mergeRequest: read(badgeDetailKeys.mergeRequest), diff: read(badgeDetailKeys.diff))
    }

    /// Default until changed. A value this version does not know also reads as Default.
    public static func interfaceSize(defaults: UserDefaults) -> InterfaceSize {
        defaults.string(forKey: interfaceSizeKey).flatMap(InterfaceSize.init(rawValue:)) ?? .standard
    }

    public static func saveInterfaceSize(_ size: InterfaceSize, defaults: UserDefaults) {
        defaults.set(size.rawValue, forKey: interfaceSizeKey)
    }

    public static func saveBadgeDetails(_ details: BadgeDetails, defaults: UserDefaults) {
        defaults.set(details.jiraProject, forKey: badgeDetailKeys.jiraProject)
        defaults.set(details.jiraTicket, forKey: badgeDetailKeys.jiraTicket)
        defaults.set(details.mergeRequest, forKey: badgeDetailKeys.mergeRequest)
        defaults.set(details.diff, forKey: badgeDetailKeys.diff)
    }
}
