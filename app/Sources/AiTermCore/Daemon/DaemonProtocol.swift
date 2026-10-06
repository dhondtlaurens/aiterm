import Foundation

/// The app's half of the wire contract with the daemon (`daemon/aitermd/protocol.py`): its
/// protocol version, its frame limit, and every request, event and error code it names. Each is
/// checked against the daemon's own by `WireContractTests`, which reads the manifest the daemon's
/// test suite writes beside its golden frames in `daemon/tests/wire/`.
public enum DaemonProtocol {
    /// The version `workspace.snapshot` reports. A helper that reports another is one this app
    /// cannot speak (`DaemonError.Code.incompatible`).
    public static let version = 1
    /// The longest line either side reads: the daemon's request reader is limited to it, and a
    /// longer line from the daemon ends this app's connection.
    public static let maximumFrameBytes = 1 << 20
}

/// A request the daemon answers.
public enum DaemonMethod: String, CaseIterable, Sendable {
    /// Also this client's liveness check (`DaemonClient.livenessCheck`).
    case itermStatus = "iterm.status"
    case itermProvideCookie = "iterm.provideCookie"
    case workspaceSnapshot = "workspace.snapshot"
    case windowCreateTask = "window.createTask"
    case windowCreateTerminal = "window.createTerminal"
    case windowActivate = "window.activate"
    case windowSetFrame = "window.setFrame"
    case windowClose = "window.close"
    case tabCreate = "tab.create"
    /// Not sent by the app: `aitermd ctl`'s.
    case sessionsList = "sessions.list"
    case sessionsSetTitles = "sessions.setTitles"
    case sessionsMarkSeen = "sessions.markSeen"
    /// Not sent by the app: `aitermd ctl`'s.
    case usageGet = "usage.get"
    case interfaceSetMatchItermBackground = "interface.setMatchItermBackground"
}

/// An event the daemon broadcasts. A name not among these is a newer helper's and arrives as
/// `DaemonEvent.unknown`; one among them that cannot be read ends the connection (`DaemonClient`).
/// `iterm.auth_failed` is spelt as it always has been on the wire, unlike its camel-cased siblings.
public enum DaemonEventName: String, CaseIterable, Sendable {
    case itermConnected = "iterm.connected"
    case itermDisconnected = "iterm.disconnected"
    case itermAuthFailed = "iterm.auth_failed"
    case itermCookieRequested = "iterm.cookieRequested"
    case windowActivated = "window.activated"
    case windowClosed = "window.closed"
    case sessionOpened = "session.opened"
    case sessionChanged = "session.changed"
    case sessionClosed = "session.closed"
    case usageChanged = "usage.changed"
}

extension DaemonError {
    /// What went wrong, by name: one of the daemon's (`daemonCodes`), which arrive in an error reply,
    /// or one of this client's own. Any other name a helper sends is kept as it came.
    public struct Code: RawRepresentable, Hashable, Sendable, Decodable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public var description: String { rawValue }

        // The daemon's.
        /// A request's parameters are missing or of the wrong type.
        public static let badParams: Code = "bad_params"
        /// The thing a request named — a window, session or task — is already gone.
        public static let notFound: Code = "not_found"
        /// The daemon has no connection to iTerm2, or lost it during the request.
        public static let itermUnavailable: Code = "iterm_unavailable"
        /// A line that is not a request at all. This client also uses it for a request too long to send.
        public static let `protocol`: Code = "protocol"
        /// The handler failed in a way it did not name.
        public static let `internal`: Code = "internal"
        /// The daemon has no handler for this request name — an older helper out of sync with a newer app.
        public static let unknownMethod: Code = "unknown_method"
        /// Every code the daemon answers with.
        public static let daemonCodes: [Code] = [.badParams, .notFound, .itermUnavailable, .protocol, .internal, .unknownMethod]

        // This client's own.
        /// `DaemonClient.snapshot()`'s guard: a helper whose protocol version this app cannot speak.
        public static let incompatible: Code = "incompatible"
        /// No reply within the request's timeout; what the request asked for may still happen.
        public static let timeout: Code = "timeout"
        /// The connection closed, or was never open, before the reply came.
        public static let disconnected: Code = "disconnected"
        /// A `DaemonClient` is single-use: one that has connected once cannot connect again.
        public static let connectionUsed: Code = "connection_used"
        /// The socket could not be made, or its path is too long.
        public static let socket: Code = "socket"
        /// The daemon's socket did not accept the connection.
        public static let connect: Code = "connect"
        /// The request could not be written to the socket.
        public static let write: Code = "write"
    }
}
