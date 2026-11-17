import Foundation

public struct Frame: Codable, Equatable, Sendable { public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h } }

public struct SessionInfo: Codable, Equatable, Identifiable, Sendable {
    public var sessionId: String, windowId: String, tabIndex: Int, taskId: String?, projectId: String?
    public var agent: SessionAgent, state: SessionState, cwd: String
    /// The directory the *agent* is in. `cwd` is iTerm2's, which is the shell's and never follows
    /// a Claude that has entered a worktree; the daemon fills this in from the agent's own session
    /// file (Claude) or its hook posts (Codex). Absent for a plain shell.
    public var agentCwd: String? = nil
    /// True for the tab that was current in its window as of the daemon's last snapshot. The
    /// daemon sends this flag for every tab.
    public var active = false
    /// This provider's last-known context fill within the task, 0-100. The daemon shares it across
    /// sibling tabs running the same provider so tab changes cannot erase it. An unassociated
    /// session may carry its own value, but the app only displays task context.
    public var contextPercent: Int? = nil
    /// Current input context for this conversation, never shared with sibling tabs. Unknown is nil.
    public var contextTokens: Int? = nil
    /// The conversation this tab's agent runs, as the agent's own hooks name it: what reopening its
    /// task's window resumes (`TaskItem.conversations`). Nil for a shell, before the agent's first
    /// hook placed on this tab.
    public var conversationId: String? = nil
    /// The terminal row this tab's window was opened for, which adopts a window iTerm2 renumbered or
    /// restored. Nil for a task's tab.
    public var terminalId: String? = nil
    /// The key of the Operator's extra worker tab this is (`open_tab`): it tells that tab apart from its task's
    /// first worker and from the task's other extra tabs, all tagged with the task. Nil for any other tab.
    public var tabKey: String? = nil
    /// The work running beside its agent's turn, in the order the daemon gives it: what the last Stop listed first,
    /// then the subagents and shells read live that it did not list. Only an item that `holdsTurn` wakes the agent
    /// again; a turn ended with one is paused, not finished.
    public var work: [WorkItem] = []
    /// The first line of the prompt you typed into this tab yourself, for the turn it started: not one AiTerm launched
    /// the agent with or delivered. Nil once that turn ends, for any other prompt.
    public var yourPrompt: String? = nil
    /// What ended its last turn short, an API error Claude Code reported in place of its Stop, until it works again. Nil
    /// for any other tab.
    public var stoppedOn: StoppedOn? = nil
    /// The test runner's own exact-worktree lifecycle; only queued/running states are live work.
    public var testActivity: TestActivity? = nil
    public var id: String { sessionId }
    /// The task tag as the id it names. The app writes `uuidString`, but a tag read back from
    /// iTerm2 is a string, so it is compared as a UUID rather than by spelling.
    public var taskUUID: UUID? { taskId.flatMap(UUID.init(uuidString:)) }
    /// The terminal tag as the id it names, compared as a UUID rather than by spelling, as `taskUUID` is.
    public var terminalUUID: UUID? { terminalId.flatMap(UUID.init(uuidString:)) }
    /// What this tab's branch must be resolved from.
    public var effectiveCwd: String { agentCwd ?? cwd }
}

/// A test run the project's runner reports through an inherited kernel lock and exit record, in the format
/// docs/configuration.md documents for any project ("Show your project's test runs").
public struct TestActivity: Codable, Equatable, Sendable {
    public enum State: String, Codable, LenientRawDecodable, Sendable {
        case queued, running, completed, interrupted
        static var unrecognized: Self { .interrupted }
    }
    public var runId: String, suite: String, state: State
    public var queuePosition: Int?, holder: String?, exitCode: Int?
    public var finishedAt: Double?
    public init(runId: String, suite: String, state: State, queuePosition: Int? = nil,
                holder: String? = nil, exitCode: Int? = nil, finishedAt: Double? = nil) {
        self.runId = runId; self.suite = suite; self.state = state
        self.queuePosition = queuePosition; self.holder = holder; self.exitCode = exitCode
        self.finishedAt = finishedAt
    }
    public var isActive: Bool { state == .queued || state == .running }
    public var line: String {
        switch state {
        case .queued: return "tests queued" + (queuePosition.map { " · #\($0)" } ?? "")
        case .running: return "running tests · " + suite
        case .completed:
            return exitCode.map { $0 == 0 ? "last tests passed" : "last tests failed · exit \($0)" } ?? "last tests ended · exit unavailable"
        case .interrupted: return "last tests interrupted · exit unavailable"
        }
    }
    public var detail: String {
        let ended = finishedAt.map { "; finished " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard) } ?? ""
        let lead = "\(suite) tests: " + line + ended
        return holder.map { lead + "; waiting for " + $0 } ?? lead
    }
}

