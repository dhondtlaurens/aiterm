import Foundation

/// The requests the app makes of a connected daemon, apart from the connection's snapshots and
/// cookie answers. `DaemonClient` sends them over the socket; the app's tests record them instead.
public protocol DaemonCommands: Sendable {
    /// The tabs now, after the daemon ticks; this query yields no snapshot event.
    func sessions() async throws -> [SessionInfo]
    /// `background` opens it behind the person's work: an operator's worker windows do. Its window id, and why its agent
    /// command could not be typed, when the daemon could not type it: the window is there either way.
    func createTaskWindow(taskId: String, cwd: String, title: String, agentCommand: String?, frame: Frame, background: Bool, worker: Bool) async throws -> Opening
    func createTerminalWindow(projectId: String, terminalId: String, cwd: String, title: String, frame: Frame) async throws -> String
    /// A tab in an existing window, carrying that window's task or project tag. `tabKey` tags it as the Operator's
    /// extra worker tab of that key (`open_tab`), and a repeat returns the tab already tagged so; `background` opens
    /// it behind the person's work.
    func createTab(windowId: String, cwd: String, agentCommand: String?, tabKey: String?, background: Bool, worker: Bool) async throws -> Opening
    func setWorkerSessions(taskId: String, sessionIds: [String], released: Bool, ownership: Int) async throws
    func activate(windowId: String) async throws
    /// One tab selected in its window, and that window brought forward: a task's worker tab among several, which
    /// `activate(windowId:)` would leave as its window last showed it.
    func activate(sessionId: String) async throws
    func setFrame(windowId: String, frame: Frame) async throws
    func close(windowId: String) async throws
    @discardableResult func setSessionTitles(_ titles: [SessionTitle]) async throws -> Int
    func markSeen(taskId: String) async throws -> Int
    /// Applies the Interface preference to every terminal window AiTerm manages.
    func setMatchItermBackground(_ enabled: Bool) async throws
    /// Types `text` into the session by the daemon's delivery rules; `ownership` must be the session's
    /// current generation, `wake` holds it while the person types there. `guardInput` holds any other text to the
    /// same checks of the person (typing, unsent input, no keystroke monitor), the delivery check's pass still needed:
    /// a project signal's prompt typed into a conversation that is also the person's.
    func deliver(sessionId: String, text: String, ownership: Int, wake: Bool, guardInput: Bool, worktree: String?) async throws -> Delivery
    func closeIdle(sessionId: String, ownership: Int, conversation: String) async throws -> Delivery
    /// What the session's input holds, read and never typed into: a project signal's Archive waits while it may hold
    /// the person's unsent words.
    func inputState(sessionId: String) async throws -> InputState
    func setOwnership(sessionId: String, ownership: Int) async throws
    /// What the delivery check vouches for, per agent: whether, and at which version, its workers can be messaged.
    func deliveryPolicy() async throws -> [AgentKind: DeliveryVerdict]
    func registerOperator(operatorId: String, token: String, generation: Int) async throws
    func revokeOperator(operatorId: String, generation: Int) async throws
    func replyToOperator(requestId: String, result: JSONValue?, error: String?) async throws
}

public extension DaemonCommands {
    func createTaskWindow(taskId: String, cwd: String, title: String, agentCommand: String?, frame: Frame,
                          background: Bool) async throws -> Opening {
        try await createTaskWindow(taskId: taskId, cwd: cwd, title: title, agentCommand: agentCommand,
                                   frame: frame, background: background, worker: false)
    }
    func createTab(windowId: String, cwd: String, agentCommand: String?, tabKey: String?, background: Bool) async throws -> Opening {
        try await createTab(windowId: windowId, cwd: cwd, agentCommand: agentCommand, tabKey: tabKey, background: background, worker: false)
    }

    /// An unguarded delivery, as every caller but a project signal's makes it.
    func deliver(sessionId: String, text: String, ownership: Int, wake: Bool, worktree: String?) async throws -> Delivery {
        try await deliver(sessionId: sessionId, text: text, ownership: ownership, wake: wake, guardInput: false, worktree: worktree)
    }
}

/// A window or tab the daemon opened: its window or session id, and why its agent command
/// could not be typed (the daemon's `commandError`), nil when it was.
public struct Opening: Equatable, Sendable {
    public var id: String
    public var commandError: String?
    public init(id: String, commandError: String? = nil) { self.id = id; self.commandError = commandError }
}

extension DaemonClient: DaemonCommands {}
