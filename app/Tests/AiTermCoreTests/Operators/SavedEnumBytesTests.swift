import Foundation
import Testing
@testable import AiTermCore

/// The workspace encoder's exact bytes for every open saved enum case.
@Suite struct SavedEnumBytesTests {
    private func pin<Value: Codable & Equatable>(_ value: Value, _ expected: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let actual = String(decoding: try encoder.encode(value), as: UTF8.self)
        #expect(actual == expected, "Encoded \(value): \(actual.debugDescription)")
        #expect(try decoder.decode(Value.self, from: Data(expected.utf8)) == value)
    }

    @Test func sources() throws {
        try pin(SignalSource.jira(JiraConditions()), #"""
        {
          "kind" : "jira",
          "value" : {
            "inOpenSprints" : false,
            "labels" : [

            ],
            "projects" : [

            ],
            "statuses" : [

            ]
          }
        }
        """#)
        try pin(SignalSource.gitLab(RequestConditions(event: .reviewRequested)), #"""
        {
          "kind" : "gitLab",
          "value" : {
            "event" : "reviewRequested",
            "projects" : [

            ],
            "sentBackToMe" : true,
            "waitingOnMyReply" : true
          }
        }
        """#)
        try pin(SignalSource.gitLab(RequestConditions(event: .myRequest)), #"""
        {
          "kind" : "gitLab",
          "value" : {
            "event" : "myRequest",
            "projects" : [

            ],
            "sentBackToMe" : true,
            "waitingOnMyReply" : true
          }
        }
        """#)
        try pin(SignalSource.gitHub(RequestConditions(event: .reviewRequested)), #"""
        {
          "kind" : "gitHub",
          "value" : {
            "event" : "reviewRequested",
            "projects" : [

            ],
            "sentBackToMe" : true,
            "waitingOnMyReply" : true
          }
        }
        """#)
        try pin(SignalSource.gitHub(RequestConditions(event: .myRequest)), #"""
        {
          "kind" : "gitHub",
          "value" : {
            "event" : "myRequest",
            "projects" : [

            ],
            "sentBackToMe" : true,
            "waitingOnMyReply" : true
          }
        }
        """#)
        try pin(SignalSource.unknown(["kind": "future", "value": ["extra": 7]]), #"""
        {
          "kind" : "future",
          "value" : {
            "extra" : 7
          }
        }
        """#)
    }

    @Test func doneConditions() throws {
        try pin(DoneWhen.operatorJudges, #"""
        {
          "kind" : "operatorJudges"
        }
        """#)
        try pin(DoneWhen.hasReviewer, #"""
        {
          "kind" : "hasReviewer"
        }
        """#)
        try pin(DoneWhen.approved, #"""
        {
          "kind" : "approved"
        }
        """#)
        try pin(DoneWhen.threadsResolved, #"""
        {
          "kind" : "threadsResolved"
        }
        """#)
        try pin(DoneWhen.merged, #"""
        {
          "kind" : "merged"
        }
        """#)
        try pin(DoneWhen.myReviewPosted, #"""
        {
          "kind" : "myReviewPosted"
        }
        """#)
        try pin(DoneWhen.mergedOrClosed, #"""
        {
          "kind" : "mergedOrClosed"
        }
        """#)
        try pin(DoneWhen.ticketStatus("Done"), #"""
        {
          "kind" : "ticketStatus",
          "value" : "Done"
        }
        """#)
        try pin(DoneWhen.unknown(["kind": "future", "value": ["extra": 7]]), #"""
        {
          "kind" : "future",
          "value" : {
            "extra" : 7
          }
        }
        """#)
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
        try pin(TaskPhase.watching(.ticketStatus("Done")), #"""
        {
          "kind" : "watching",
          "value" : {
            "kind" : "ticketStatus",
            "value" : "Done"
          }
        }
        """#)
        try pin(TaskPhase.unknown(["kind": "future", "value": ["extra": 7]]), #"""
        {
          "kind" : "future",
          "value" : {
            "extra" : 7
          }
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
        try pin(ItemRef.unknown(["kind": "future", "value": ["extra": 7]]), #"""
        {
          "kind" : "future",
          "value" : {
            "extra" : 7
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
        try pin(JournalText.unknown(["kind": "future", "value": ["extra": 7]]), #"""
        {
          "kind" : "future",
          "value" : {
            "extra" : 7
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
        try pin(OperatorSession.Lifecycle.unknown(["kind": "future", "value": ["extra": 7]]), #"""
        {
          "kind" : "future",
          "value" : {
            "extra" : 7
          }
        }
        """#)
    }

    @Test func finishChoices() throws {
        try pin(SignalFinish.Then.keep, #""keep""#)
        try pin(SignalFinish.Then.archive, #""archive""#)
        try pin(SignalFinish.Then.remove, #""remove""#)
        try pin(SignalFinish.Then.unknown("future"), #""future""#)
    }

    @Test func requestEvents() throws {
        try pin(RequestConditions.Event.reviewRequested, #""reviewRequested""#)
        try pin(RequestConditions.Event.myRequest, #""myRequest""#)
        try pin(RequestConditions.Event.unknown("future"), #""future""#)
    }

    @Test func seenDispositions() throws {
        try pin(SignalSeen.Disposition.started, #""started""#)
        try pin(SignalSeen.Disposition.skipped, #""skipped""#)
        try pin(SignalSeen.Disposition.unknown("future"), #""future""#)
    }

    @Test func agentDecisions() throws {
        try pin(AgentChoiceRecord.Decided.oracleAgreed, #""oracleAgreed""#)
        try pin(AgentChoiceRecord.Decided.oracleOff, #""oracleOff""#)
        try pin(AgentChoiceRecord.Decided.oracleUnavailable, #""oracleUnavailable""#)
        try pin(AgentChoiceRecord.Decided.disagreed, #""disagreed""#)
        try pin(AgentChoiceRecord.Decided.operatorAlone, #""operatorAlone""#)
        try pin(AgentChoiceRecord.Decided.unknown("future"), #""future""#)
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
        try missing(SignalSource.self, kinds: ["jira", "gitLab", "gitHub"], name: "SignalSource")
        try missing(DoneWhen.self, kinds: ["ticketStatus"], name: "DoneWhen")
        try missing(TaskPhase.self, kinds: ["watching"], name: "TaskPhase")
        try missing(ItemRef.self, kinds: ["ticket", "mergeRequest"], name: "ItemRef")
        try missing(JournalText.self, kinds: ["ours", "quoted"], name: "JournalText")
    }

    @Test func lifecycleMissingOrInvalidValuesStayUnknown() throws {
        for kind in ["open", "closing", "revoking"] {
            for raw: JSONValue in [["kind": .string(kind)], ["kind": .string(kind), "value": 7]] {
                let decoded = try raw.decode(OperatorSession.Lifecycle.self)
                #expect(decoded == .unknown(raw))
                #expect(try JSONValue(encoding: decoded) == raw)
            }
        }
    }
}
