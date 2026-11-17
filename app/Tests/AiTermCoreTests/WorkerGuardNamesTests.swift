import Testing
@testable import AiTermCore

struct WorkerGuardNamesTests {
    private static func pushRule(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64) && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }

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

    @Test(arguments: rows) func aFullCommitIdIsFortyOrSixtyFourAsciiHexDigits(text: String) {
        #expect(WorkerGuard.isFullCommit(text) == Self.pushRule(text))
    }
}
