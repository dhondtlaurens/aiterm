import Foundation
import Testing
@testable import AiTermCore

/// The workspace encoder's exact bytes for every saved enum case.
@Suite struct SavedEnumBytesTests {
    private func pin<Value: Codable & Equatable>(_ value: Value, _ expected: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let actual = String(decoding: try encoder.encode(value), as: UTF8.self)
        #expect(actual == expected, "Encoded \(value): \(actual.debugDescription)")
        #expect(try decoder.decode(Value.self, from: Data(expected.utf8)) == value)
    }

    @Test func triggerSources() throws {
        try pin(SignalTrigger.Source.jira, #""jira""#)
        try pin(SignalTrigger.Source.gitLab, #""gitLab""#)
        try pin(SignalTrigger.Source.gitHub, #""gitHub""#)
    }

    @Test func phases() throws {
        try pin(TaskPhase.launching, #"""
        {
          "kind" : "launching"
        }
        """#)
        try pin(TaskPhase.choosing, #"""
        {
          "kind" : "choosing"
        }
        """#)
        try pin(TaskPhase.working, #"""
        {
          "kind" : "working"
        }
        """#)
        try pin(TaskPhase.blocked, #"""
        {
          "kind" : "blocked"
        }
        """#)
        try pin(TaskPhase.done, #"""
        {
          "kind" : "done"
        }
        """#)
        try pin(TaskPhase.archived, #"""
        {
          "kind" : "archived"
        }
        """#)
        try pin(TaskPhase.watching, #"""
        {
          "kind" : "watching"
        }
        """#)
    }

    @Test func items() throws {
        try pin(ItemRef.ticket(SignalTicketRef(site: "jira.example", key: "DEMO-1")), #"""
        {
          "kind" : "ticket",
          "value" : {
            "key" : "DEMO-1",
            "site" : "jira.example"
          }
        }
        """#)
        try pin(ItemRef.mergeRequest(SignalRequestRef(remote: "host.example/repo", number: 7)), #"""
        {
          "kind" : "mergeRequest",
          "value" : {
            "number" : 7,
            "remote" : "host.example\/repo"
          }
        }
        """#)
    }

    @Test func journalText() throws {
        try pin(JournalText.ours("Note"), #"""
        {
          "kind" : "ours",
          "value" : "Note"
        }
        """#)
        try pin(JournalText.quoted(SignalQuote(source: "Worker", text: "Reply")), #"""
        {
          "kind" : "quoted",
          "value" : {
            "source" : "Worker",
            "text" : "Reply"
          }
        }
        """#)
    }

    @Test func lifecycle() throws {
        try pin(OperatorSession.Lifecycle.idle, #"""
        {
          "kind" : "idle"
        }
        """#)
        try pin(OperatorSession.Lifecycle.opening, #"""
        {
          "kind" : "opening"
        }
        """#)
        try pin(OperatorSession.Lifecycle.open(since: Date(timeIntervalSince1970: 1_800_000_000), wake: nil), #"""
        {
          "kind" : "open",
          "value" : {
            "since" : "2027-01-15T08:00:00Z"
          }
        }
        """#)
        try pin(OperatorSession.Lifecycle.open(since: Date(timeIntervalSince1970: 1_800_000_000), wake: .sent), #"""
        {
          "kind" : "open",
          "value" : {
            "since" : "2027-01-15T08:00:00Z",
            "wake" : "sent"
          }
        }
        """#)
        try pin(OperatorSession.Lifecycle.open(since: Date(timeIntervalSince1970: 1_800_000_000), wake: .maybeUnsent), #"""
        {
          "kind" : "open",
          "value" : {
            "since" : "2027-01-15T08:00:00Z",
            "wake" : "maybeUnsent"
          }
        }
        """#)
        try pin(OperatorSession.Lifecycle.closing(then: .renew), #"""
        {
          "kind" : "closing",
          "value" : "renew"
        }
        """#)
        try pin(OperatorSession.Lifecycle.closing(then: .retire), #"""
        {
          "kind" : "closing",
          "value" : "retire"
        }
        """#)
        try pin(OperatorSession.Lifecycle.revoking(then: .renew), #"""
        {
          "kind" : "revoking",
          "value" : "renew"
        }
        """#)
        try pin(OperatorSession.Lifecycle.revoking(then: .retire), #"""
        {
          "kind" : "revoking",
          "value" : "retire"
        }
        """#)
    }

    @Test func finishChoices() throws {
        try pin(SignalFinish.Then.keep, #""keep""#)
        try pin(SignalFinish.Then.archive, #""archive""#)
        try pin(SignalFinish.Then.remove, #""remove""#)
    }

    @Test func seenDispositions() throws {
        try pin(SignalSeen.Disposition.started, #""started""#)
        try pin(SignalSeen.Disposition.skipped, #""skipped""#)
    }

    @Test func agentDecisions() throws {
        try pin(AgentChoiceRecord.Decided.oracleAgreed, #""oracleAgreed""#)
        try pin(AgentChoiceRecord.Decided.oracleOff, #""oracleOff""#)
        try pin(AgentChoiceRecord.Decided.oracleUnavailable, #""oracleUnavailable""#)
        try pin(AgentChoiceRecord.Decided.disagreed, #""disagreed""#)
        try pin(AgentChoiceRecord.Decided.operatorAlone, #""operatorAlone""#)
    }

    private func missing<Value: Decodable>(_ type: Value.Type, kinds: [String], name: String) throws {
        for kind in kinds {
            do {
                _ = try JSONDecoder().decode(type, from: Data("{\"kind\":\"\(kind)\"}".utf8))
                Issue.record("Expected missing value for \(name).\(kind)")
            } catch DecodingError.dataCorrupted(let context) {
                #expect(context.debugDescription == "Missing \(name) value")
            }
        }
    }

    @Test func missingKnownValuesThrow() throws {
        try missing(ItemRef.self, kinds: ["ticket", "mergeRequest"], name: "ItemRef")
        try missing(JournalText.self, kinds: ["ours", "quoted"], name: "JournalText")
    }

    @Test func lifecycleMissingOrInvalidValuesThrow() {
        for kind in ["open", "closing", "revoking"] {
            for raw: JSONValue in [["kind": .string(kind)], ["kind": .string(kind), "value": 7]] {
                #expect(throws: DecodingError.self) { try raw.decode(OperatorSession.Lifecycle.self) }
            }
        }
    }

    @Test func unknownKindsThrow() {
        let raw: JSONValue = ["kind": "future", "value": ["extra": 7]]
        #expect(throws: DecodingError.self) { try raw.decode(TaskPhase.self) }
        #expect(throws: DecodingError.self) { try raw.decode(ItemRef.self) }
        #expect(throws: DecodingError.self) { try raw.decode(JournalText.self) }
        #expect(throws: DecodingError.self) { try raw.decode(OperatorSession.Lifecycle.self) }
    }

    @Test func unknownStringsThrow() {
        let raw: JSONValue = "future"
        #expect(throws: DecodingError.self) { try raw.decode(SignalTrigger.Source.self) }
        #expect(throws: DecodingError.self) { try raw.decode(SignalFinish.Then.self) }
        #expect(throws: DecodingError.self) { try raw.decode(SignalSeen.Disposition.self) }
        #expect(throws: DecodingError.self) { try raw.decode(AgentChoiceRecord.Decided.self) }
        #expect(throws: DecodingError.self) { try raw.decode(Signal.Kind.self) }
    }
}
