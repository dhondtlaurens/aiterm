import Foundation
import Testing
@testable import AiTermTestSupport
@testable import AiTermCore

/// The chat's saved lifecycle and the one rule that says when the chat is idle.
@Suite struct OperatorLifecycleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func everyCaseRoundTripsInTheKindValueShape() throws {
        let cases: [(OperatorSession.Lifecycle, JSONValue)] = [
            (.idle, ["kind": "idle"]),
            (.opening, ["kind": "opening"]),
            (.open(since: now, wake: nil), ["kind": "open", "value": ["since": "2027-01-15T08:00:00Z"]]),
            (.open(since: now, wake: .sent), ["kind": "open", "value": ["since": "2027-01-15T08:00:00Z", "wake": "sent"]]),
            (.open(since: now, wake: .maybeUnsent), ["kind": "open", "value": ["since": "2027-01-15T08:00:00Z", "wake": "maybeUnsent"]]),
            (.closing(then: .renew), ["kind": "closing", "value": "renew"]),
            (.closing(then: .retire), ["kind": "closing", "value": "retire"]),
            (.revoking(then: .renew), ["kind": "revoking", "value": "renew"]),
            (.revoking(then: .retire), ["kind": "revoking", "value": "retire"]),
        ]
        for (lifecycle, json) in cases {
            #expect(try JSONValue(encoding: lifecycle) == json, "\(lifecycle)")
            #expect(try json.decode(OperatorSession.Lifecycle.self) == lifecycle, "\(lifecycle)")
        }
    }

    /// A newer build's case, and a known kind whose value does not decode, are kept as they were and are inert.
    @Test func whatDoesNotDecodeIsUnknownAndKeepsItsBytes() throws {
        for raw: JSONValue in [["kind": "handing", "value": 3], ["kind": "closing", "value": "later"], ["kind": "open", "value": ["wake": "sent"]],
                               ["kind": "open", "value": ["since": "2027-01-15T08:00:00Z", "wake": "read"]]] {
            let decoded = try raw.decode(OperatorSession.Lifecycle.self)
            #expect(decoded == .unknown(raw))
            #expect(try JSONValue(encoding: decoded) == raw)
            #expect(decoded.isChanging && !decoded.isOpen && !decoded.isRetiring && decoded.wake == nil)
        }
    }

    @Test func thePredicatesNameOpenChangingAndRetiring() {
        let open = OperatorSession.Lifecycle.open(since: now, wake: .sent)
        #expect(open.isOpen && !open.isChanging && !open.isRetiring && open.wake == .sent)
        #expect(!OperatorSession.Lifecycle.idle.isOpen && !OperatorSession.Lifecycle.idle.isChanging)
        for changing: OperatorSession.Lifecycle in [.opening, .closing(then: .renew), .revoking(then: .renew)] {
            #expect(changing.isChanging && !changing.isRetiring && !changing.isOpen, "\(changing)")
        }
        for retiring: OperatorSession.Lifecycle in [.closing(then: .retire), .revoking(then: .retire)] {
            #expect(retiring.isChanging && retiring.isRetiring, "\(retiring)")
        }
    }

    /// A saved session without a lifecycle is from an earlier build: it does not load.
    @Test func aSessionSavedWithoutALifecycleDoesNotDecode() throws {
        var saved = try #require(try JSONValue(encoding: OperatorSession(createdAt: now)).objectValue)
        saved["lifecycle"] = nil
        #expect(throws: DecodingError.self) { try JSONValue.object(saved).decode(OperatorSession.self) }
    }

    @Test(arguments: [
        // tab state, stopped, tabs in the window, acts running, wake unread, idle
        (SessionState?.some(.done), false, 1, false, false, true),
        (.some(.idle), false, 1, false, false, true),
        (nil, false, 0, false, false, true),
        (nil, false, 1, false, false, true),
        (.some(.working), false, 1, false, false, false),
        (.some(.done), true, 1, false, false, false),
        (.some(.done), false, 2, false, false, false),
        (.some(.done), false, 1, true, false, false),
        (.some(.done), false, 1, false, true, false),
    ])
    func theChatIsIdleOnlyWhenNothingRunsWaitsOrSharesItsWindow(state: SessionState?, stopped: Bool, tabs: Int, acts: Bool, wake: Bool, idle: Bool) {
        let tab = state.map { state in
            var tab = SessionInfo.make("operator", window: "operator-window", state: state)
            if stopped { tab.stoppedOn = StoppedOn(error: "billing_error") }
            return tab
        }
        #expect(OperatorSession.chatIsIdle(tab: tab, tabsInWindow: tabs, actsRunning: acts, wakeUnread: wake) == idle)
    }
}
