import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

extension AppControllerTests {
    /// How many times the app sends the background preference to a daemon whose first snapshot
    /// says `connectedAtAttach`, and which — when it was not — then connects iTerm2 and says so.
    private func backgroundSends(connectedAtAttach: Bool) async throws -> Int {
        let path = "/tmp/at-\(UUID().uuidString.prefix(8)).sock"
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-background-\(UUID().uuidString).log")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
import json,socket,sys
path,log,attached=sys.argv[1:]
s=socket.socket(socket.AF_UNIX)
s.bind(path);s.listen()
c,_=s.accept()
snapshots=0
with c:
 f=c.makefile('rb')
 for line in f:
  message=json.loads(line)
  method=message['method']
  with open(log,'a') as output: output.write(method+'\\n')
  if method=='workspace.snapshot':
   snapshots+=1
   result={'protocolVersion':1,'connected':attached=='1' or snapshots>1,'sessions':[],'usage':{'claude':None,'codex':None}}
   c.sendall((json.dumps({'id':message['id'],'result':result})+'\\n').encode())
   if snapshots==1 and attached!='1':
    c.sendall((json.dumps({'event':'iterm.connected','payload':{'version':'3.7.2'}})+'\\n').encode())
  else:
   c.sendall((json.dumps({'id':message['id'],'result':{}})+'\\n').encode())
""", path, log.path, connectedAtAttach ? "1" : "0"]
        server.standardError = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        try server.run()

        let preferences = InterfacePreferences.scratch()
        preferences.matchItermBackground = true
        let controller = AppController(preferences: preferences)
        let connection = DaemonConnection(socketPath: path,
            onClient: { controller.helper.setDaemonClient($0) },
            onStatus: { _ in },
            onEvent: { controller.helper.handle($0) })
        defer {
            connection.stop()
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(at: log)
        }
        connection.start()

        func backgroundRequestCount() -> Int {
            let methods = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return methods.split(separator: "\n").count { $0 == "interface.setMatchItermBackground" }
        }
        let deadline = TestDeadline.fromNow()
        while backgroundRequestCount() < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        return backgroundRequestCount()
    }

    /// The daemon applies the preference only while iTerm2 is connected, so it is sent when iTerm2
    /// connects — here, after the app attached — and only then.
    @Test func itermReconnectReappliesPersistedBackgroundPreference() async throws {
        #expect(try await backgroundSends(connectedAtAttach: false) == 1)
    }

    /// A daemon that already has iTerm2 — adopted, or reached again after the app's socket dropped —
    /// broadcasts no `iterm.connected`; the attach snapshot is the only news, and it sends once.
    @Test func attachingToADaemonThatHasItermSendsTheBackgroundPreferenceOnce() async throws {
        #expect(try await backgroundSends(connectedAtAttach: true) == 1)
    }

    @Test func socketLossReconnectsWhileServerStaysAliveAndStopEndsRetries() async throws {
        let path = "/tmp/at-\(UUID().uuidString.prefix(8)).sock"
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
import socket,json,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]);s.listen()
count=0
while True:
 c,_=s.accept();count+=1
 with c:
  f=c.makefile('rb')
  for line in f:
   m=json.loads(line)
   result={'protocolVersion':1,'connected':True,'sessions':[],'usage':{'claude':None,'codex':None}}
   c.sendall((json.dumps({'id':m['id'],'result':result})+'\\n').encode())
   if count==1: break
  f.close()
""", path]
        server.standardError = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        try server.run()
        defer {
            server.terminate()
            server.waitUntilExit()
            try? FileManager.default.removeItem(atPath: path)
        }
        var snapshots = 0, activeClients = 0
        let connection = DaemonConnection(socketPath: path, onClient: { if $0 != nil { activeClients += 1 } },
                                          onStatus: { _ in }, onEvent: { if case .snapshot = $0 { snapshots += 1 } })
        connection.start()
        connection.start() // idempotent: no second connection lifetime
        let deadline = Date().addingTimeInterval(6)
        while snapshots < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(snapshots >= 2)
        #expect(server.isRunning)
        connection.stop()
        let count = activeClients
        try await Task.sleep(for: .milliseconds(250))
        #expect(activeClients == count)
    }

    /// C4: a snapshot this app's `Decodable`s cannot parse at all (as opposed to one carrying an
    /// unknown enum raw value, which decodes tolerantly) is a daemon this app cannot fully speak
    /// to — the same `.helperMismatch` as an explicit protocol-version refusal, not a retryable
    /// `.helperUnreachable`.
    @Test func aSnapshotDecodingFailureIsAHelperMismatchNotAnUnreachableHelper() async throws {
        let path = "/tmp/at-\(UUID().uuidString.prefix(8)).sock"
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
import json,socket,sys
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]);s.listen()
c,_=s.accept()
with c:
 f=c.makefile('rb')
 for line in f:
  m=json.loads(line)
  # No protocolVersion: a shape this app's Decodable cannot parse at all.
  result={'connected':True,'sessions':[],'usage':{'claude':None,'codex':None}}
  c.sendall((json.dumps({'id':m['id'],'result':result})+'\\n').encode())
