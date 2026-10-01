import Foundation

/// The line above the sidebar that says what the helper or iTerm2 is doing, in the iTerm2 card's
/// words (`ItermConnection.banner`). `.warning`, drawn amber, is iTerm2 refusing AiTerm's
/// connection; `.info`, drawn grey, is everything else — a missing helper or Python included.
public struct DaemonBanner: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case info, warning }
    public let text: String, tone: Tone

    public static func info(_ text: String) -> DaemonBanner { DaemonBanner(text: text, tone: .info) }
    public static func warning(_ text: String) -> DaemonBanner { DaemonBanner(text: text, tone: .warning) }
}
