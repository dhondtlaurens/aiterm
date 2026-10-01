import Foundation

public struct Frame: Codable, Equatable, Sendable { public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h } }

public struct SessionInfo: Codable, Equatable, Identifiable, Sendable {
    public var sessionId: String, windowId: String, tabIndex: Int, taskId: String?, projectId: String?
    public var agent: SessionAgent, model: String?, reasoning: String? = nil, state: SessionState, title: String, cwd: String
    /// The directory the *agent* is in. `cwd` is iTerm2's, which is the shell's and never follows
    /// a Claude that has entered a worktree; the daemon fills this in from the agent's own session
    /// file (Claude) or its hook posts (Codex). Absent for a plain shell.
    public var agentCwd: String? = nil
    /// True for the tab that was current in its window as of the daemon's last snapshot.
    public var active: Bool? = nil
    /// This provider's last-known context fill within the task, 0-100. The daemon shares it across
    /// sibling tabs running the same provider so tab changes cannot erase it. An unassociated
    /// session may carry its own value, but the app only displays task context.
    public var contextPercent: Int? = nil
    public var id: String { sessionId }
    /// The task tag as the id it names. The app writes `uuidString`, but a tag read back from
    /// iTerm2 is a string, so it is compared as a UUID rather than by spelling.
    public var taskUUID: UUID? { taskId.flatMap(UUID.init(uuidString:)) }
    /// What this tab's branch must be resolved from.
    public var effectiveCwd: String { agentCwd ?? cwd }
}

/// A literal title for one iTerm2 tab. The daemon keeps it separate from the session's process
/// title, which remains available for agent status detection.
public struct SessionTitle: Codable, Equatable, Sendable {
    public var sessionId: String, title: String
    public init(sessionId: String, title: String) { self.sessionId = sessionId; self.title = title }
}

public struct UsageWindow: Codable, Equatable, Sendable { public var usedPercent: Int; public var resetsAt: Int? }
public struct Usage: Codable, Equatable, Sendable {
    public var fiveHour, sevenDay, spend: UsageWindow?; public var plan: String?
    /// When the vendor last reported, in epoch seconds.
    public var updatedAt: Int
}
public struct UsageSnapshot: Codable, Equatable, Sendable { public var claude, codex: Usage?
    public static let empty = UsageSnapshot(claude: nil, codex: nil) }

public struct DaemonError: Error, Equatable, LocalizedError, CustomStringConvertible {
    public let code: String, message: String
    public var errorDescription: String? { message }
    public var description: String { message }

    /// The thing a request named — a window, session or task — is already gone.
    static let notFoundCode = "not_found"
    /// `DaemonClient.snapshot()`'s own guard: a helper whose protocol version this app cannot speak.
    static let incompatibleCode = "incompatible"
    /// The daemon has no handler for this request name — an older helper out of sync with a newer app.
    static let unknownMethodCode = "unknown_method"

    public var isNotFound: Bool { code == Self.notFoundCode }
    /// Either code a stale or mismatched helper answers with, as opposed to iTerm2 itself being
    /// unreachable — `DaemonConnection` reports these as `.helperMismatch`, not a retryable outage.
    public var isMismatch: Bool { code == Self.incompatibleCode || code == Self.unknownMethodCode }
}

public struct DaemonSnapshot: Decodable, Equatable, Sendable {
    public let protocolVersion: Int
    public let connected: Bool
    public let sessions: [SessionInfo]
    public let usage: UsageSnapshot
    /// Why iTerm2 is refusing the daemon's API connection, while it is. A refusal at startup comes
    /// before the app has attached to hear the `iterm.auth_failed` event, so the snapshot carries it.
    public var itermAuthError: String? = nil
    /// The iTerm2 the daemon is connected to, while it is. Older daemons do not send it.
    public var itermVersion: String? = nil
    /// A cookie request the daemon made before the app attached to hear `iterm.cookieRequested`.
    /// Older daemons, which ask iTerm2 themselves, do not send it.
    public var itermCookieRequest: Int? = nil
}

/// The app's answer when the daemon asks it for an iTerm2 API cookie (`ItermCookie`).
public enum ItermCookieAnswer: Equatable, Sendable {
    case granted(cookie: String, key: String)
    case notRunning
    /// Why iTerm2 would not hand one over, e.g. AiTerm has no Automation permission for it.
    case refused(String)
}

public enum DaemonEvent: Equatable, Sendable {
    case snapshot(DaemonSnapshot)
    case itermConnected(String?), itermDisconnected, itermAuthFailed(String), itermCookieRequested(Int)
    case windowActivated(String), windowClosed(String)
    case sessionOpened(SessionInfo), sessionClosed(String), sessionChanged(SessionInfo)
    case usageChanged(UsageSnapshot), unknown(String)
}

struct RawMessage: Decodable {
    var id: Int?, result: AnyCodableBox?, error: DaemonErrorBody?, event: String?, payload: AnyCodableBox?
    /// Not on the wire: `DaemonClient.dispatch(_:)` fills this in for a `workspace.snapshot` reply
    /// it already decoded to yield as a `.snapshot` event, so `request(_:params:as:)` can hand that
    /// same value back to `snapshot()`'s caller instead of decoding `result` a second time.
    var decodedSnapshot: DaemonSnapshot? = nil
}
struct DaemonErrorBody: Decodable { var code: String, message: String }

/// Keeps the raw JSON bytes of a subtree so it can be decoded later into a concrete type.
struct AnyCodableBox: Decodable {
    let data: Data
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(JSONValue.self)
        data = try JSONEncoder().encode(value)
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: data) }
}

indirect enum JSONValue: Codable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
