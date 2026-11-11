import Testing
import Foundation
@testable import AiTermCore

@Suite struct ADFTextTests {
    @Test func testFlattensCommonNodes() throws {
        let adf: [String: Any] = ["type": "doc", "version": 1, "content": [
            ["type": "heading", "attrs": ["level": 2], "content": [["type": "text", "text": "Goal"]]],
            ["type": "paragraph", "content": [["type": "text", "text": "Drain "], ["type": "text", "text": "in-flight", "marks": [["type": "strong"]]], ["type": "text", "text": " tasks."]]],
            ["type": "bulletList", "content": [
                ["type": "listItem", "content": [["type": "paragraph", "content": [["type": "text", "text": "SIGTERM handler"]]]]],
                ["type": "listItem", "content": [["type": "paragraph", "content": [["type": "text", "text": "30s timeout"]]]]]]],
            ["type": "codeBlock", "attrs": ["language": "ts"], "content": [["type": "text", "text": "process.on('SIGTERM', drain)"]]],
        ]]
        #expect(ADFText.plain(try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: adf))) == "Goal\n\nDrain in-flight tasks.\n\n- SIGTERM handler\n- 30s timeout\n\n```\nprocess.on('SIGTERM', drain)\n```")
    }

    @Test func testNilAndStringPassThrough() {
        #expect(ADFText.plain(nil) == "")
        #expect(ADFText.plain("already plain") == "already plain")
    }
}

// The Foundation implementation before 3d, retained as the compatibility reference.
private enum FoundationADFText {
    public static func plain(_ adf: Any?) -> String {
        guard let adf else { return "" }
        if let s = adf as? String { return s }
        guard let node = adf as? [String: Any] else { return "" }
        return blocks(node).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func blocks(_ node: [String: Any]) -> [String] {
        let children = node["content"] as? [[String: Any]] ?? []
        switch node["type"] as? String {
        case "doc": return children.flatMap(blocks)
        case "paragraph", "heading": return [inline(children)]
        case "codeBlock": return ["```\n" + inline(children) + "\n```"]
        case "bulletList": return [children.map { "- " + itemText($0) }.joined(separator: "\n")]
        case "orderedList": return [children.enumerated().map { "\($0.offset + 1). " + itemText($0.element) }.joined(separator: "\n")]
        case "rule": return ["---"]
        default: return children.flatMap(blocks)
        }
    }

    private static func itemText(_ item: [String: Any]) -> String { blocks(item).joined(separator: " ") }

    private static func inline(_ nodes: [[String: Any]]) -> String {
        nodes.map { n -> String in
            switch n["type"] as? String {
            case "text": return n["text"] as? String ?? ""
            case "hardBreak": return "\n"
            case "mention": return (n["attrs"] as? [String: Any])?["text"] as? String ?? ""
            case "inlineCard": return (n["attrs"] as? [String: Any])?["url"] as? String ?? ""
            default: return inline(n["content"] as? [[String: Any]] ?? [])
            }
        }.joined()
    }
}

extension FoundationADFText {
    /// `text` as an Atlassian Document Format document: a paragraph for each run of lines, its line breaks kept.
    static func document(_ text: String) -> [String: Any] {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return ["type": "doc", "version": 1, "content": paragraphs.map { paragraph -> [String: Any] in
            let lines = paragraph.components(separatedBy: "\n")
            let inline = lines.enumerated().flatMap { index, line -> [[String: Any]] in
                (index > 0 ? [["type": "hardBreak"]] : []) + (line.isEmpty ? [] : [["type": "text", "text": line]])
            }
            return ["type": "paragraph", "content": inline]
        }]
    }
}

extension ADFTextTests {
    @Test func typedADFRenderingKeepsTheFoundationRuleByteForByte() throws {
        let text: JSONValue = ["type": "text", "text": " e\u{301} / \"quoted\"\n"]
        let paragraph: JSONValue = ["type": "paragraph", "content": .array([text, ["type": "hardBreak"],
            ["type": "mention", "attrs": ["text": "@Zoë"]], ["type": "inlineCard", "attrs": ["url": "https://x/y"]]])]
        let rows: [JSONValue] = [.null, true, 4, "  untouched\r\n", [], [:], text, paragraph,
            ["type": "doc", "content": .array([paragraph, ["type": "rule"], ["type": "codeBlock", "content": .array([text])]])],
            ["type": "doc", "content": .array([paragraph, 1])],
            ["type": "paragraph", "content": .array([text, .null])],
            ["type": "paragraph", "content": [["type": "unknown", "content": .array([text, false])]]],
            ["type": "doc", "content": ["not": "an array"]],
            ["type": "bulletList", "content": [["type": "listItem", "content": .array([paragraph,
                ["type": "orderedList", "content": [["type": "listItem", "content": .array([paragraph])]]]])]]],
            ["type": "table", "content": [["type": "tableRow", "content": [["type": "tableCell", "content": .array([paragraph])]]]]],
            ["type": "paragraph", "content": [["type": "date", "attrs": ["timestamp": "10"]], ["type": "status", "attrs": ["text": "done"]], ["type": "text", "text": false]]],
            ["type": "unknown", "content": .array([paragraph])]]
        for row in rows {
            let reference = FoundationADFText.plain(row.foundationValue)
            #expect(Data(ADFText.plain(row).utf8) == Data(reference.utf8), "\(row)")
        }
    }

    @Test func typedADFDocumentsKeepTheFoundationBodyAndText() throws {
        for text in ["", " \n\t", "one\ntwo", "one\r\ntwo\r\n\r\nthree", "\n\none\n\n\n\ntwo\n\n", "e\u{301} / \"quotes\" \\ 😊", "one\rtwo"] {
            let reference = FoundationADFText.document(text)
            let document = ADFText.document(text)
            let before = try JSONSerialization.data(withJSONObject: reference, options: [.sortedKeys])
            let after = try JSONSerialization.data(withJSONObject: document.foundationValue, options: [.sortedKeys])
            #expect(after == before)
            #expect(Data(ADFText.plain(document).utf8) == Data(FoundationADFText.plain(reference).utf8))
        }
    }
}
