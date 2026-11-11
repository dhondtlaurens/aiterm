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

    /// The push, the local merge and `record_review` accept and refuse exactly what they did before phase 2. A single
    /// rule for the three is the maintainer's to approve: it changes which inputs the merge and the review refuse.
    @Test(arguments: rows) func eachReaderKeepsItsRuleFromBeforePhaseTwo(text: String) {
        #expect(CommitId.isFull(text) == Self.pushRule(text), "push")
        #expect(CommitId.isMergeable(text) == Self.mergeRule(text), "local merge")
        #expect(CommitId.isAbbreviation(text) == Self.reviewRule(text), "record_review")
        #expect((CommitId(text) != nil) == Self.pushRule(text))
    }
}
