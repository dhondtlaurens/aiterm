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
    var sessionsValue: [SessionInfo] = []
    var onRequest: (String) -> Void = { _ in }
    /// An individual reply can be held after entry, before its current failure/result is read.
    var beforeReply: (@MainActor (String) async -> Void)?
    /// The code each method fails with: one of the app's, or one only a newer helper would send.
    var failing: [String: DaemonError.Code]
    /// What `session.deliver` answers, in order, the last one repeated; delivered when empty.
    var deliveries: [Delivery] = []
    var idleClosures: [Delivery] = []
    /// What `session.inputState` answers, by session: empty when not set.
    var inputStates: [String: InputState] = [:]
    /// What `delivery.policy` answers: both agents checked at the versions the scratch ports say are installed.
    var deliveryVerdicts: [AgentKind: DeliveryVerdict] = [.claude: DeliveryVerdict(policy: .auto, version: "2.1.301"),
                                                          .codex: DeliveryVerdict(policy: .auto, version: "0.160.0")]
    /// What `commandError` the window and tab creation calls answer, by method (`window.createTask`, `tab.create`): an
    /// agent command the daemon could not type.
    var commandErrors: [String: String] = [:]
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
        if let beforeReply { await beforeReply(method) }
        if method == holding, !released { await withCheckedContinuation { held.append($0) } }
        replies[method, default: 0] += 1
        let count = replies[method, default: 1]
        if let code = failing[method] { throw DaemonError(code: code, message: "test failure") }
        return count == 1 ? id : "\(id)-\(count)"
    }

    private static func frame(_ frame: Frame) -> [String: Any] { ["x": frame.x, "y": frame.y, "w": frame.w, "h": frame.h] }

    func sessions() async throws -> [SessionInfo] {
        try await answer("sessions.list", [:])
        return sessionsValue
    }

    func createTaskWindow(taskId: String, cwd: String, title: String, agentCommand: String?, frame: Frame, background: Bool, worker: Bool) async throws -> Opening {
        var params: [String: Any] = ["taskId": taskId, "cwd": cwd, "title": title, "frame": Self.frame(frame)]
        params["agentCommand"] = agentCommand
        if worker { params["worker"] = true }
        params["background"] = background
        let id = try await answer("window.createTask", params, id: "reopened")
        return Opening(id: id, commandError: commandErrors["window.createTask"])
    }

    func createTerminalWindow(projectId: String, terminalId: String, cwd: String, title: String, frame: Frame) async throws -> String {
        try await answer("window.createTerminal", ["projectId": projectId, "terminalId": terminalId, "cwd": cwd, "title": title,
                                                   "frame": Self.frame(frame)], id: "terminal-window")
    }

    func createTab(windowId: String, cwd: String, agentCommand: String?, tabKey: String?, background: Bool, worker: Bool) async throws -> Opening {
        var params: [String: Any] = ["windowId": windowId, "cwd": cwd]
        params["agentCommand"] = agentCommand
        params["tabKey"] = tabKey
        if worker { params["worker"] = true }
        params["background"] = background
        let id = try await answer("tab.create", params, id: "s-review")
        return Opening(id: id, commandError: commandErrors["tab.create"])
    }

    func setWorkerSessions(taskId: String, sessionIds: [String], released: Bool, ownership: Int) async throws {
        try await answer("task.setWorkerSessions", ["taskId": taskId, "sessionIds": sessionIds, "released": released, "ownership": ownership])
    }
    func activate(windowId: String) async throws { try await answer("window.activate", ["windowId": windowId]) }

    func activate(sessionId: String) async throws { try await answer("session.activate", ["sessionId": sessionId]) }

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

    func deliver(sessionId: String, text: String, ownership: Int, wake: Bool, guardInput: Bool, worktree: String?) async throws -> Delivery {
        var params: [String: Any] = ["sessionId": sessionId, "text": text, "ownership": ownership, "wake": wake]
        if guardInput { params["guardInput"] = true }
        params["worktree"] = worktree
        try await answer("session.deliver", params)
        guard let first = deliveries.first else { return Delivery(result: .delivered, reason: nil) }
        if deliveries.count > 1 { deliveries.removeFirst() }
        return first
    }

    func closeIdle(sessionId: String, ownership: Int, conversation: String) async throws -> Delivery {
        try await answer("session.closeIdle", ["sessionId": sessionId, "ownership": ownership, "conversation": conversation])
        guard let first = idleClosures.first else { return Delivery(result: .delivered, reason: nil) }
        if idleClosures.count > 1 { idleClosures.removeFirst() }
        return first
    }
    func inputState(sessionId: String) async throws -> InputState {
        try await answer("session.inputState", ["sessionId": sessionId])
        return inputStates[sessionId] ?? .empty
    }
    func deliveryPolicy() async throws -> [AgentKind: DeliveryVerdict] {
        try await answer("delivery.policy", [:])
        return deliveryVerdicts
    }

    func setOwnership(sessionId: String, ownership: Int) async throws {
        try await answer("session.setOwnership", ["sessionId": sessionId, "ownership": ownership])
    }


    func registerOperator(operatorId: String, token: String, generation: Int) async throws {
        try await answer("operator.register", ["operatorId": operatorId, "token": token, "generation": generation])
    }
    func revokeOperator(operatorId: String, generation: Int) async throws {
        try await answer("operator.revoke", ["operatorId": operatorId, "generation": generation])
    }

    /// Recorded with `result` as the `JSONValue` itself, so a test reads the answer as the operator would.
    func replyToOperator(requestId: String, result: JSONValue?, error: String?) async throws {
        var params: [String: Any] = ["requestId": requestId]
        params["result"] = result
        params["error"] = error
        try await answer("operator.reply", params)
    }
}
