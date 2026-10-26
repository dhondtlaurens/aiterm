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
    /// The conversation this tab's agent runs, as the agent's own hooks name it: what reopening its
    /// task's window resumes (`TaskItem.conversations`). Nil for a shell, before the agent's first
    /// hook placed on this tab, and from a daemon too old to send it.
    public var conversationId: String? = nil
    /// The terminal row this tab's window was opened for, which adopts a window iTerm2 renumbered or
    /// restored. Nil for a task's tab, and from a daemon too old to send it.
    public var terminalId: String? = nil
    /// The key of the Operator's extra worker tab this is (`open_tab`): it tells that tab apart from its task's
    /// first worker and from the task's other extra tabs, all tagged with the task. Nil for any other tab, and
    /// from a daemon too old to send it.
    public var tabKey: String? = nil
    /// What its agent left running in the background when its last turn ended, which wakes it again (Claude's
    /// `background_tasks`): a shell by its command, other work by its description. A turn ended with any is paused,
    /// not finished. Empty once a new turn starts, and from a daemon too old to send it.
    public var background: [BackgroundJob] = []
    /// The first line of the prompt you typed into this tab yourself, for the turn it started: not one AiTerm launched
    /// the agent with or delivered. Nil once that turn ends, for any other prompt, and from a daemon too old to send it.
    public var yourPrompt: String? = nil
    /// The last slash commands AiTerm typed into this Claude tab, oldest first, and what became of each as the tab's
    /// own transcript shows it. Empty for any other tab, and from a daemon too old to send it.
    public var slashCommands: [SlashCommand] = []
    public var id: String { sessionId }
    /// The task tag as the id it names. The app writes `uuidString`, but a tag read back from
    /// iTerm2 is a string, so it is compared as a UUID rather than by spelling.
    public var taskUUID: UUID? { taskId.flatMap(UUID.init(uuidString:)) }
    /// The terminal tag as the id it names, compared as a UUID rather than by spelling, as `taskUUID` is.
    public var terminalUUID: UUID? { terminalId.flatMap(UUID.init(uuidString:)) }
    /// What this tab's branch must be resolved from.
    public var effectiveCwd: String { agentCwd ?? cwd }
    /// The model and effort this tab runs now, as its own Claude Code says them: its SessionStart, its PostModelSwitch
    /// and its status line, none of them a subagent's, and only once a switch has happened. Nil for any other agent,
    /// whose hooks may carry a child thread's model, and while Claude hasn't said.
    public var liveModel: String? { agent == .claude ? model : nil }
    public var liveReasoning: String? { agent == .claude ? reasoning : nil }
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
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
        terminalId = try c.decodeIfPresent(String.self, forKey: .terminalId)
        tabKey = try c.decodeIfPresent(String.self, forKey: .tabKey)
        background = try c.decodeIfPresent([BackgroundJob].self, forKey: .background) ?? []
        yourPrompt = try c.decodeIfPresent(String.self, forKey: .yourPrompt)
        slashCommands = try c.decodeIfPresent([SlashCommand].self, forKey: .slashCommands) ?? []
    }
}

/// A slash command AiTerm typed into a Claude tab and pressed Enter on (`message_task`), and what became of it, as the
/// tab's own transcript shows it (the daemon's `slash_commands.py`).
public struct SlashCommand: Codable, Equatable, Sendable {
    /// `delivered`: typed, nothing of it seen yet. `queued`: Claude Code queued it, and nothing has been taken from the
    /// queue since. `ran`: its own command record is there. `unknown`: nothing of it seen within a minute, or a
    /// transcript that can't be read; a /model or /effort run mid-turn takes effect and writes nothing. See
    /// `SessionAgent`'s decoding note: a state this app does not know reads as unknown.
    public enum State: String, Codable, LenientRawDecodable, Sendable {
        case delivered, queued, ran, unknown
        static var unrecognized: Self { .unknown }
    }
    public var text: String, state: State
    /// When AiTerm typed it, and when its transcript recorded it queued or run: seconds since 1970.
    public var deliveredAt: Double, seenAt: Double?
    /// A local command's output, on one line, once it ran.
    public var output: String?
    public init(text: String, state: State, deliveredAt: Double, seenAt: Double? = nil, output: String? = nil) {
        self.text = text; self.state = state; self.deliveredAt = deliveredAt; self.seenAt = seenAt; self.output = output
    }
}

/// One piece of work an agent's turn left running when it ended (a Claude Stop's `background_tasks`): a shell by its
/// command, a monitor or any other task by its description.
public struct BackgroundJob: Codable, Equatable, Hashable, Sendable {
    /// See `SessionAgent`'s decoding note: a kind this app does not know reads as `.task`.
    public enum Kind: String, Codable, LenientRawDecodable, Sendable {
        case shell, monitor, task
        static var unrecognized: Self { .task }
    }
    public var kind: Kind, text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }

    /// A daemon older than the kinds — one left running after a crash — sends each job as its text alone: read as
    /// a task, described, rather than failing the session it came in.
    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.init(kind: .task, text: text)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind), text: try c.decode(String.self, forKey: .text))
    }
}

/// A literal title for one iTerm2 tab. The daemon keeps it separate from the session's process
/// title, which remains available for agent status detection.
public struct SessionTitle: Codable, Equatable, Sendable {
    public var sessionId: String, title: String
    public init(sessionId: String, title: String) { self.sessionId = sessionId; self.title = title }
}

public struct UsageWindow: Codable, Equatable, Sendable { public var usedPercent: Int; public var resetsAt: Int? }
public struct Usage: Codable, Equatable, Sendable {
    public var fiveHour, sevenDay, spend: UsageWindow?
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
    /// Acknowledges the app-resolved Claude folder. Older helpers omit it.
    public var claudeConfigDirectory: String? = nil
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
    case ownership, itermDisconnected, sessionClosed, replaced, notChecked, unsupported, typing, unsentInput
    case screenUnread, prompt, unrecognisedScreen, nothing, messageFile, wakeText, itermRefused, pasteOnly
    case unknown
    static var unrecognized: Self { .unknown }
}

/// A delivery's result and, unless it was delivered, why: in the daemon's words, and as a code.
public struct Delivery: Codable, Equatable, Sendable {
    public var result: DeliveryOutcome
    public var reason: String?
    /// Nil when delivered, and from a daemon that names no code.
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

/// The prompt a session has open, as the daemon's screen markers classify it.
/// A kind a newer daemon names that this app does not decodes as `.menu`: a prompt is open, never
/// "none", which would read as safe to type. (A JSON null kind is still nil, at `DaemonClient.PromptResult`.)
public enum PromptKind: String, Codable, LenientRawDecodable, CaseIterable, Sendable {
    case permission, startup, menu
    static var unrecognized: Self { .menu }
}

/// One tool call from an operator: answered with `operator.reply` and the same `requestId`.
public struct OperatorRequest: Decodable, Equatable, Sendable {
    public var requestId: String, runId: String, tool: String
    /// An object; a call with none reads as an empty one.
    public var arguments: JSONValue
    public init(requestId: String, runId: String, tool: String, arguments: JSONValue) {
        self.requestId = requestId; self.runId = runId; self.tool = tool; self.arguments = arguments
    }
    private enum CodingKeys: String, CodingKey { case requestId, runId, tool, arguments }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        runId = try c.decode(String.self, forKey: .runId)
        tool = try c.decode(String.self, forKey: .tool)
        arguments = try c.decodeIfPresent(JSONValue.self, forKey: .arguments) ?? .object([:])
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
