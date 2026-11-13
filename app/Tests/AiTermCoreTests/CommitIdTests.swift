import Testing
@testable import AiTermCore

struct CommitIdTests {
    // The three rules as they were on main before phase 2 (9a5d2fd7), kept here as the reference `CommitId` is held to.

    /// `Repository+Publish.swift`'s `isCommitId`: the push's refspec.
    private static func pushRule(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64) && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }

    /// `LocalMerge.mergeNow`'s guard.
    private static func mergeRule(_ text: String) -> Bool { text.count >= 40 && text.allSatisfy(\.isHexDigit) }

    /// `record_review`'s guard on the reviewed commit.
    private static func reviewRule(_ text: String) -> Bool { (4...64).contains(text.count) && text.allSatisfy(\.isHexDigit) }

    static let rows: [String] = {
        let fullwidth = "\u{FF10}\u{FF11}\u{FF21}\u{FF41}"
        return ["", "abc", "abcd", "ABCD", "HEAD", "main", "-abc", "a:b", "feat/pluto-231", "0123456789abcdef",
                String(repeating: "a", count: 39), String(repeating: "a", count: 40), String(repeating: "F", count: 40),
                String(repeating: "a", count: 41), String(repeating: "a", count: 63), String(repeating: "a", count: 64),
                String(repeating: "a", count: 65), String(repeating: "a", count: 70), String(repeating: "g", count: 40),
                String(repeating: fullwidth, count: 10), String(repeating: fullwidth, count: 1), String(repeating: fullwidth, count: 16),
                String(repeating: "a", count: 39) + "\u{FF11}", "\u{0660}\u{0661}\u{0662}\u{0663}", String(repeating: "\u{0661}", count: 40),
                String(repeating: "a", count: 39) + " ", "e\u{301}" + String(repeating: "a", count: 39)]
    }()

    /// The rows one rule for every reader moves (the maintainer's decision of 2026-11-12), with what each reader said
    /// before and says now: the local merge takes only a full object name, 40 or 64 ASCII hex digits, and
    /// `record_review` only ASCII hex digits. The push's rule does not move.
    static let changed: [String: (merge: (before: Bool, now: Bool)?, review: (before: Bool, now: Bool)?)] = {
        let fullwidth = "\u{FF10}\u{FF11}\u{FF21}\u{FF41}"
        return [
            String(repeating: "a", count: 41): ((true, false), nil),
            String(repeating: "a", count: 63): ((true, false), nil),
            String(repeating: "a", count: 65): ((true, false), nil),
            String(repeating: "a", count: 70): ((true, false), nil),
            String(repeating: fullwidth, count: 10): ((true, false), (true, false)),
            String(repeating: fullwidth, count: 16): ((true, false), (true, false)),
            String(repeating: "a", count: 39) + "\u{FF11}": ((true, false), (true, false)),
            String(repeating: fullwidth, count: 1): (nil, (true, false)),
        ]
    }()

    /// Every reader agrees with its rule from before phase 2, kept above as the reference, on every row but `changed`,
    /// where it says what the table says it says now, and the reference what it said before.
    @Test(arguments: rows) func eachReaderKeepsItsRuleFromBeforePhaseTwoButTheRowsOneRuleMoves(text: String) {
        #expect(CommitId.isFull(text) == Self.pushRule(text), "push")
        #expect((CommitId(text) != nil) == Self.pushRule(text))
        let moved = Self.changed[text]
        if let merge = moved?.merge {
            #expect(Self.mergeRule(text) == merge.before, "local merge, before")
            #expect(CommitId.isMergeable(text) == merge.now, "local merge, now")
        } else {
            #expect(CommitId.isMergeable(text) == Self.mergeRule(text), "local merge")
        }
        if let review = moved?.review {
            #expect(Self.reviewRule(text) == review.before, "record_review, before")
            #expect(CommitId.isAbbreviation(text) == review.now, "record_review, now")
        } else {
            #expect(CommitId.isAbbreviation(text) == Self.reviewRule(text), "record_review")
        }
    }

    /// Every row the table names is one of the rows tried.
    @Test func theRowsThatMoveAreAmongTheRows() {
        #expect(Set(Self.changed.keys).isSubset(of: Set(Self.rows)))
    }
}
