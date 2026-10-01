import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

/// Mutable transport state is protected by `lock`; the writer queue owns writes,
/// and each reader exclusively closes its descriptor. Streams are thread-safe.
public final class DaemonClient: @unchecked Sendable {
    public let socketPath: String
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var nextId = 0
    private var generation = 0
    private struct Pending {
        let continuation: CheckedContinuation<RawMessage, Error>
        let deadline: DispatchWorkItem
        let method: String
    }
    private var pending: [Int: Pending] = [:]
    private let writer = DispatchQueue(label: "aiterm.socket-writer")
    private let requestTimeout: TimeInterval
    private var used = false
    private var eventContinuation: AsyncStream<DaemonEvent>.Continuation?
    public let events: AsyncStream<DaemonEvent>
    private static let maximumFrameBytes = 1 << 20

    public init(socketPath: String, requestTimeout: TimeInterval = 15) {
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
        let stream = AsyncStream<DaemonEvent>.makeStream(bufferingPolicy: .bufferingOldest(512))
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }

    public func connect() throws {
        lock.lock()
        guard !used else { lock.unlock(); throw DaemonError(code: "connection_used", message: "Create a new client to reconnect") }
        used = true
        lock.unlock()
        let address = try UnixSocketAddress(path: socketPath)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw DaemonError(code: "socket", message: String(cString: strerror(errno))) }
        // Without this, writing to a daemon that has gone away raises SIGPIPE, whose default
        // disposition kills the whole app. With it, `writeAll` simply sees EPIPE and reports it.
        var noSigPipe: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var rc = address.withSockaddr { Darwin.connect(s, $0, $1) }
        if rc != 0, errno == EINPROGRESS {
            var descriptor = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, 2_000)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            if ready > 0, getsockopt(s, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 { rc = 0 }
            else { errno = ready == 0 ? ETIMEDOUT : (error == 0 ? errno : error) }
        }
        guard rc == 0 else { let e = errno; Darwin.close(s); throw DaemonError(code: "connect", message: String(cString: strerror(e))) }
        _ = fcntl(s, F_SETFL, flags)
        lock.lock()
        guard eventContinuation != nil else {
            lock.unlock(); Darwin.close(s)
            throw DaemonError(code: "disconnected", message: "Connection was canceled")
        }
        generation += 1; let gen = generation; fd = s
        lock.unlock()
        Thread(block: { self.readLoop(fd: s, generation: gen) }).start()
    }

    /// Tears the connection down and **ends** `events`: the continuation is taken out from under
    /// `lock` and finished exactly once, so a consumer's `for await` over `events` returns instead
    /// of hanging forever on a client that is never coming back. Taking it (rather than only
    /// finishing it) also makes later `yield`s from a stale `readLoop` no-ops, which is the same
    /// guarantee the `generation` bump gives the socket side. A client is single-use once
    /// disconnected: reconnecting it would not revive the stream, so callers make a new client.
    public func disconnect() {
        lock.lock()
        let f = fd; fd = -1; generation += 1
        let waiting = pending; pending = [:]
        let continuation = eventContinuation; eventContinuation = nil
        // The reader takes this lock before closing: shutdown must happen before
        // it can release the descriptor number for another socket to reuse.
        if f >= 0 { shutdown(f, SHUT_RDWR) }
        lock.unlock()
        // Shut the socket down but do NOT close it here: `readLoop` may be blocked in `read(f)`,
        // and closing the descriptor out from under it would free the number for immediate reuse
        // by another `connect()` in this process — the blocked reader would then consume bytes
        // belonging to a brand-new connection. `shutdown` makes the pending `read` return 0, and
        // the reader closes its own descriptor on the way out.
        waiting.values.forEach {
            $0.deadline.cancel()
            $0.continuation.resume(throwing: DaemonError(code: "disconnected", message: "helper connection closed"))
        }
        continuation?.finish()
    }

    /// Reads newline-delimited JSON off `fd` until EOF/error. `generation` is the value captured
    /// at `connect()` time for this specific connection: once `fd` is closed, its integer can be
    /// reused immediately by a later `connect()`, so a blocked `read()` on the stale value could
    /// otherwise observe bytes from — and then tear down — a brand-new connection. Comparing
    /// against the live `self.generation` after the loop exits ensures this reader only tears
    /// things down when it is still the current connection; if a newer `connect()`/`disconnect()`
    /// has already superseded it, that call owns the cleanup.
    private func readLoop(fd: Int32, generation: Int) {
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        reading: while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 10) {
                let line = buffer[..<nl]; buffer.removeSubrange(...nl)
                guard line.count <= Self.maximumFrameBytes,
                      let msg = try? JSONDecoder().decode(RawMessage.self, from: line) else { break reading }
                dispatch(msg)
            }
            if buffer.count > Self.maximumFrameBytes { break }
        }
        // This thread is the sole owner of `fd` (the parameter): `connect()` handed it over and
        // `disconnect()` only shuts it down, so the close below is the one and only close. Clear
        // `self.fd` first, under the lock, so a `disconnect()` arriving after the close cannot
        // `shutdown()` a descriptor number the process has already handed to someone else.
        lock.lock()
        let stillCurrent = generation == self.generation
        if stillCurrent { self.fd = -1 }
        lock.unlock()
        Darwin.close(fd)
        // The stream ending *is* the signal: yielding a synthetic `.itermDisconnected` here blamed
        // iTerm2 for the daemon itself having died (the banner read "Reconnecting to iTerm2…" for a
        // helper that was simply gone). `DaemonConnection` already treats an `events` stream that
        // ends without cancellation as `.helperUnreachable`.
        guard stillCurrent else { return }
        disconnect()
    }

    /// The event continuation read under `lock`, so a reader thread cannot observe it while
    /// `disconnect()` is taking it away; `nil` once the stream has been finished.
    private func liveContinuation() -> AsyncStream<DaemonEvent>.Continuation? {
        lock.lock(); defer { lock.unlock() }
        return eventContinuation
    }

    private func dispatch(_ msg: RawMessage) {
        if let id = msg.id {
            lock.lock(); let cont = pending.removeValue(forKey: id); lock.unlock()
            cont?.deadline.cancel()
            var msg = msg
            if cont?.method == "workspace.snapshot", let snapshot = try? msg.result?.decode(DaemonSnapshot.self) {
                msg.decodedSnapshot = snapshot
                if case .dropped = liveContinuation()?.yield(.snapshot(snapshot)) { disconnect() }
            }
            cont?.continuation.resume(returning: msg)
            return
        }
        guard let name = msg.event else { return }
        if case .dropped = liveContinuation()?.yield(Self.decodeEvent(name, msg.payload)) {
            // An incomplete event history is not trustworthy. Reconnect to a fresh snapshot.
            disconnect()
        }
    }

    static func decodeEvent(_ name: String, _ payload: AnyCodableBox?) -> DaemonEvent {
        struct Version: Decodable { var version: String? }
        struct WindowId: Decodable { var windowId: String }
        struct SessionId: Decodable { var sessionId: String }
        struct Reason: Decodable { var reason: String }
        struct CookieRequest: Decodable { var requestId: Int }
        if name == "iterm.disconnected" { return .itermDisconnected }
        guard let payload else { return .unknown(name) }
        do {
            switch name {
            case "iterm.connected": return .itermConnected(try payload.decode(Version.self).version)
            case "iterm.auth_failed": return .itermAuthFailed(try payload.decode(Reason.self).reason)
            case "iterm.cookieRequested": return .itermCookieRequested(try payload.decode(CookieRequest.self).requestId)
            case "window.activated": return .windowActivated(try payload.decode(WindowId.self).windowId)
            case "window.closed": return .windowClosed(try payload.decode(WindowId.self).windowId)
            case "session.opened": return .sessionOpened(try payload.decode(SessionInfo.self))
            case "session.changed": return .sessionChanged(try payload.decode(SessionInfo.self))
            case "session.closed": return .sessionClosed(try payload.decode(SessionId.self).sessionId)
            case "usage.changed": return .usageChanged(try payload.decode(UsageSnapshot.self))
            default: return .unknown(name)
            }
        } catch { return .unknown(name) }
    }

    private func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        return nextId
    }

    private final class Cancellation: Sendable {
        private let value = Mutex(false)
        func cancel() { value.withLock { $0 = true } }
        var isCancelled: Bool { value.withLock { $0 } }
    }

    private func failRequest(_ id: Int, error: Error) {
        lock.lock(); let entry = pending.removeValue(forKey: id); lock.unlock()
        entry?.deadline.cancel()
        entry?.continuation.resume(throwing: error)
    }

    /// The wire shape of a request: `params` is only ever present for the concrete `P` a call site
    /// hands it, so the daemon sees an ordinary typed request — never the boxed-and-reinflated
    /// `JSONValue` an `any Encodable` would have had to pass through.
    private struct Envelope<P: Encodable>: Encodable {
        let id: Int, method: String, params: P?
        private enum CodingKeys: String, CodingKey { case id, method, params }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params) // omit the key entirely, not `null`
        }
    }
    private struct NoParams: Encodable {}

    public func request<R: Decodable>(_ method: String, as type: R.Type) async throws -> R {
        try await request(method, params: Optional<NoParams>.none, as: type)
    }

    public func request<P: Encodable, R: Decodable>(_ method: String, params: P, as type: R.Type) async throws -> R {
        try await request(method, params: Optional(params), as: type)
    }

    private func request<P: Encodable, R: Decodable>(_ method: String, params: P?, as type: R.Type) async throws -> R {
        try Task.checkCancellation()
        let id = allocateID(), cancellation = Cancellation()
        var encoded = try JSONEncoder().encode(Envelope(id: id, method: method, params: params))
        encoded.append(10)
        let data = encoded
        guard data.count <= Self.maximumFrameBytes else { throw DaemonError(code: "protocol", message: "Request exceeds frame limit") }
        let msg: RawMessage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let deadline = DispatchWorkItem { [weak self] in
                    self?.failRequest(id, error: DaemonError(code: "timeout", message: "\(method) timed out; its outcome may need reconciliation"))
                }
                lock.lock()
                if cancellation.isCancelled {
                    lock.unlock(); cont.resume(throwing: CancellationError()); return
                }
                guard fd >= 0 else {
                    lock.unlock(); cont.resume(throwing: DaemonError(code: "disconnected", message: "not connected")); return
                }
                pending[id] = Pending(continuation: cont, deadline: deadline, method: method)
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + requestTimeout, execute: deadline)
                writer.async { [self] in
                    lock.lock()
                    // dup keeps this descriptor alive even if the reader exits during a write.
                    let socket = pending[id] != nil && fd >= 0 ? dup(fd) : -1
                    lock.unlock()
                    guard socket >= 0 else {
                        failRequest(id, error: DaemonError(code: "disconnected", message: "not connected")); return
                    }
                    defer { Darwin.close(socket) }
                    if let error = Self.writeAll(fd: socket, data: data) {
                        failRequest(id, error: error)
                        disconnect() // a partial JSON frame cannot safely be followed by another
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.failRequest(id, error: CancellationError())
        }
        if let error = msg.error { throw DaemonError(code: error.code, message: error.message) }
        if R.self == Empty.self { return Empty() as! R }
        // `dispatch(_:)` already decoded this reply once to yield it as a `.snapshot` event;
        // reuse that instead of decoding `result` into the same type a second time.
        if let snapshot = msg.decodedSnapshot as? R { return snapshot }
        guard let result = msg.result else { throw DaemonError(code: "protocol", message: "missing result") }
        return try result.decode(R.self)
    }

    /// Writes every byte of `data` to `fd`, retrying on `EINTR` and looping past short
    /// writes, so a partial `write(2)` never silently truncates a request line (which would leave
    /// the daemon waiting on a malformed frame and the caller awaiting forever). Returns the
    /// failure as a `DaemonError`, or `nil` once everything has been written.
    private static func writeAll(fd: Int32, data: Data) -> DaemonError? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> DaemonError? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR { continue }
                return DaemonError(code: "write", message: n < 0 ? String(cString: strerror(errno)) : "short write")
            }
            return nil
        }
    }

    // -- typed helpers -----------------------------------------------------------------
    public struct Empty: Decodable { public init() {} }
    struct WindowResult: Decodable { var windowId: String }
    struct SessionResult: Decodable { var sessionId: String }
    struct ChangedResult: Decodable { var changed: Int }
    struct CreateTaskParams: Encodable { var taskId, cwd, title: String; var agentCommand: String?; var frame: Frame }
    struct CreateTerminalParams: Encodable { var projectId, cwd, title: String; var frame: Frame }
    struct WindowParams: Encodable { var windowId: String; var frame: Frame? }
    struct CreateTabParams: Encodable { var windowId, cwd: String; var agentCommand: String? }
    struct SessionTitlesParams: Encodable { var titles: [SessionTitle] }
    struct TaskParams: Encodable { var taskId: String }
    struct InterfaceParams: Encodable { var matchItermBackground: Bool }
    struct CookieParams: Encodable {
        var requestId: Int; var cookie, key, error: String?; var notRunning: Bool?
        init(requestId: Int, answer: ItermCookieAnswer) {
            self.requestId = requestId
            switch answer {
            case .granted(let cookie, let key): self.cookie = cookie; self.key = key
            case .notRunning: notRunning = true
            case .refused(let reason): error = reason
            }
        }
    }
    struct AcceptedResult: Decodable { var accepted: Bool }

    public func snapshot() async throws -> DaemonSnapshot {
        let snapshot = try await request("workspace.snapshot", as: DaemonSnapshot.self)
        guard snapshot.protocolVersion == 1 else {
            throw DaemonError(code: DaemonError.incompatibleCode, message: "Restart AiTerm with its matching bundled helper")
        }
        return snapshot
    }
    public func createTaskWindow(taskId: String, cwd: String, title: String, agentCommand: String?, frame: Frame) async throws -> String {
        try await request("window.createTask", params: CreateTaskParams(taskId: taskId, cwd: cwd, title: title, agentCommand: agentCommand, frame: frame), as: WindowResult.self).windowId }
    public func createTerminalWindow(projectId: String, cwd: String, title: String, frame: Frame) async throws -> String {
        try await request("window.createTerminal", params: CreateTerminalParams(projectId: projectId, cwd: cwd, title: title, frame: frame), as: WindowResult.self).windowId }
    /// A tab in an existing window, carrying that window's task or project tag.
    public func createTab(windowId: String, cwd: String, agentCommand: String?) async throws -> String {
        try await request("tab.create", params: CreateTabParams(windowId: windowId, cwd: cwd, agentCommand: agentCommand), as: SessionResult.self).sessionId }
    public func activate(windowId: String) async throws { _ = try await request("window.activate", params: WindowParams(windowId: windowId, frame: nil), as: Empty.self) }
    public func setFrame(windowId: String, frame: Frame) async throws { _ = try await request("window.setFrame", params: WindowParams(windowId: windowId, frame: frame), as: Empty.self) }
    public func close(windowId: String) async throws { _ = try await request("window.close", params: WindowParams(windowId: windowId, frame: nil), as: Empty.self) }
    @discardableResult public func setSessionTitles(_ titles: [SessionTitle]) async throws -> Int {
        try await request("sessions.setTitles", params: SessionTitlesParams(titles: titles), as: ChangedResult.self).changed
    }
    public func markSeen(taskId: String) async throws -> Int { try await request("sessions.markSeen", params: TaskParams(taskId: taskId), as: ChangedResult.self).changed }
    /// Answers `iterm.cookieRequested`. False when the request had already timed out or been
    /// answered, so the cookie was not used.
    @discardableResult public func provideCookie(requestId: Int, _ answer: ItermCookieAnswer) async throws -> Bool {
        try await request("iterm.provideCookie", params: CookieParams(requestId: requestId, answer: answer), as: AcceptedResult.self).accepted
    }
    /// Applies the Interface preference to every terminal window AiTerm manages. The daemon keeps
    /// this session-scoped, so no iTerm2 profile is edited.
    public func setMatchItermBackground(_ enabled: Bool) async throws {
        _ = try await request("interface.setMatchItermBackground", params: InterfaceParams(matchItermBackground: enabled), as: Empty.self)
    }
}
