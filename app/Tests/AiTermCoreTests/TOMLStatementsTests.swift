import Testing
@testable import AiTermCore

@Suite struct TOMLStatementsTests {
    let text = """
        # top comment
        model = "gpt-5.6"

        [ui]
        yolo = false # trailing

        [ui.status_line]
        type = "command"
        command = '~/bin/line.sh'
        padding = 2
        note = \"\"\"
        [not.a.table]
        \"\"\"
        """

    @Test func tablesSplitAtHeadersOnly() {
        let tables = TOMLStatements.tables(text)
        #expect(tables.map(\.path) == [[], ["ui"], ["ui", "status_line"]])
        #expect(tables.map(\.text).joined() == text)
    }

    @Test func keyIsTheAssignedNameEvenForNonStringValues() {
        let keys = TOMLStatements.tables(text)[2].statements.compactMap(\.keyPath)
        #expect(keys == [["type"], ["command"], ["padding"], ["note"]])
    }
}

/// The parser's edge cases, directly: each is a way a real config can be written that a line
/// scanner would split, or read, wrongly.
@Suite struct TOMLStatementsEdgeCaseTests {
    @Test func aHeaderMayCarryATrailingComment() {
        let tables = TOMLStatements.tables("[profiles.fast] # quick\nmodel = \"m\"\n")
        #expect(tables.map(\.path) == [[], ["profiles", "fast"]])
        #expect(tables[1].statements.map(\.text) == ["[profiles.fast] # quick\n", "model = \"m\"\n"])
        #expect(tables[1].statements.compactMap(\.keyPath) == [["model"]])
    }

    @Test func arrayHeadersAndQuotedOrSpacedHeaderKeys() {
        let text = "[[hooks.Stop]]\n[ ui . \"status.line\" ]\n['a b'.c]\n"
        let tables = TOMLStatements.tables(text).dropFirst()
        #expect(tables.map(\.path) == [["hooks", "Stop"], ["ui", "status.line"], ["a b", "c"]])
        #expect(tables.map(\.array) == [true, false, false])
    }

    @Test func aMultiLineArrayWithCommentsHoldingBracketsAndQuotesIsOneStatement() {
        let text = "list = [\n  \"a\", # not ] the end\n  'b', # nor \" this\n]\n[next]\n"
        #expect(TOMLStatements.statements(text).first?.text == "list = [\n  \"a\", # not ] the end\n  'b', # nor \" this\n]\n")
        #expect(TOMLStatements.tables(text).map(\.path) == [[], ["next"]])
    }

    /// TOML 1.1 lets an inline table span lines; a newline inside it does not end the statement.
    @Test func anInlineTableSpanningLinesIsOneStatement() {
        let text = "status_line = {\n  type = \"command\",\n  command = \"x\",\n}\nafter = 1\n"
        #expect(TOMLStatements.statements(text).compactMap(\.keyPath) == [["status_line"], ["after"]])
    }

    @Test func aMultiLineLiteralStringMayHoldQuotesOfItsOwn() {
        let text = "note = '''it's ''quoted'' '''\n[t]\n"
        #expect(TOMLStatements.statements(text).map(\.text) == ["note = '''it's ''quoted'' '''\n", "[t]\n"])
        #expect(TOMLStatements.tables(text).map(\.path) == [[], ["t"]])
    }

    @Test func keyPathSplitsDottedKeysAndReadsQuotedParts() {
        func path(_ code: String) -> [String]? { TOMLStatements.statements(code).first?.keyPath }
        #expect(path("ui . status_line.type = 1") == ["ui", "status_line", "type"])
        #expect(path("\"ui\".'status_line' = {}") == ["ui", "status_line"])
        #expect(path("\"a=b\" = 1") == ["a=b"])
        #expect(path("\"a.b\" = 1") == ["a.b"])
        #expect(path("[header]") == nil)
        #expect(path("# comment") == nil)
    }
}
