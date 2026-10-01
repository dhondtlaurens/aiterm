import Testing
import Foundation
@testable import AiTermCore

@Suite struct ADFTextTests {
    @Test func testFlattensCommonNodes() {
        let adf: [String: Any] = ["type": "doc", "version": 1, "content": [
            ["type": "heading", "attrs": ["level": 2], "content": [["type": "text", "text": "Goal"]]],
            ["type": "paragraph", "content": [["type": "text", "text": "Drain "], ["type": "text", "text": "in-flight", "marks": [["type": "strong"]]], ["type": "text", "text": " tasks."]]],
            ["type": "bulletList", "content": [
                ["type": "listItem", "content": [["type": "paragraph", "content": [["type": "text", "text": "SIGTERM handler"]]]]],
                ["type": "listItem", "content": [["type": "paragraph", "content": [["type": "text", "text": "30s timeout"]]]]]]],
            ["type": "codeBlock", "attrs": ["language": "ts"], "content": [["type": "text", "text": "process.on('SIGTERM', drain)"]]],
        ]]
        #expect(ADFText.plain(adf) == "Goal\n\nDrain in-flight tasks.\n\n- SIGTERM handler\n- 30s timeout\n\n```\nprocess.on('SIGTERM', drain)\n```")
    }

    @Test func testNilAndStringPassThrough() {
        #expect(ADFText.plain(nil) == "")
        #expect(ADFText.plain("already plain") == "already plain")
    }
}
