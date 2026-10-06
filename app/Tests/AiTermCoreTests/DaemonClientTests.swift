import Testing
import Foundation
import Synchronization
@testable import AiTermCore
@testable import AiTermTestSupport

/// Wraps an `AsyncStream<DaemonEvent>.AsyncIterator` in a reference type so it can be shared with
/// the deadline-racing `Task` in `nextEvent(_:timeoutSeconds:)` below without re-deriving a fresh
/// iterator (which would drop events) on every call.
///
/// Unchecked because the iterator is mutable: `nextEvent` settles each `next()` before the next call.
private final class EventBox: @unchecked Sendable {
    private var iterator: AsyncStream<DaemonEvent>.AsyncIterator
    init(_ stream: AsyncStream<DaemonEvent>) { iterator = stream.makeAsyncIterator() }
    func next() async -> DaemonEvent? { await iterator.next() }
}

private enum NextEventResult { case event(DaemonEvent?), timedOut }

/// Races `box.next()` against a timeout so a dropped/never-sent event fails the test with a
/// recorded `Issue` instead of hanging the whole suite.
private func nextEvent(_ box: EventBox, timeoutSeconds: Double = 2) async -> NextEventResult {
    await withTaskGroup(of: NextEventResult.self) { group in
        group.addTask { .event(await box.next()) }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            return .timedOut
        }
        let result = await group.next() ?? .timedOut
        group.cancelAll()
        return result
    }
}

final class DaemonClientTests {
    var server: FakeSocketServer!
    var client: DaemonClient!

    init() {
        let path = "/tmp/aiterm-test-\(UUID().uuidString.prefix(8)).sock"
        server = FakeSocketServer(path: path); server.start()
        client = DaemonClient(socketPath: path)
    }
    deinit { client.disconnect(); server.stop() }

