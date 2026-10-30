import Foundation

/// Claude's user-level paths. The live value comes from the login shell, never Finder's
/// environment. Defaults and test homes do not start a shell.
public struct ClaudeConfig: Sendable {
    private let value: @Sendable () -> String?

    public init(_ value: String? = nil) { self.value = { value } }

    private init(value: @escaping @Sendable () -> String?) { self.value = value }

    /// Resolved lazily off the main actor by the first reader, then fixed for this app launch.
    public static let loginShell = ClaudeConfig(value: { loginValue })
    private static let loginValue = LoginShellLocator.shared.current()?.claudeConfigDirectory

    private var override: String? { value().nonEmpty }

    public func directory(home: URL) -> URL {
        guard let path = override else { return home.appendingPathComponent(".claude") }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: home).standardizedFileURL
    }

    func settingsURL(home: URL) -> URL { directory(home: home).appendingPathComponent("settings.json") }

    /// Claude moves its global state inside an explicitly configured directory, even if that
    /// directory is ~/.claude. Without an override the historical ~/.claude.json remains in use.
    public func globalJSON(home: URL) -> URL {
        (override == nil ? home : directory(home: home)).appendingPathComponent(".claude.json")
    }
}
