import Foundation
import Testing
@testable import AiTermCore

@Suite struct DaemonTypesTests {
    @Test func sessionReasoningDecodesWhenPresentAndDefaultsToNilWhenAbsent() throws {
        let withReasoning = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"pi","model":"openai/model-x","reasoning":"high","state":"working","title":"PI","cwd":"/repo"}"#
        let pi = try JSONDecoder().decode(SessionInfo.self, from: Data(withReasoning.utf8))
        #expect(pi.agent == .pi)
        #expect(pi.reasoning == "high")

        let legacy = #"{"sessionId":"s2","windowId":"w1","tabIndex":1,"taskId":null,"projectId":null,"agent":"codex","model":"gpt-5.6","state":"idle","title":"Codex","cwd":"/repo"}"#
        let codex = try JSONDecoder().decode(SessionInfo.self, from: Data(legacy.utf8))
        #expect(codex.reasoning == nil)
    }

    /// A session carries what its conversation has spent; an older daemon, or a tab whose agent has
    /// not replied yet, sends none, and the cached share may be unknown.
    @Test func sessionTokensDecodeWhenPresentAndDefaultToNilWhenAbsent() throws {
        let counted = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"claude","model":null,"state":"working","title":"","cwd":"/repo","tokens":{"input":936018,"cached":935988,"output":5625}}"#
        #expect(try JSONDecoder().decode(SessionInfo.self, from: Data(counted.utf8)).tokens
                == TokenTally(input: 936_018, cached: 935_988, output: 5_625))
        let unknownShare = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"grok","model":null,"state":"working","title":"","cwd":"/repo","tokens":{"input":12,"cached":null,"output":3}}"#
        #expect(try JSONDecoder().decode(SessionInfo.self, from: Data(unknownShare.utf8)).tokens?.cached == nil)
        let none = #"{"sessionId":"s2","windowId":"w1","tabIndex":1,"taskId":null,"projectId":null,"agent":"shell","model":null,"state":"idle","title":"","cwd":"/repo"}"#
        #expect(try JSONDecoder().decode(SessionInfo.self, from: Data(none.utf8)).tokens == nil)
    }

    /// C4: a daemon built from a different worktree can send a `SessionAgent`/`SessionState` raw
    /// value this app has never heard of. Decoding it to `.shell`/`.idle` keeps that one session
    /// from failing the whole snapshot, instead of a `.helperUnreachable` reconnect loop.
    @Test func unknownAgentAndStateDecodeToTheirDefaultsInsteadOfFailing() throws {
        let json = #"{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"gremlin","model":null,"state":"pondering","title":"","cwd":"/repo"}"#
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
        #expect(info.agent == .shell)
        #expect(info.state == .idle)
    }

    @Test func aSnapshotCarryingAnUnknownAgentOrStateStillDecodesAsAWhole() throws {
        let json = #"{"protocolVersion":1,"connected":true,"sessions":[{"sessionId":"s1","windowId":"w1","tabIndex":0,"taskId":null,"projectId":null,"agent":"gremlin","model":null,"state":"pondering","title":"","cwd":"/repo"}],"usage":{"claude":null,"codex":null}}"#
        let snapshot = try JSONDecoder().decode(DaemonSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.sessions.first?.agent == .shell)
        #expect(snapshot.sessions.first?.state == .idle)
    }

    static let refused = "execution error: Not authorized to send Apple events to iTerm2. (-1743)"

    @Test func snapshotCarriesTheAuthErrorAndOlderDaemonsDecodeWithout() throws {
        let refused = #"{"protocolVersion":1,"connected":false,"itermAuthError":"execution error: Not authorized to send Apple events to iTerm2. (-1743)","sessions":[],"usage":{"claude":null,"codex":null}}"#
        #expect(try JSONDecoder().decode(DaemonSnapshot.self, from: Data(refused.utf8)).itermAuthError == Self.refused)
        let older = #"{"protocolVersion":1,"connected":false,"sessions":[],"usage":{"claude":null,"codex":null}}"#
        #expect(try JSONDecoder().decode(DaemonSnapshot.self, from: Data(older.utf8)).itermAuthError == nil)
    }

    @Test func cookieRequestsDecodeFromTheSnapshotAndTheEvent() throws {
        let asking = #"{"protocolVersion":1,"connected":false,"itermCookieRequest":3,"sessions":[],"usage":{"claude":null,"codex":null}}"#
        #expect(try JSONDecoder().decode(DaemonSnapshot.self, from: Data(asking.utf8)).itermCookieRequest == 3)
        let older = #"{"protocolVersion":1,"connected":false,"sessions":[],"usage":{"claude":null,"codex":null}}"#
        #expect(try JSONDecoder().decode(DaemonSnapshot.self, from: Data(older.utf8)).itermCookieRequest == nil)
        let line = Data(#"{"event":"iterm.cookieRequested","payload":{"requestId":4}}"#.utf8)
        #expect(try DaemonClient.decodeEvent("iterm.cookieRequested", from: line) == .itermCookieRequested(4))
    }

    @Test func eachCookieAnswerEncodesOnlyItsOwnFields() throws {
        func json(_ answer: ItermCookieAnswer) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return String(decoding: try encoder.encode(DaemonClient.CookieParams(requestId: 1, answer: answer)), as: UTF8.self)
        }
        #expect(try json(.granted(cookie: "c", key: "k")) == #"{"cookie":"c","key":"k","requestId":1}"#)
        #expect(try json(.notRunning) == #"{"notRunning":true,"requestId":1}"#)
        #expect(try json(.refused("no")) == #"{"error":"no","requestId":1}"#)
    }

    @Test func authFailedEventDecodesItsReason() throws {
        let line = Data(#"{"event":"iterm.auth_failed","payload":{"reason":"execution error: Not authorized to send Apple events to iTerm2. (-1743)"}}"#.utf8)
        #expect(try DaemonClient.decodeEvent("iterm.auth_failed", from: line) == .itermAuthFailed(Self.refused))
    }

    @Test func bannerWarnsWhileITerm2RefusesAndOtherwiseOnlyWaits() {
        let refusing = DaemonSnapshot(protocolVersion: 1, connected: false, sessions: [], usage: .empty, itermAuthError: Self.refused)
        #expect(ItermConnection.forSnapshot(refusing) == .refused(Self.refused))
        let banner = ItermConnection.forSnapshot(refusing).banner
        #expect(banner?.tone == .warning)
        #expect(banner?.text.contains(Self.refused) == true)
        #expect(banner?.text.contains("Automation") == true)

        #expect(ItermConnection.forSnapshot(DaemonSnapshot(protocolVersion: 1, connected: false, sessions: [], usage: .empty)).banner
                == .info("Waiting for iTerm2…"))
        #expect(ItermConnection.forSnapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)).banner == nil)
    }

    @Test func connectedSnapshotCarriesTheITerm2VersionAndOlderDaemonsDecodeWithout() throws {
        let current = #"{"protocolVersion":1,"connected":true,"itermVersion":"3.7.2","itermAuthError":null,"sessions":[],"usage":{"claude":null,"codex":null}}"#
        let snapshot = try JSONDecoder().decode(DaemonSnapshot.self, from: Data(current.utf8))
        #expect(ItermConnection.forSnapshot(snapshot) == .connected(version: "3.7.2"))
        let older = #"{"protocolVersion":1,"connected":true,"sessions":[],"usage":{"claude":null,"codex":null}}"#
        #expect(ItermConnection.forSnapshot(try JSONDecoder().decode(DaemonSnapshot.self, from: Data(older.utf8)))
                == .connected(version: nil))
    }

    /// Every state but a live connection keeps the sidebar's line, and it opens with the iTerm2
    /// card's status for that state; only the refusal is amber.
    @Test func everyStateButConnectedKeepsItsBanner() {
        #expect(ItermConnection.starting.banner == .info("Starting AiTerm’s helper…"))
        #expect(ItermConnection.itermReconnecting.banner == .info("Reconnecting to iTerm2…"))
        #expect(ItermConnection.helperUnreachable.banner == .info("Reconnecting to AiTerm’s helper…"))
        #expect(ItermConnection.helperMismatch.banner
                == .info("AiTerm’s helper is from another version. Quit and reopen AiTerm.app."))
        #expect(ItermConnection.helperFailing("exit 1").banner?.text
                == "AiTerm’s helper keeps stopping: exit 1. Read why in \(ItermConnection.logPath).")
        #expect(ItermConnection.connected(version: "3.7.2").banner == nil)
        let states: [ItermConnection] = [.starting, .helperMissing, .pythonMissing, .helperFailing("exit 1"), .helperMismatch,
                                         .helperUnreachable, .waitingForIterm, .itermReconnecting, .refused("-1743")]
        for state in states {
            #expect(state.banner?.text.hasPrefix(state.status) == true, "\(state)")
            #expect(state.banner?.tone == (state == .refused("-1743") ? .warning : .info), "\(state)")
        }
    }

    /// A helper's message is written for the protocol or by Python — "no such window or
    /// session: w3", an exception's text — and is logged, never shown. What the person reads is
    /// said by the code, in a sentence of its own, whatever the message was; a code only a newer
    /// helper knows still reads as one.
    @Test func whatThePersonReadsIsSaidByTheCodeNotTheHelpersMessage() {
        let message = "Traceback: KeyError('w3') in rpc_params"
        let codes: [DaemonError.Code] = DaemonError.Code.daemonCodes
            + [.incompatible, .timeout, .disconnected, .connectionUsed, .socket, .connect, .write, "a_newer_helpers_code"]
        for code in codes {
            let error = DaemonError(code: code, message: message)
            #expect(!error.localizedDescription.contains("KeyError"), "\(code)")
            #expect(error.localizedDescription.hasSuffix("."), "\(code) reads as a sentence")
            #expect(error.description == message, "the message stays what the log and a developer read")
        }
        func said(_ code: DaemonError.Code) -> String { DaemonError(code: code, message: message).localizedDescription }
        #expect(said(.itermUnavailable) == "iTerm2 isn’t connected.")
        #expect(said(.notFound) == "The iTerm2 window or tab is already gone.")
        #expect(said(.timeout) == "AiTerm’s helper didn’t answer in time; it may still finish.")
        #expect(said(.disconnected) == "AiTerm’s helper isn’t connected.")
        #expect(said(.unknownMethod) == "AiTerm’s helper is from another version.")
        #expect(said(.internal) == "AiTerm’s helper ran into a problem.")
    }
}