/// What ended a Claude tab's last turn short (the daemon's `StoppedOn`): the API error Claude Code reported in place of
/// its Stop, by Claude Code's own name for it, and for a usage limit when it resets, as the tab's transcript recorded it.
public struct StoppedOn: Codable, Equatable, Sendable {
    /// `rate_limit` for a usage or rate limit; `billing_error`, `authentication_failed` and the like for a failure that
    /// blocks the tab until someone acts; `unknown` for one Claude Code could not name.
    public var error: String
    /// When the limit resets, in seconds since 1970; nil while the transcript has not said, and for any other error.
    public var resetsAt: Int?
    public init(error: String, resetsAt: Int? = nil) { self.error = error; self.resetsAt = resetsAt }

    /// A usage or rate limit, which Claude Code may carry on from by itself once it resets.
    public var isLimit: Bool { error == "rate_limit" }
}

/// One line of a tab's work (`SessionInfo.work`): a shell by its command, a monitor, a subagent or any other task by its
/// description.
public struct WorkItem: Codable, Equatable, Sendable {
    public var kind: BackgroundJob.Kind, text: String
    /// Its agent's last Stop listed it: the agent takes the turn up again once it ends. The row's status and the
    /// Operator read only these; the card draws every item.
    public var holdsTurn: Bool
    public init(kind: BackgroundJob.Kind, text: String, holdsTurn: Bool) {
        self.kind = kind; self.text = text; self.holdsTurn = holdsTurn
    }
    public var job: BackgroundJob { BackgroundJob(kind: kind, text: text) }
}

