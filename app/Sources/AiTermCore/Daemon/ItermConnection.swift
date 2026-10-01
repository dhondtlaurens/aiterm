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
    /// The helper is answering and has never had iTerm2 in this streak.
    case waitingForIterm
    /// The helper had iTerm2 and lost it.
    case itermReconnecting
    /// iTerm2 is running but will not hand the helper an API cookie.
    case refused(String)
    case connected(version: String?)

    public static func forSnapshot(_ snapshot: DaemonSnapshot) -> ItermConnection {
        if snapshot.connected { return .connected(version: snapshot.itermVersion) }
        if let reason = snapshot.itermAuthError { return .refused(reason) }
        return .waitingForIterm
    }

    /// The state as the iTerm2 card's status line says it — a status, so no full stop. The banner
    /// above the sidebar opens with the same words, so the two never name one state two ways.
    public var status: String {
        switch self {
        case .starting: "Starting AiTerm’s helper…"
        case .helperMissing: "AiTerm’s helper is missing"
        case .pythonMissing: "Python 3.11+ was not found"
        case .helperFailing(let message): "AiTerm’s helper keeps stopping: \(message)"
        case .helperMismatch: "AiTerm’s helper is from another version"
        case .helperUnreachable: "Reconnecting to AiTerm’s helper…"
        case .waitingForIterm: "Waiting for iTerm2…"
        case .itermReconnecting: "Reconnecting to iTerm2…"
        case .refused(let reason): "iTerm2 refused the connection: \(reason)"
        case .connected(let version): version.map { "Connected to iTerm2 \($0)" } ?? "Connected to iTerm2"
        }
    }

    /// The line above the sidebar: the card's status, then — where only the person can mend it —
    /// what to do, as the card's steps say it. Nothing is shown once iTerm2 is connected.
    public var banner: DaemonBanner? {
        switch self {
        case .starting, .helperUnreachable, .waitingForIterm, .itermReconnecting: .info(status)
        case .helperMissing: .info(status + ". Reinstall AiTerm.app, which bundles the helper.")
        case .pythonMissing: .info(status + ". Install it with brew install python, then quit and reopen AiTerm.")
        case .helperFailing: .info(status + ". Read why in \(Self.logPath).")
        case .helperMismatch: .info(status + ". Quit and reopen AiTerm.app.")
        case .refused:
            .warning(status + ". In System Settings › Privacy & Security › Automation, turn on iTerm2 under AiTerm. "
                     + "AiTerm retries on its own within a minute.")
        case .connected: nil
        }
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
