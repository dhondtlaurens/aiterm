import Foundation

public enum ADFText {
    public static func plain(_ adf: JSONValue?) -> String {
        guard let adf else { return "" }
        if let s = adf.stringValue { return s }
        guard let node = adf.objectValue else { return "" }
        return blocks(node).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Foundation's cast accepted the whole array or none of it. Keep that rule for malformed ADF.
    private static func children(of node: [String: JSONValue]) -> [[String: JSONValue]] {
        guard let values = node["content"]?.arrayValue else { return [] }
        let objects = values.compactMap(\.objectValue)
        return objects.count == values.count ? objects : []
    }

    private static func blocks(_ node: [String: JSONValue]) -> [String] {
        let children = children(of: node)
        switch node["type"]?.stringValue {
        case "doc": return children.flatMap(blocks)
        case "paragraph", "heading": return [inline(children)]
        case "codeBlock": return ["```\n" + inline(children) + "\n```"]
        case "bulletList": return [children.map { "- " + itemText($0) }.joined(separator: "\n")]
        case "orderedList": return [children.enumerated().map { "\($0.offset + 1). " + itemText($0.element) }.joined(separator: "\n")]
        case "rule": return ["---"]
        default: return children.flatMap(blocks)
        }
    }

    private static func itemText(_ item: [String: JSONValue]) -> String { blocks(item).joined(separator: " ") }

    private static func inline(_ nodes: [[String: JSONValue]]) -> String {
        nodes.map { n -> String in
            switch n["type"]?.stringValue {
            case "text": return n["text"]?.stringValue ?? ""
            case "hardBreak": return "\n"
            case "mention": return n["attrs"]?["text"]?.stringValue ?? ""
            case "inlineCard": return n["attrs"]?["url"]?.stringValue ?? ""
            default: return inline(children(of: n))
            }
        }.joined()
    }
}

extension ADFText {
    /// `text` as an Atlassian Document Format document: a paragraph for each run of lines, its line breaks kept.
    static func document(_ text: String) -> JSONValue {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return ["type": "doc", "version": 1, "content": .array(paragraphs.map { paragraph -> JSONValue in
            let lines = paragraph.components(separatedBy: "\n")
            let inline = lines.enumerated().flatMap { index, line -> [JSONValue] in
                (index > 0 ? [["type": "hardBreak"]] : []) + (line.isEmpty ? [] : [["type": "text", "text": .string(line)]])
            }
            return ["type": "paragraph", "content": .array(inline)]
        })]
    }
}
