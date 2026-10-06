import Foundation
import os
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
    /// A request waiting for its reply. Its closures know the type the caller awaits, so the reader
    /// decodes the reply once, straight into that type, and resumes the caller with it.
    private struct Pending {
        let deadline: DispatchWorkItem
        /// Decodes the reply line and resumes the caller. A reply that also stands for an event
        /// (`snapshot()`'s) hands it to `yield` first, so it takes its place in the stream in
        /// wire order, before the caller resumes.
        let answer: (_ line: Data, _ decoder: JSONDecoder, _ yield: (DaemonEvent) -> Void) -> Void
        let fail: (Error) -> Void
    }
    private var pending: [Int: Pending] = [:]
    /// Requests that timed out since the last reply of any kind.
    private var consecutiveTimeouts = 0
    /// A helper whose loop is stuck still has its process and its socket, so neither the supervisor
    /// nor the reader notices it. It answers each request on its own task, so a slow one (a window
    /// waiting on iTerm2) never holds up another's reply: two timeouts with no reply between them
    /// are a full timeout's silence across two requests. One would drop the connection over a
    /// single slow iTerm2 call; a third would leave the app waiting out another timeout on a helper
    /// already not answering. A false alarm costs one reconnect and a fresh snapshot.
    static let timeoutsBeforeDisconnect = 2
    private let writer = DispatchQueue(label: "aiterm.socket-writer")
    private let requestTimeout: TimeInterval
    private var used = false
    private var eventContinuation: AsyncStream<DaemonEvent>.Continuation?
    public let events: AsyncStream<DaemonEvent>
    private static let maximumFrameBytes = 1 << 20
    private static let log = Logger(subsystem: "com.laurensdhondt.aiterm", category: "daemon")

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
            $0.fail(DaemonError(code: "disconnected", message: "helper connection closed"))
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
        let decoder = JSONDecoder()
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        // The bytes at the front of `buffer` already searched for a newline: only what a read adds
        // is searched, so a large frame arriving in pieces is not rescanned from its start each time.
        var searched = 0
        reading: while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(chunk, count: n)
            var lineStart = buffer.startIndex
            var searchFrom = buffer.startIndex + searched
            while let nl = buffer[searchFrom...].firstIndex(of: 10) {
                let line = buffer[lineStart..<nl]
                guard line.count <= Self.maximumFrameBytes,
                      let header = try? decoder.decode(Header.self, from: line) else { break reading }
                dispatch(header, line: line, decoder: decoder)
                lineStart = nl + 1; searchFrom = lineStart
            }
            // Once per read rather than per line: only an unfinished line is carried over.
            buffer.removeSubrange(buffer.startIndex..<lineStart)
            searched = buffer.count
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

    private func dispatch(_ header: Header, line: Data, decoder: JSONDecoder) {
        if let id = header.id {
            lock.lock()
            let request = pending.removeValue(forKey: id)
            consecutiveTimeouts = 0 // even a late reply is a helper that answers
            lock.unlock()
            guard let request else { return }
            request.deadline.cancel()
            if let error = header.error { request.fail(DaemonError(code: error.code, message: error.message)); return }
            request.answer(line, decoder, yield)
            return
        }
        guard let name = header.event else { return }
        yield(Self.decodeEvent(name, from: line, using: decoder))
    }

    private func yield(_ event: DaemonEvent) {
        if case .dropped = liveContinuation()?.yield(event) {
            // An incomplete event history is not trustworthy. Reconnect to a fresh snapshot.
            disconnect()
        }
    }

    /// The event a line names, decoded from its bytes. An event this app does not know is a newer
    /// helper's and is passed on as `.unknown`; one it knows but cannot read is logged, since the
    /// row it was about is left as it was.
    static func decodeEvent(_ name: String, from line: Data, using decoder: JSONDecoder = JSONDecoder()) -> DaemonEvent {
        struct Version: Decodable { var version: String? }
        struct WindowId: Decodable { var windowId: String }
        struct SessionId: Decodable { var sessionId: String }
        struct Reason: Decodable { var reason: String }
        struct CookieRequest: Decodable { var requestId: Int }
        func payload<P: Decodable>(_: P.Type) throws -> P {
            let event = try decoder.decode(EventPayload<P>.self, from: line)
            return event.payload
        }
        do {
            switch name {
            case "iterm.disconnected": return .itermDisconnected
            case "iterm.connected": return .itermConnected(try payload(Version.self).version)
            case "iterm.auth_failed": return .itermAuthFailed(try payload(Reason.self).reason)
            case "iterm.cookieRequested": return .itermCookieRequested(try payload(CookieRequest.self).requestId)
            case "window.activated": return .windowActivated(try payload(WindowId.self).windowId)
            case "window.closed": return .windowClosed(try payload(WindowId.self).windowId)
            case "session.opened": return .sessionOpened(try payload(SessionInfo.self))
            case "session.changed": return .sessionChanged(try payload(SessionInfo.self))
            case "session.closed": return .sessionClosed(try payload(SessionId.self).sessionId)
            case "usage.changed": return .usageChanged(try payload(UsageSnapshot.self))
            default: return .unknown(name)
            }
        } catch {
            log.error("Unreadable \(name, privacy: .public) event from the helper: \(String(describing: error), privacy: .public)")
            return .unknown(name)
        }
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
        entry?.fail(error)
    }

    private func timedOut(_ id: Int, method: String) {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        if entry != nil { consecutiveTimeouts += 1 }
        let wedged = entry != nil && consecutiveTimeouts >= Self.timeoutsBeforeDisconnect
        lock.unlock()
        entry?.fail(DaemonError(code: "timeout", message: "\(method) timed out; its outcome may need reconciliation"))
        if wedged { disconnect() }
    }

    /// A reply's `result`, decoded from its line. `Empty` asks for nothing, so nothing is read: a
    /// helper may answer it with `{}`, `null` or no result at all.
    private static func result<R: Decodable>(_: R.Type, from line: Data, using decoder: JSONDecoder) throws -> R {
        if let empty = Empty() as? R { return empty }
        return try decoder.decode(Reply<R>.self, from: line).result
    }

    /// The wire shape of a request: `params` is only ever present for the concrete `P` a call site
    /// hands it, so it is encoded as that type, with no untyped value in between.
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

    public func request<R: Decodable & Sendable>(_ method: String, as type: R.Type) async throws -> R {
        try await request(method, params: Optional<NoParams>.none, as: type, ordered: nil)
    }

    public func request<P: Encodable, R: Decodable & Sendable>(_ method: String, params: P, as type: R.Type) async throws -> R {
        try await request(method, params: Optional(params), as: type, ordered: nil)
    }

    /// `ordered` makes the reply an event too, yielded from the reader thread in its place among
    /// the events around it.
    private func request<P: Encodable, R: Decodable & Sendable>(_ method: String, params: P?, as type: R.Type,
                                                                ordered: (@Sendable (R) -> DaemonEvent)?) async throws -> R {
        try Task.checkCancellation()
        let id = allocateID(), cancellation = Cancellation()
        var encoded = try JSONEncoder().encode(Envelope(id: id, method: method, params: params))
        encoded.append(10)
        let data = encoded
        guard data.count <= Self.maximumFrameBytes else { throw DaemonError(code: "protocol", message: "Request exceeds frame limit") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<R, Error>) in
                let deadline = DispatchWorkItem { [weak self] in self?.timedOut(id, method: method) }
                let request = Pending(deadline: deadline, answer: { line, decoder, yield in
                    do {
                        let value = try Self.result(R.self, from: line, using: decoder)
                        if let ordered { yield(ordered(value)) }
                        cont.resume(returning: value)
                    } catch { cont.resume(throwing: error) }
                }, fail: { cont.resume(throwing: $0) })
                lock.lock()
                if cancellation.isCancelled {
                    lock.unlock(); cont.resume(throwing: CancellationError()); return
                }
                guard fd >= 0 else {
                    lock.unlock(); cont.resume(throwing: DaemonError(code: "disconnected", message: "not connected")); return
                }
                pending[id] = request
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
    public struct Empty: Decodable, Sendable { public init() {} }
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

    /// The daemon's state, which is also yielded as `.snapshot` in the event stream: the daemon
    /// writes it with no pause after reading its state, so it is a barrier between the events
    /// before it and those after.
    public func snapshot() async throws -> DaemonSnapshot {
        let snapshot = try await request("workspace.snapshot", params: Optional<NoParams>.none, as: DaemonSnapshot.self,
                                         ordered: { .snapshot($0) })
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
