import Foundation

/// How far the chain from AiTerm to iTerm2 reaches: the bundled Python, the helper it runs, the
/// socket to that helper, and the helper's API connection to iTerm2. The sidebar banner and the
/// iTerm settings card both read this one value, so they cannot disagree about what is broken.
public enum ItermConnection: Equatable, Sendable {
    case starting
    case helperMissing
    case pythonMissing
    /// The helper has exited more than once; the message is its last exit.
    case helperFailing(String)
    case helperMismatch
    /// The helper process is up but its socket is not answering yet.
    case helperUnreachable
    /// The helper is answering and waiting for its API connection to iTerm2.
    case waitingForIterm
    /// iTerm2 is not running, as the app learned when asked for an API cookie.
    case itermNotRunning
    /// iTerm2 is running but will not hand the helper an API cookie.
    case refused(String)
    case connected(version: String?)

    public static func forSnapshot(_ snapshot: DaemonSnapshot) -> ItermConnection {
        if snapshot.connected { return .connected(version: snapshot.itermVersion) }
        if let reason = snapshot.itermAuthError { return .refused(reason) }
        return .waitingForIterm
    }

    /// The iTerm2 card’s status line, without a full stop.
    public var status: String {
        switch self {
        case .starting: "Starting AiTerm’s helper…"
        case .helperMissing: "AiTerm’s helper is missing"
        case .pythonMissing: "Python 3.11+ was not found"
        case .helperFailing(let message): "AiTerm’s helper keeps stopping: \(message)"
        case .helperMismatch: "AiTerm’s helper is from another version"
        case .helperUnreachable: "Reconnecting to AiTerm’s helper…"
        case .waitingForIterm: "Waiting for iTerm2…"
        case .itermNotRunning: "iTerm2 isn’t running"
        case .refused(let reason): "iTerm2 refused the connection: \(reason)"
        case .connected(let version): version.map { "Connected to iTerm2 \($0)" } ?? "Connected to iTerm2"
        }
    }

    /// Actionable problems appear at once; a start, reconnect or wait is silent until its grace ends.
    public func banner(waited: Bool) -> ConnectionBanner? {
        switch self {
        case .itermNotRunning:
            return ConnectionBanner(title: "iTerm2 isn’t running.", opensIterm: true)
        case .refused(let reason):
            return ConnectionBanner(title: "iTerm2 refused AiTerm.",
                description: "In System Settings › Privacy & Security › Automation, turn on iTerm2 under AiTerm. "
                    + "AiTerm retries on its own within a minute.", help: reason)
        case .waitingForIterm:
            return waited ? ConnectionBanner(title: "AiTerm isn’t connected to iTerm2.",
                description: "iTerm2 has to allow AiTerm’s connection. Settings shows what is missing.",
                opensSettings: true) : nil
        case .connected:
            return nil
        default: break
        }
        let description: String
        switch self {
        case .helperMissing:
            description = "Reinstall AiTerm.app, which bundles the helper."
        case .pythonMissing:
            description = "Python 3.11+ was not found. Install it with brew install python, then quit and reopen AiTerm."
        case .helperFailing(let message):
            description = "It keeps stopping: \(message). Read why in \(Self.logPath)."
        case .helperMismatch:
            description = "It is from another version. Quit and reopen AiTerm.app."
        case .starting, .helperUnreachable:
            guard waited else { return nil }
            description = "Read why in \(Self.logPath)."
        case .waitingForIterm, .itermNotRunning, .refused, .connected:
            return nil
        }
        return ConnectionBanner(title: "AiTerm’s helper isn’t working.", description: description)
    }

    /// Where the helper's output goes, as a person would type it.
    public static var logPath: String { (AiTermPaths.daemonLogURL.path as NSString).abbreviatingWithTildeInPath }
}

/// What AiTerm can learn about iTerm2 without the helper: whether it is installed, and whether its
/// Python API server is switched on. The helper cannot tell an API that is off from an iTerm2 that
/// is still launching; iTerm2's own preference can.
public enum ItermPreferences {
    public static let bundleIdentifier = "com.googlecode.iterm2"

    /// iTerm2 › Settings › General › Magic › Enable Python API. iTerm2 ships with it off, so a
    /// missing key means off.
    public static func pythonAPIEnabled() -> Bool {
        let domain = bundleIdentifier as CFString
        CFPreferencesAppSynchronize(domain) // Read what iTerm2 wrote a moment ago, not a cached copy.
        return (CFPreferencesCopyAppValue("EnableAPIServer" as CFString, domain) as? Bool) ?? false
    }
}
