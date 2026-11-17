import Foundation

/// The requests the app makes of a connected daemon, apart from the connection's snapshots and
/// cookie answers. `DaemonClient` sends them over the socket; the app's tests record them instead.
public protocol DaemonCommands: Sendable {
    /// The tabs now, after the daemon ticks; this query yields no snapshot event.
    func sessions() async throws -> [SessionInfo]
    /// `background` opens it behind the person's work: an operator's worker windows do. Its window id, and why its agent
    /// command could not be typed, when the daemon could not type it: the window is there either way.
    func createTaskWindow(taskId: String, cwd: String, title: String, agentCommand: String?, frame: Frame, background: Bool) async throws -> Opening
    func createTerminalWindow(projectId: String, terminalId: String, cwd: String, title: String, frame: Frame) async throws -> String
    /// A tab in an existing window, carrying that window's task or project tag. `tabKey` tags it as the Operator's
    /// extra worker tab of that key (`open_tab`), and a repeat returns the tab already tagged so; `background` opens
    /// it behind the person's work.
    func createTab(windowId: String, cwd: String, agentCommand: String?, tabKey: String?, background: Bool) async throws -> Opening
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
    /// current generation, `wake` holds it while the person types there.
    func deliver(sessionId: String, text: String, ownership: Int, wake: Bool, worktree: String?) async throws -> Delivery
    func closeIdle(sessionId: String, ownership: Int, conversation: String) async throws -> Delivery
    func setOwnership(sessionId: String, ownership: Int) async throws
    /// What the delivery check vouches for, per agent: whether, and at which version, its workers can be messaged.
    func deliveryPolicy() async throws -> [AgentKind: DeliveryVerdict]
    func registerOperator(operatorId: String, token: String, generation: Int) async throws
    func revokeOperator(operatorId: String, generation: Int) async throws
    func replyToOperator(requestId: String, result: JSONValue?, error: String?) async throws
}

/// A window or tab the daemon opened: its window or session id, and why its agent command
/// could not be typed (the daemon's `commandError`), nil when it was.
public struct Opening: Equatable, Sendable {
    public var id: String
    public var commandError: String?
    public init(id: String, commandError: String? = nil) { self.id = id; self.commandError = commandError }
}

extension DaemonClient: DaemonCommands {}
