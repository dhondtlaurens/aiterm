import Testing
import AiTermCore

@Suite struct OptionalStringTests {
    @Test(arguments: [nil, ""] as [String?])
    func absentOrEmptyTextStaysAbsent(text: String?) {
        #expect(text.said == nil)
        #expect(text.nonEmpty == nil)
    }

    @Test(arguments: [" \t\r\n", "\u{00A0}\u{2028}\u{2029}"])
    func whitespaceIsAbsentOnlyWhenTrimmed(text: String) {
        #expect(Optional(text).said == nil)
        #expect(Optional(text).nonEmpty == text)
    }

    @Test func trimmingKeepsTheTextInsideItsEdges() {
        let text: String? = "\t\u{00A0}fix  it\nagain\r\n"
        #expect(text.said == "fix  it\nagain")
        #expect(text.nonEmpty == text)
    }
}
