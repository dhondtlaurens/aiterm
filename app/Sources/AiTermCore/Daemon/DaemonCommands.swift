import Foundation

/// The requests the app makes of a connected daemon, apart from the connection's own cookie
/// answers. `DaemonClient` sends them over the socket; the app's tests record them instead.
public protocol DaemonCommands: Sendable {
    func snapshot() async throws -> DaemonSnapshot
    /// `background` opens it behind the person's work: an operator's worker windows do.
    func createTaskWindow(taskId: String, cwd: String, title: String, agentCommand: String?, frame: Frame, background: Bool) async throws -> String
    func createTerminalWindow(projectId: String, terminalId: String, cwd: String, title: String, frame: Frame) async throws -> String
    /// A tab in an existing window, carrying that window's task or project tag. `tabKey` tags it as the Operator's
    /// extra worker tab of that key (`open_tab`), and a repeat returns the tab already tagged so; `background` opens
    /// it behind the person's work.
    func createTab(windowId: String, cwd: String, agentCommand: String?, tabKey: String?, background: Bool) async throws -> String
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
    func prompt(sessionId: String) async throws -> PromptKind?
    func promptDetails(sessionId: String) async throws -> PromptDetails
    /// Declines Codex's update offer with Esc, and nothing else: true when it did.
    func dismissStartup(sessionId: String) async throws -> Bool
    func setOwnership(sessionId: String, ownership: Int) async throws
    /// What the delivery check vouches for, per agent: whether, and at which version, its workers can be messaged.
    func deliveryPolicy() async throws -> [AgentKind: DeliveryVerdict]
    func registerOperator(runId: String, token: String) async throws
    func revokeOperator(runId: String) async throws
    func replyToOperator(requestId: String, result: JSONValue?, error: String?) async throws
}

extension DaemonCommands {
    /// Compatibility for a helper that cannot return the prompt's visible text.
    public func promptDetails(sessionId: String) async throws -> PromptDetails {
        PromptDetails(kind: try await prompt(sessionId: sessionId))
    }

    /// A task window in front, as every window but an operator's worker's opens.
    public func createTaskWindow(taskId: String, cwd: String, title: String, agentCommand: String?, frame: Frame) async throws -> String {
        try await createTaskWindow(taskId: taskId, cwd: cwd, title: title, agentCommand: agentCommand, frame: frame, background: false)
    }

    /// A tab in front, as every tab but an operator's extra worker's opens.
    public func createTab(windowId: String, cwd: String, agentCommand: String?) async throws -> String {
        try await createTab(windowId: windowId, cwd: cwd, agentCommand: agentCommand, tabKey: nil, background: false)
    }
}

extension DaemonClient: DaemonCommands {}