""", path]
        server.standardError = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        try server.run()
        defer {
            server.terminate()
            server.waitUntilExit()
            try? FileManager.default.removeItem(atPath: path)
        }
        let bound = TestDeadline.fromNow()
        while !FileManager.default.fileExists(atPath: path), Date() < bound { try await Task.sleep(for: .milliseconds(10)) }
        var states: [ItermConnection] = []
        let connection = DaemonConnection(socketPath: path, onClient: { _ in },
                                          onStatus: { if states.last != $0 { states.append($0) } }, onEvent: { _ in })
        connection.start()
        defer { connection.stop() }
        let deadline = TestDeadline.fromNow()
        while states.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        #expect(states.first == .helperMismatch, "a snapshot the app cannot decode must not be blamed on iTerm2 being unreachable, got \(states)")
    }

    @Test func refusedITerm2AuthenticationIsAWarningFromTheSnapshotAndFromTheEvent() async throws {
        let path = "/tmp/at-\(UUID().uuidString.prefix(8)).sock"
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
import json,socket,sys,time
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1]);s.listen()
c,_=s.accept()
with c:
 f=c.makefile('rb')
 for line in f:
  m=json.loads(line)
  result={'protocolVersion':1,'connected':False,'itermAuthError':'first refusal','sessions':[],'usage':{'claude':None,'codex':None}}
  c.sendall((json.dumps({'id':m['id'],'result':result})+'\\n').encode())
  time.sleep(0.2)
  c.sendall((json.dumps({'event':'iterm.disconnected','payload':{}})+'\\n').encode())
  c.sendall((json.dumps({'event':'iterm.auth_failed','payload':{'reason':'second refusal'}})+'\\n').encode())
  time.sleep(5)
""", path]
        server.standardError = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        try server.run()
        defer {
            server.terminate()
            server.waitUntilExit()
            try? FileManager.default.removeItem(atPath: path)
        }
        let bound = TestDeadline.fromNow()
        while !FileManager.default.fileExists(atPath: path), Date() < bound { try await Task.sleep(for: .milliseconds(10)) }
        var states: [ItermConnection] = []
        let connection = DaemonConnection(socketPath: path, onClient: { _ in },
                                          onStatus: { if states.last != $0 { states.append($0) } }, onEvent: { _ in })
        connection.start()
        defer { connection.stop() }
        let deadline = TestDeadline.fromNow()
        while states.count < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        #expect(states == [.refused("first refusal"), .itermReconnecting, .refused("second refusal")], "got \(states)")
        #expect(states.first?.banner?.tone == .warning)
    }

    /// The helper's request reaches the app in the bootstrap snapshot and, later, as an event; a
    /// second snapshot repeating the first request must not fetch a second single-use cookie.
    @Test func cookieRequestsFromTheSnapshotAndTheEventAreEachAnsweredOnce() async throws {
        let path = "/tmp/at-\(UUID().uuidString.prefix(8)).sock"
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-cookie-\(UUID().uuidString).log")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
import json,socket,sys
path,log=sys.argv[1:]
s=socket.socket(socket.AF_UNIX)
s.bind(path);s.listen()
c,_=s.accept()
snapshots=0
with c:
 f=c.makefile('rb')
 for line in f:
  m=json.loads(line)
  if m['method']=='workspace.snapshot':
   snapshots+=1
   result={'protocolVersion':1,'connected':False,'itermCookieRequest':7,'sessions':[],'usage':{'claude':None,'codex':None}}
   c.sendall((json.dumps({'id':m['id'],'result':result})+'\\n').encode())
  else:
   with open(log,'a') as out: out.write(json.dumps(m['params'],sort_keys=True)+'\\n')
   c.sendall((json.dumps({'id':m['id'],'result':{'accepted':True}})+'\\n').encode())
   if m['params']['requestId']==7:
    c.sendall((json.dumps({'event':'iterm.cookieRequested','payload':{'requestId':8}})+'\\n').encode())
""", path, log.path]
        server.standardError = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        try server.run()
        defer {
            server.terminate()
            server.waitUntilExit()
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(at: log)
        }
        let bound = TestDeadline.fromNow()
        while !FileManager.default.fileExists(atPath: path), Date() < bound { try await Task.sleep(for: .milliseconds(10)) }
        var asked = 0
        var client: DaemonClient?
        let connection = DaemonConnection(socketPath: path, onClient: { client = $0 }, onStatus: { _ in }, onEvent: { _ in },
                                          requestCookie: { asked += 1; return .granted(cookie: "c\(asked)", key: "k") })
        connection.start()
        defer { connection.stop() }
        func answers() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        let deadline = TestDeadline.fromNow()
        while answers().count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        // A later snapshot still showing request 7 is not answered again.
        _ = try await client?.snapshot()
        try await Task.sleep(for: .milliseconds(150))

        #expect(answers() == [#"{"cookie": "c1", "key": "k", "requestId": 7}"#, #"{"cookie": "c2", "key": "k", "requestId": 8}"#])
        #expect(asked == 2)
    }
}
