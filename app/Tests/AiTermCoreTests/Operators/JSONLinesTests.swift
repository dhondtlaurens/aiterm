import Foundation
import Testing
@testable import AiTermTestSupport
@testable import AiTermCore

@Suite(.blocking) struct JSONLinesTests {
    @Test func missingFileIsEmpty() throws {
        let file = try ScratchFolder.make("json-lines-").appendingPathComponent("missing.jsonl")
        #expect(try JSONLines.read(String.self, from: file).isEmpty)
    }

    @Test func incompleteLastLineIsIgnored() throws {
        let file = try ScratchFolder.make("json-lines-").appendingPathComponent("records.jsonl")
        try Data("\"first\"\n\"unfinished".utf8).write(to: file)
        #expect(try JSONLines.read(String.self, from: file) == ["first"])
    }

    @Test func corruptCompleteLineThrows() throws {
        let file = try ScratchFolder.make("json-lines-").appendingPathComponent("records.jsonl")
        try Data("\"first\"\n{broken}\n\"last\"\n".utf8).write(to: file)
        #expect(throws: DecodingError.self) { try JSONLines.read(String.self, from: file) }
        // Appending does not erase or skip corrupt history.
        try JSONLines.append("next", to: file)
        #expect(throws: DecodingError.self) { try JSONLines.read(String.self, from: file) }
    }

    @Test(arguments: [0, 20, 9_000])
    func appendRepairsAnIncompleteTail(length: Int) throws {
        let file = try ScratchFolder.make("json-lines-").appendingPathComponent("records.jsonl")
        try JSONLines.append("first", to: file)
        let complete = try Data(contentsOf: file)
        var torn = complete; torn.append(Data(String(repeating: "x", count: length).utf8))
        try torn.write(to: file)
        try JSONLines.append("second", to: file)
        #expect(try JSONLines.read(String.self, from: file) == ["first", "second"])
        #expect(try Data(contentsOf: file).starts(with: complete))
    }

    @Test(arguments: ["", "{incomplete"])
    func appendRepairsAFileWithoutAnyCompleteRecord(tail: String) throws {
        let file = try ScratchFolder.make("json-lines-").appendingPathComponent("records.jsonl")
        try Data(tail.utf8).write(to: file)
        try JSONLines.append("first", to: file)
        #expect(try JSONLines.read(String.self, from: file) == ["first"])
    }

    @Test func datesUseISO8601AndEachAppendEndsWithANewline() throws {
        let file = try ScratchFolder.make("json-lines-").appendingPathComponent("records.jsonl")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try JSONLines.append(at, to: file)
        #expect(try Data(contentsOf: file) == Data("\"2027-01-15T08:00:00Z\"\n".utf8))
        #expect(try JSONLines.read(Date.self, from: file) == [at])
    }
}
