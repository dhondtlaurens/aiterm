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
    /// True for the tab that was current in its window as of the daemon's last snapshot. The
    /// bundled daemon always says; one that does not is read as saying no.
    public var active = false
    /// This provider's last-known context fill within the task, 0-100. The daemon shares it across
    /// sibling tabs running the same provider so tab changes cannot erase it. An unassociated
    /// session may carry its own value, but the app only displays task context.
    public var contextPercent: Int? = nil
    /// What this tab's conversation has spent, its subagents and background workers included. The
    /// tab's own — the daemon never shares it across sibling tabs, as it does a context fill.
    public var tokens: TokenTally? = nil
    /// The conversation this tab's agent runs, as the agent's own hooks name it: what reopening its
    /// task's window resumes (`TaskItem.conversations`). Nil for a shell, before the agent's first
    /// hook placed on this tab, and from a daemon too old to send it.
    public var conversationId: String? = nil
    public var id: String { sessionId }
    /// The task tag as the id it names. The app writes `uuidString`, but a tag read back from
    /// iTerm2 is a string, so it is compared as a UUID rather than by spelling.
    public var taskUUID: UUID? { taskId.flatMap(UUID.init(uuidString:)) }
    /// What this tab's branch must be resolved from.
    public var effectiveCwd: String { agentCwd ?? cwd }
}

extension SessionInfo {
    /// Written by hand for `active` alone, which an older daemon leaves out; every other field is
    /// read as the synthesised decoder would. In an extension, so the memberwise initialiser stays.
    /// `WireContractTests` reads the daemon's own sessions with it and compares each field with the
    /// daemon's JSON, so a field this misreads, or a key it reads under another name, shows there.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        windowId = try c.decode(String.self, forKey: .windowId)
        tabIndex = try c.decode(Int.self, forKey: .tabIndex)
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        agent = try c.decode(SessionAgent.self, forKey: .agent)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        state = try c.decode(SessionState.self, forKey: .state)
        title = try c.decode(String.self, forKey: .title)
        cwd = try c.decode(String.self, forKey: .cwd)
        agentCwd = try c.decodeIfPresent(String.self, forKey: .agentCwd)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        contextPercent = try c.decodeIfPresent(Int.self, forKey: .contextPercent)
        // Read leniently: a tally this app cannot read — a count too large for an `Int`, a daemon of
        // another shape — costs only these counts, not the session and the snapshot it came in.
        tokens = (try? c.decodeIfPresent(TokenTally.self, forKey: .tokens)) ?? nil
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
    }
}

/// What one conversation has spent so far, its subagents and background workers included (the
/// daemon's `TokenTally`). `input` counts cache reads and writes too; `cached` is that share — nil
/// when the harness cannot tell it apart — and `output` counts reasoning.
public struct TokenTally: Codable, Equatable, Sendable {
    public var input: Int, cached: Int?, output: Int
    public init(input: Int, cached: Int?, output: Int) { self.input = input; self.cached = cached; self.output = output }
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

/// A request's failure: the daemon's error reply, or this client's own (`Code`). `message` is
/// written for the protocol, or by Python — "no such window or session: w3", an exception's text —
/// so it is what the log and a developer read (`description`); the person reads `userMessage`.
public struct DaemonError: Error, Equatable, LocalizedError, CustomStringConvertible {
    public let code: Code, message: String
    public var errorDescription: String? { userMessage }
    public var description: String { message }

    /// The failure as a banner's reason says it, by its code — never the helper's own message, which
    /// is written for the protocol or by Python. A code only a newer helper knows reads as the
    /// helper's problem, as `internal` does.
    public var userMessage: String {
        switch code {
        case .itermUnavailable: "iTerm2 isn’t connected."
        case .notFound: "The iTerm2 window or tab is already gone."
        case .timeout: "AiTerm’s helper didn’t answer in time; it may still finish."
        case .disconnected, .connect, .socket, .write, .connectionUsed: "AiTerm’s helper isn’t connected."
        case .unknownMethod, .incompatible: "AiTerm’s helper is from another version."
        case .badParams, .protocol: "AiTerm’s helper couldn’t read the request."
        default: "AiTerm’s helper ran into a problem."
        }
    }

    public var isNotFound: Bool { code == .notFound }
    /// Either code a stale or mismatched helper answers with, as opposed to iTerm2 itself being
    /// unreachable — `DaemonConnection` reports these as `.helperMismatch`, not a retryable outage.
    public var isMismatch: Bool { code == .incompatible || code == .unknownMethod }
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

/// What routes a line from the daemon: a reply's `id` and `error`, or an event's name. The rest of
/// the line is decoded from the same bytes, once, into the type its route names (`Reply`,
/// `EventPayload`), with no untyped tree in between.
struct Header: Decodable { var id: Int?, event: String?, error: DaemonErrorBody? }
struct DaemonErrorBody: Decodable { var code: DaemonError.Code, message: String }
/// A reply's `result`, as the request's own type.
struct Reply<Value: Decodable>: Decodable { var result: Value }
/// An event's `payload`, as the type its name says.
struct EventPayload<Value: Decodable>: Decodable { var payload: Value }