    @Test func testTypedRequestRoundTrip() async throws {
        server.handler = { req in
            #expect(req["method"] as? String == "window.createTask")
            return ["id": req["id"]!, "result": ["windowId": "w7"]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let id = try await client.createTaskWindow(taskId: "t1", cwd: "/wt", title: "x", agentCommand: "claude", frame: Frame(x: 1, y: 2, w: 3, h: 4))
        #expect(id == "w7")
        let params = server.received.first?["params"] as? [String: Any]
        #expect(params?["taskId"] as? String == "t1")
        #expect((params?["frame"] as? [String: Any])?["w"] as? Double == 3)
    }

    /// A review opened in its task's window: the daemon tags the tab with the window's task, and
    /// `cwd` is what keeps it in the task's worktree whatever the active tab is doing.
    @Test func testCreateTabSendsTheWindowCwdAndCommand() async throws {
        server.handler = { req in
            #expect(req["method"] as? String == "tab.create")
            return ["id": req["id"]!, "result": ["sessionId": "s9"]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let id = try await client.createTab(windowId: "w1", cwd: "/wt", agentCommand: "claude '/code-review'")
        #expect(id == "s9")
        let params = server.received.first?["params"] as? [String: Any]
        #expect(params?["windowId"] as? String == "w1")
        #expect(params?["cwd"] as? String == "/wt")
        #expect(params?["agentCommand"] as? String == "claude '/code-review'")
    }

    /// The terminal's name titles its iTerm2 window, so it has to reach the daemon.
    @Test func testCreateTerminalSendsTheTerminalName() async throws {
        server.handler = { req in
            #expect(req["method"] as? String == "window.createTerminal")
            return ["id": req["id"]!, "result": ["windowId": "w3"]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let id = try await client.createTerminalWindow(projectId: "p1", cwd: "/repo", title: "Logs", frame: Frame(x: 1, y: 2, w: 3, h: 4))
        #expect(id == "w3")
        let params = server.received.first?["params"] as? [String: Any]
        #expect(params?["projectId"] as? String == "p1")
        #expect(params?["title"] as? String == "Logs")
    }

    @Test func testInterfaceBackgroundPreferenceReachesTheDaemon() async throws {
        server.handler = { req in
            #expect(req["method"] as? String == "interface.setMatchItermBackground")
            return ["id": req["id"]!, "result": [:]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        try await client.setMatchItermBackground(true)
        let params = server.received.first?["params"] as? [String: Any]
        #expect(params?["matchItermBackground"] as? Bool == true)
    }

    @Test func testSessionTitlesReachTheDaemonAsOneBatch() async throws {
        server.handler = { req in
            #expect(req["method"] as? String == "sessions.setTitles")
            return ["id": req["id"]!, "result": ["changed": 2]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let changed = try await client.setSessionTitles([
            SessionTitle(sessionId: "s1", title: "feat/one"),
            SessionTitle(sessionId: "s2", title: "main"),
        ])
        #expect(changed == 2)
        let params = server.received.first?["params"] as? [String: Any]
        let titles = params?["titles"] as? [[String: Any]]
        #expect(titles?.first?["sessionId"] as? String == "s1")
        #expect(titles?.first?["title"] as? String == "feat/one")
    }

    @Test func testErrorResponseThrowsDaemonError() async throws {
        server.handler = { req in ["id": req["id"]!, "error": ["code": "not_found", "message": "no such window"]] }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        do { try await client.activate(windowId: "nope"); Issue.record("expected throw") }
        catch let e as DaemonError { #expect(e == DaemonError(code: "not_found", message: "no such window")) }
    }

    @Test func testEventsAreDecoded() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        server.push(event: "iterm.connected", payload: ["version": "3.7.2"])
        server.push(event: "window.activated", payload: ["windowId": "w1"])
        server.push(event: "session.changed", payload: ["sessionId": "s1", "windowId": "w1", "tabIndex": 0, "taskId": "t1", "projectId": NSNull(), "agent": "claude", "model": "claude-opus-5", "state": "working", "title": "✳", "cwd": "/wt"])
        server.push(event: "usage.changed", payload: ["claude": ["fiveHour": ["usedPercent": 23, "resetsAt": 99], "sevenDay": NSNull(), "spend": NSNull(), "plan": NSNull(), "updatedAt": 1], "codex": NSNull()])

        guard case .event(let e1) = await nextEvent(box) else { Issue.record("timed out waiting for iterm.connected event"); return }
        #expect(e1 == .itermConnected("3.7.2"))

        guard case .event(let e2) = await nextEvent(box) else { Issue.record("timed out waiting for session.changed event"); return }
        #expect(e2 == .windowActivated("w1"))

        guard case .event(let e5) = await nextEvent(box) else { Issue.record("timed out waiting for session.changed event"); return }
        guard case .sessionChanged(let s)? = e5 else { Issue.record("expected .sessionChanged"); return }
        #expect(s.state == .working); #expect(s.model == "claude-opus-5")

        guard case .event(let e6) = await nextEvent(box) else { Issue.record("timed out waiting for usage.changed event"); return }
        guard case .usageChanged(let u)? = e6 else { Issue.record("expected .usageChanged"); return }
        #expect(u.claude?.fiveHour?.usedPercent == 23); #expect(u.codex == nil)

        // A later snapshot replaces the first wholesale: the vendor that went quiet is nil again.
        server.push(event: "usage.changed", payload: ["claude": NSNull(), "codex": ["fiveHour": NSNull(), "sevenDay": ["usedPercent": 12, "resetsAt": 88], "spend": NSNull(), "plan": "pro", "updatedAt": 2]])
        guard case .event(let e7) = await nextEvent(box) else { Issue.record("timed out waiting for second usage.changed event"); return }
        guard case .usageChanged(let u2)? = e7 else { Issue.record("expected .usageChanged"); return }
        #expect(u2.codex?.sevenDay?.usedPercent == 12)
        #expect(u2.claude == nil)
    }

    /// The branch a row shows is resolved from `effectiveCwd`, never from `cwd`: iTerm2 only ever
    /// reports the shell's directory, which does not follow an agent into a worktree.
    @Test func testSessionInfoPrefersTheAgentsCwd() throws {
        let moved = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"claude","model":null,"state":"idle","title":"","cwd":"/repo","agentCwd":"/repo/.worktrees/feat","active":true}"#
        let a = try JSONDecoder().decode(SessionInfo.self, from: Data(moved.utf8))
        #expect(a.effectiveCwd == "/repo/.worktrees/feat")
        #expect(a.active == true)

        // An older daemon, or a plain shell tab: no agentCwd, no active flag.
        let plain = #"{"sessionId":"s2","windowId":"w1","tabIndex":1,"taskId":null,"projectId":null,"agent":"shell","model":null,"state":"idle","title":"","cwd":"/repo"}"#
        let b = try JSONDecoder().decode(SessionInfo.self, from: Data(plain.utf8))
        #expect(b.effectiveCwd == "/repo")
        #expect(b.active == nil)
    }

    /// No synthetic `.itermDisconnected` here: the daemon dying is not the same fact as iTerm2
    /// going away, and yielding it blamed iTerm2 for a helper that had simply exited. The stream
    /// ending, with no event, is the whole signal — `DaemonConnection` reads it as `.helperUnreachable`.
    @Test func testEventStreamEndsWhenTheConnectionCloses() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        server.stop()

        guard case .event(let end) = await nextEvent(box) else { Issue.record("the event stream never ended after the connection closed"); return }
        #expect(end == nil)
    }

    @Test func testDisconnectEndsTheEventStream() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        client.disconnect()

        guard case .event(let end) = await nextEvent(box) else { Issue.record("the event stream never ended after disconnect()"); return }
        #expect(end == nil)
    }

    @Test func silentRequestTimesOutAndDoesNotPoisonSubsequentRequests() async throws {
        client = DaemonClient(socketPath: server.path, requestTimeout: 0.08)
        server.handler = { _ in nil }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        struct Status: Decodable { var connected: Bool }
        do { _ = try await client.request("iterm.status", as: Status.self); Issue.record("Expected deadline") }
        catch let error as DaemonError { #expect(error.code == "timeout") }
        // A timeout does not corrupt framing or poison subsequent requests.
        server.handler = { req in ["id": req["id"]!, "result": ["connected": true]] }
        #expect(try await client.request("iterm.status", as: Status.self).connected)
    }

    /// A separate, long-timeout client: racing cancellation against an 80ms request timeout (as a
    /// single client covering both halves used to) is flaky under load, where a slow scheduler can
    /// let the 20ms cancel arrive after the deadline already fired.
    @Test func cancellingARequestFinishesPromptlyWithoutWaitingForItsTimeout() async throws {
        let path = "/tmp/aiterm-test-\(UUID().uuidString.prefix(8)).sock"
        let longWaitServer = FakeSocketServer(path: path); longWaitServer.start()
        defer { longWaitServer.stop() }
        longWaitServer.handler = { _ in nil }
        let longWaitClient = DaemonClient(socketPath: path, requestTimeout: 30)
        defer { longWaitClient.disconnect() }
        try longWaitClient.connect()
        #expect(longWaitServer.waitForClient(timeout: 2))
        struct Status: Decodable { var connected: Bool }
        let waiting = Task { try await longWaitClient.request("iterm.status", as: Status.self) }
        await eventually { !longWaitServer.received.isEmpty }
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
    }

    @Test func concurrentRequestsKeepTheirFramesAndResponses() async throws {
        server.handler = { req in ["id": req["id"]!, "result": req["params"]!] }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let client: DaemonClient = self.client
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let value = String(repeating: "payload-\(index)", count: 2000)
                    let reply = try await client.request("echo", params: value, as: String.self)
                    #expect(reply == value)
                }
            }
            try await group.waitForAll()
        }
        #expect(server.received.count == 40)
    }

    @Test func missingEventPayloadsNeverCrash() {
        for name in ["window.activated", "window.closed", "session.opened", "session.changed", "session.closed", "usage.changed"] {
            #expect(DaemonClient.decodeEvent(name, from: Data(#"{"event":"\#(name)"}"#.utf8)) == .unknown(name))
        }
        #expect(DaemonClient.decodeEvent("iterm.disconnected", from: Data(#"{"event":"iterm.disconnected"}"#.utf8)) == .itermDisconnected)
    }

    /// The reader searches only the bytes each read adds and carries an unfinished line over: a line
    /// that arrives a few bytes at a time, and a read holding one line and the start of the next,
    /// each come out whole and in order.
    @MainActor @Test func linesSplitAcrossReadsArriveWholeAndInOrder() async throws {
        let server = try await PythonSocketServer.start(script: """
import json,socket,sys,time
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]);s.listen()
c,_=s.accept()
line=lambda w:(json.dumps({'event':'window.closed','payload':{'windowId':w}})+'\\n').encode()
a,b,d=line('a'),line('b'),line('c')
for i in range(0,len(a),3):
 c.sendall(a[i:i+3]);time.sleep(0.002)
c.sendall(b+d[:10]);time.sleep(0.02);c.sendall(d[10:])
time.sleep(5)
""")
        defer { server.stop() }
        let client = DaemonClient(socketPath: server.path)
        defer { client.disconnect() }
        try client.connect()
        let box = EventBox(client.events)
        for windowId in ["a", "b", "c"] {
            guard case .event(let event) = await nextEvent(box) else { Issue.record("timed out waiting for window \(windowId)"); return }
            #expect(event == .windowClosed(windowId))
        }
    }

    /// A payload is decoded straight into its type from the line's bytes: no number passes through
    /// `Double` on the way, which could not hold an integer above 2^53 exactly.
    @Test func eventIntegersArriveExactly() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        let large = (1 << 53) + 1
        server.push(event: "iterm.cookieRequested", payload: ["requestId": large])
        guard case .event(let event) = await nextEvent(box) else { Issue.record("timed out waiting for the event"); return }
        #expect(event == .itermCookieRequested(large))
    }

    private func timeOut(_ client: DaemonClient, sourceLocation: SourceLocation = #_sourceLocation) async {
        do { _ = try await client.request("window.activate", as: DaemonClient.Empty.self); Issue.record("Expected a timeout", sourceLocation: sourceLocation) }
        catch { #expect((error as? DaemonError)?.code == "timeout", sourceLocation: sourceLocation) }
    }

    /// CS-6: a daemon whose loop is stuck keeps its socket open and its process alive, so neither
    /// the reader nor the supervisor notices. Two timeouts in a row prompt a liveness check, and a
    /// check that goes unanswered as well drops the connection so its owner reconnects.
    @Test func aHelperThatAnswersNothingIsDropped() async throws {
        client = DaemonClient(socketPath: server.path, requestTimeout: 0.05, livenessTimeout: 0.1)
        server.handler = { _ in nil }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        let box = EventBox(client.events)
        await timeOut(client)
        await timeOut(client)
        guard case .event(let end) = await nextEvent(box) else { Issue.record("a wedged helper kept its connection"); return }
        #expect(end == nil)
        #expect(server.received.contains { $0["method"] as? String == DaemonClient.livenessCheck })
    }

    /// Requests queued behind one of the helper's locks while iTerm2 is slow time out back to back
    /// from a helper whose loop is fine: it answers the liveness check, and the connection stays.
    @Test func timeoutsFromAHelperThatStillAnswersKeepTheConnection() async throws {
        client = DaemonClient(socketPath: server.path, requestTimeout: 0.05, livenessTimeout: 2)
        server.handler = { req in req["method"] as? String == DaemonClient.livenessCheck ? ["id": req["id"]!, "result": ["connected": false]] : nil }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        func checks() -> Int { server.received.count { $0["method"] as? String == DaemonClient.livenessCheck } }
        for round in 1...2 {
            await timeOut(client)
            await timeOut(client)
            try #require(await eventually(describing: "round \(round)'s check") { checks() == 2 * round - 1 })
            // Sent once the server holds the check, so answered after it in wire order: the check's
            // reply has been read, ending this run of timeouts, before the next round's first one.
            _ = try await client.request(DaemonClient.livenessCheck, as: DaemonClient.Empty.self)
        }
        #expect(checks() == 4, "one check per run of timeouts, and one request per round after it")
    }

    /// One reply between two timeouts is a helper that is answering: only an unbroken run counts.
    /// Long enough a timeout that an answered request is never mistaken for one under load.
    @Test func aReplyBetweenTimeoutsKeepsTheConnection() async throws {
        client = DaemonClient(socketPath: server.path, requestTimeout: 0.5, livenessTimeout: 0.1)
        let answering = Mutex(false)
        server.handler = { req in answering.withLock { $0 } ? ["id": req["id"]!, "result": [:]] : nil }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        await timeOut(client)
        answering.withLock { $0 = true }
        _ = try await client.request("window.activate", as: DaemonClient.Empty.self)
        answering.withLock { $0 = false }
        await timeOut(client)
        answering.withLock { $0 = true }
        _ = try await client.request("window.activate", as: DaemonClient.Empty.self)
        #expect(!server.received.contains { $0["method"] as? String == DaemonClient.livenessCheck })
    }

    @Test func snapshotAppearsInWireOrderAsAnEventBarrier() async throws {
        server.handler = { req in
            ["id": req["id"]!, "result": ["protocolVersion": 1, "connected": true, "sessions": [], "usage": ["claude": NSNull(), "codex": NSNull()]]]
        }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        server.push(event: "window.closed", payload: ["windowId": "old"])
        let snapshot = try await client.snapshot()
        server.push(event: "window.closed", payload: ["windowId": "new"])
        let box = EventBox(client.events)
        guard case .event(let old) = await nextEvent(box) else { Issue.record("missing old event"); return }
        guard case .event(let barrier) = await nextEvent(box) else { Issue.record("missing barrier"); return }
        guard case .event(let new) = await nextEvent(box) else { Issue.record("missing new event"); return }
        #expect(old == .windowClosed("old"))
        #expect(barrier == .snapshot(snapshot))
        #expect(new == .windowClosed("new"))
    }

    @Test func eventOverflowEndsTheStreamSoTheOwnerCanResynchronize() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        for index in 0..<600 { server.push(event: "window.closed", payload: ["windowId": "w\(index)"]) }
        // Do not consume while the reader is still filling the bounded queue.
        // A request behind those frames provides a deterministic processing barrier.
        do { _ = try await client.request("echo", as: DaemonClient.Empty.self); Issue.record("Expected overflow disconnect") }
        catch let error as DaemonError { #expect(error.code == "disconnected") }
        let box = EventBox(client.events)
        var received = 0
        while case .event(let event) = await nextEvent(box) {
            guard event != nil else { #expect(received == 512); return }
            received += 1
        }
        Issue.record("Overflow must finish the stream")
    }

    @Test func oversizedIncomingFrameDisconnects() async throws {
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
        server.push(event: "unknown", payload: String(repeating: "x", count: (1 << 20) + 1))
        let box = EventBox(client.events)
        guard case .event(let end) = await nextEvent(box) else { Issue.record("Stream remained open"); return }
        #expect(end == nil)
    }

    @Test func testConnectToMissingSocketThrows() {
        #expect(throws: (any Error).self) { try DaemonClient(socketPath: "/tmp/does-not-exist.sock").connect() }
    }
}
