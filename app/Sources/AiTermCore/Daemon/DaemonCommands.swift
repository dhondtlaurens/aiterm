import Foundation

/// The requests the app makes of a connected daemon, apart from the connection's own cookie
/// answers. `DaemonClient` sends them over the socket; the app's tests record them instead.
public protocol DaemonCommands: Sendable {
    func snapshot() async throws -> DaemonSnapshot
    func createTaskWindow(taskId: String, cwd: String, title: String, agentCommand: String?, frame: Frame) async throws -> String
    func createTerminalWindow(projectId: String, cwd: String, title: String, frame: Frame) async throws -> String
    /// A tab in an existing window, carrying that window's task or project tag.
    func createTab(windowId: String, cwd: String, agentCommand: String?) async throws -> String
    func activate(windowId: String) async throws
    func setFrame(windowId: String, frame: Frame) async throws
    func close(windowId: String) async throws
    @discardableResult func setSessionTitles(_ titles: [SessionTitle]) async throws -> Int
    func markSeen(taskId: String) async throws -> Int
    /// Applies the Interface preference to every terminal window AiTerm manages.
    func setMatchItermBackground(_ enabled: Bool) async throws
}

extension DaemonClient: DaemonCommands {}
