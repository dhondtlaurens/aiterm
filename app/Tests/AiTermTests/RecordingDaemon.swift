import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// A daemon that records every request, under the method `DaemonClient` would send it as, and
/// answers the window and tab calls the controller makes; the second window of a kind gets `-2`
/// after its id, and so on. `failing` refuses a method with an error code, as the daemon does, and
/// can change mid-test; `holding` keeps one method's replies back until `release()`, so a test can
/// act while the controller awaits one — the request is recorded before it is held, and whether it
/// fails is decided once it is let go.
@MainActor
final class RecordingDaemon: DaemonCommands {
    struct Request { let method: String; let params: [String: Any] }
    private(set) var requests: [Request] = []
    var onRequest: (String) -> Void = { _ in }
    /// The code each method fails with: one of the app's, or one only a newer helper would send.
    var failing: [String: DaemonError.Code]
    /// What `session.deliver` answers, in order, the last one repeated; delivered when empty.
    var deliveries: [Delivery] = []
    /// What `session.prompt` answers for each session; none open when absent.
    var prompts: [String: PromptKind] = [:]
    /// The sessions whose startup dialog `session.dismissStartup` declines (an update offer); others answer false.
    var dismissible: Set<String> = []
    /// What `delivery.policy` answers: both agents checked at the versions the scratch ports say are installed.
    var deliveryVerdicts: [AgentKind: DeliveryVerdict] = [.claude: DeliveryVerdict(policy: .auto, version: "2.1.301"),
                                                          .codex: DeliveryVerdict(policy: .auto, version: "0.160.0")]
    private let holding: String?
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var replies: [String: Int] = [:]

    init(failing: [String: DaemonError.Code] = [:], holding: String? = nil) {
        self.failing = failing
        self.holding = holding
    }

    func requests(_ method: String) -> [Request] { requests.filter { $0.method == method } }

    /// Waits until `method` has been asked for `count` times; `TestDeadline` passing is an issue.
    func received(_ method: String, count: Int = 1) async throws {
        await eventually(describing: "\(count) \(method) request(s)") { requests(method).count >= count }
    }

    /// Lets every held reply go, and every later one through without waiting.
    func release() {
        released = true
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    /// Records the request, waits out a hold, then fails it or counts its reply. `id` is the reply's
    /// window or session id for this method's first call.
    @discardableResult
    private func answer(_ method: String, _ params: [String: Any], id: String = "") async throws -> String {
        requests.append(Request(method: method, params: params))
        onRequest(method)
        if method == holding, !released { await withCheckedContinuation { held.append($0) } }
        replies[method, default: 0] += 1
        let count = replies[method, default: 1]
        if let code = failing[method] { throw DaemonError(code: code, message: "test failure") }
        return count == 1 ? id : "\(id)-\(count)"
    }

    private static func frame(_ frame: Frame) -> [String: Any] { ["x": frame.x, "y": frame.y, "w": frame.w, "h": frame.h] }

    func snapshot() async throws -> DaemonSnapshot {
        try await answer("workspace.snapshot", [:])
        return DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)
    }

    func createTaskWindow(taskId: String, cwd: String, title: String, agentCommand: String?, frame: Frame, background: Bool) async throws -> String {
        var params: [String: Any] = ["taskId": taskId, "cwd": cwd, "title": title, "frame": Self.frame(frame)]
        params["agentCommand"] = agentCommand
        if background { params["background"] = true }
        return try await answer("window.createTask", params, id: "reopened")
    }

    func createTerminalWindow(projectId: String, terminalId: String, cwd: String, title: String, frame: Frame) async throws -> String {
        try await answer("window.createTerminal", ["projectId": projectId, "terminalId": terminalId, "cwd": cwd, "title": title,
                                                   "frame": Self.frame(frame)], id: "terminal-window")
    }

    func createTab(windowId: String, cwd: String, agentCommand: String?, tabKey: String?, background: Bool) async throws -> String {
        var params: [String: Any] = ["windowId": windowId, "cwd": cwd]
        params["agentCommand"] = agentCommand
        params["tabKey"] = tabKey
        if background { params["background"] = true }
        return try await answer("tab.create", params, id: "s-review")
    }

    func activate(windowId: String) async throws { try await answer("window.activate", ["windowId": windowId]) }

    func setFrame(windowId: String, frame: Frame) async throws {
        try await answer("window.setFrame", ["windowId": windowId, "frame": Self.frame(frame)])
    }

    func close(windowId: String) async throws { try await answer("window.close", ["windowId": windowId]) }

    func setSessionTitles(_ titles: [SessionTitle]) async throws -> Int {
        try await answer("sessions.setTitles", ["titles": titles.map { ["sessionId": $0.sessionId, "title": $0.title] }])
        return 0
    }

    func markSeen(taskId: String) async throws -> Int {
        try await answer("sessions.markSeen", ["taskId": taskId])
        return 0
    }

    func setMatchItermBackground(_ enabled: Bool) async throws {
        try await answer("interface.setMatchItermBackground", ["matchItermBackground": enabled])
    }

    func deliver(sessionId: String, text: String, ownership: Int, wake: Bool, worktree: String?) async throws -> Delivery {
        var params: [String: Any] = ["sessionId": sessionId, "text": text, "ownership": ownership, "wake": wake]
        params["worktree"] = worktree
        try await answer("session.deliver", params)
        guard let first = deliveries.first else { return Delivery(result: .delivered, reason: nil) }
        if deliveries.count > 1 { deliveries.removeFirst() }
        return first
    }

    func prompt(sessionId: String) async throws -> PromptKind? {
        try await answer("session.prompt", ["sessionId": sessionId])
        return prompts[sessionId]
    }


    func dismissStartup(sessionId: String) async throws -> Bool {
        try await answer("session.dismissStartup", ["sessionId": sessionId])
        return dismissible.contains(sessionId)
    }

    func deliveryPolicy() async throws -> [AgentKind: DeliveryVerdict] {
        try await answer("delivery.policy", [:])
        return deliveryVerdicts
    }

    func setOwnership(sessionId: String, ownership: Int) async throws {
        try await answer("session.setOwnership", ["sessionId": sessionId, "ownership": ownership])
    }

    func registerOperator(runId: String, token: String) async throws { try await answer("operator.register", ["runId": runId, "token": token]) }

    func revokeOperator(runId: String) async throws { try await answer("operator.revoke", ["runId": runId]) }

    /// Recorded with `result` as the `JSONValue` itself, so a test reads the answer as the operator would.
    func replyToOperator(requestId: String, result: JSONValue?, error: String?) async throws {
        var params: [String: Any] = ["requestId": requestId]
        params["result"] = result
        params["error"] = error
        try await answer("operator.reply", params)
    }
}
