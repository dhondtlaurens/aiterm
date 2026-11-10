import Testing
@testable import AiTermCore

struct CommitIdTests {
    /// One rule where three disagreed: a local merge took any 40 or more hex digits, Unicode's included, and a push
    /// 40 or 64 ASCII ones. A full id is 40 (SHA-1) or 64 (SHA-256) ASCII hex digits; a reviewed commit may be named
    /// by 4 to 64 of them.
    @Test func aFullIdIsFortyOrSixtyFourAsciiHexDigits() {
        #expect(CommitId(String(repeating: "a", count: 40))?.text == String(repeating: "a", count: 40))
        #expect(CommitId.isFull(String(repeating: "F", count: 64)))
        for text in [String(repeating: "a", count: 41), String(repeating: "a", count: 39), String(repeating: "g", count: 40),
                     String(repeating: "\u{FF11}", count: 40), "main", "-a", ""] {
            #expect(!CommitId.isFull(text), "\(text)")
        }
        #expect(CommitId.isAbbreviation("abcd") && CommitId.isAbbreviation(String(repeating: "0", count: 64)))
        #expect(!CommitId.isAbbreviation("abc") && !CommitId.isAbbreviation("HEAD") && !CommitId.isAbbreviation(String(repeating: "0", count: 65)))
    }
}