/// A shell by its command, a monitor, a subagent or any other task by its description.
public struct BackgroundJob: Equatable, Hashable, Sendable {
    /// See `SessionAgent`'s decoding note: a kind this app does not know reads as `.task`.
    public enum Kind: String, Codable, LenientRawDecodable, Sendable {
        case shell, monitor, task, subagent
        static var unrecognized: Self { .task }
    }
    public var kind: Kind, text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

/// A literal title for one iTerm2 tab. The daemon keeps it separate from the session's process
/// title, which remains available for agent status detection.
public struct SessionTitle: Codable, Equatable, Sendable {
    public var sessionId: String, title: String
    public init(sessionId: String, title: String) { self.sessionId = sessionId; self.title = title }
}

public struct UsageWindow: Codable, Equatable, Sendable { public var usedPercent: Int; public var resetsAt: Int? }
public struct UsageRetrievalFailure: Codable, Equatable, Sendable {
    public var message: String
    public var at: Int
}
public struct Usage: Codable, Equatable, Sendable {
    public var fiveHour, sevenDay, spend: UsageWindow?
    /// When the vendor last reported, in epoch seconds.
    public var updatedAt: Int
    public var retrievalFailure: UsageRetrievalFailure? = nil
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
    /// Acknowledges the app-resolved Claude folder.
    public var claudeConfigDirectory: String? = nil
    public let connected: Bool
    public let sessions: [SessionInfo]
    public let usage: UsageSnapshot
    /// Why iTerm2 is refusing the daemon's API connection, while it is. A refusal at startup comes
    /// before the app has attached to hear the `iterm.auth_failed` event, so the snapshot carries it.
    public var itermAuthError: String? = nil
    /// The iTerm2 the daemon is connected to, while it is.
    public var itermVersion: String? = nil
    /// A cookie request the daemon made before the app attached to hear `iterm.cookieRequested`.
    public var itermCookieRequest: Int? = nil
}

/// The app's answer when the daemon asks it for an iTerm2 API cookie (`ItermCookie`).
public enum ItermCookieAnswer: Equatable, Sendable {
    case granted(cookie: String, key: String)
    case notRunning
    /// Why iTerm2 would not hand one over, e.g. AiTerm has no Automation permission for it.
    case refused(String)
}

/// How a `session.deliver` went: typed and submitted, typed but left unsent, or not typed at all.
/// An outcome a newer daemon names that this app does not decodes as `.refused`: nothing is assumed typed.
public enum DeliveryOutcome: String, Codable, LenientRawDecodable, Sendable {
    case delivered, partial, refused
    static var unrecognized: Self { .refused }
}

/// Why a delivery was refused, or its Enter held back, in one word (the daemon's `delivery.RefusalCode`):
/// what the app tells apart and says in its own words, where `Delivery.reason` says it in the daemon's. A
/// code a newer daemon names that this app does not know decodes as `.unknown`.
public enum DeliveryCode: String, Codable, LenientRawDecodable, CaseIterable, Sendable {
    case ownership, itermDisconnected, sessionClosed, replaced, notChecked, unsupported, typing, unsentInput, keysUnwatched
    case screenUnread, prompt, unrecognisedScreen, nothing, messageFile, wakeText, itermRefused, pasteOnly
    case unknown
    static var unrecognized: Self { .unknown }
}

/// A delivery's result and, unless it was delivered, why: in the daemon's words, and as a code.
public struct Delivery: Codable, Equatable, Sendable {
    public var result: DeliveryOutcome
    public var reason: String?
    /// Nil when delivered.
    public var code: DeliveryCode?
    public init(result: DeliveryOutcome, reason: String?, code: DeliveryCode? = nil) {
        self.result = result; self.reason = reason; self.code = code
    }
}

/// How AiTerm may type into one agent CLI, from the delivery check it last passed (the daemon's
/// `delivery.load_policy`): `auto` pastes and presses Enter, `pasteOnly` pastes and leaves the Enter to
/// the person, `off` types nothing. A policy a newer daemon names that this app does not know reads as
/// `off`: delivery fails closed.
public enum DeliveryPolicy: String, Codable, LenientRawDecodable, CaseIterable, Sendable {
    case auto, pasteOnly, off
    static var unrecognized: Self { .off }
}

/// The delivery check's verdict on one CLI: its policy, and the one version it vouches for.
public struct DeliveryVerdict: Codable, Equatable, Sendable {
    public var policy: DeliveryPolicy
    public var version: String?
    public init(policy: DeliveryPolicy, version: String?) { self.policy = policy; self.version = version }
}

/// One tool call from an operator: answered with `operator.reply` and the same `requestId`.
public struct OperatorRequest: Decodable, Equatable, Sendable {
    public var requestId: String, operatorId: String, tool: String
    public var generation: Int
    /// An object; a call with none reads as an empty one.
    public var arguments: JSONValue
    public init(requestId: String, operatorId: String, tool: String, arguments: JSONValue, generation: Int) {
        self.requestId = requestId; self.operatorId = operatorId; self.tool = tool; self.arguments = arguments; self.generation = generation
    }
    private enum CodingKeys: String, CodingKey { case requestId, operatorId, tool, arguments, generation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        operatorId = try c.decode(String.self, forKey: .operatorId)
        tool = try c.decode(String.self, forKey: .tool)
        arguments = try c.decodeIfPresent(JSONValue.self, forKey: .arguments) ?? .object([:])
        generation = try c.decode(Int.self, forKey: .generation)
    }
}

public enum DaemonEvent: Equatable, Sendable {
    case snapshot(DaemonSnapshot)
    case itermConnected(String?), itermDisconnected, itermAuthFailed(String), itermCookieRequested(Int)
    case windowActivated(String), windowClosed(String)
    case sessionOpened(SessionInfo), sessionClosed(String), sessionChanged(SessionInfo)
    case usageChanged(UsageSnapshot), operatorRequest(OperatorRequest), unknown(String)
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

extension DaemonError {
    /// Whether what the request asked for may still happen: it timed out, or the helper or iTerm2 went before it
    /// answered, so a window or a tab asked for may open yet, and a token sent may be registered. Any other failure
    /// is a refusal: nothing was done.
    public var leavesOutcomeUnknown: Bool { [.timeout, .disconnected, .itermUnavailable].contains(code) }
}
