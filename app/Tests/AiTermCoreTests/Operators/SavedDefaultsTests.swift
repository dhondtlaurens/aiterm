import Foundation
import Testing
@testable import AiTermCore

/// The two wrappers the Operator's records code their defaulted fields with: a missing or null field reads as its
/// default, a `Defaulted` one is always written, an `OmittedWhenDefault` one only once it differs.
@Suite struct SavedDefaultsTests {
    struct Record: Codable, Equatable {
        @Defaulted<SavedDefaults.None<String>> var always: [String] = []
        @OmittedWhenDefault<SavedDefaults.Zero> var count = 0
        @OmittedWhenDefault<SavedDefaults.Critique> var kind: ChallengeKind = .critique
    }

    private func saved(_ record: Record) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    @Test func aMissingOrNullFieldReadsAsItsDefault() throws {
        for json in [#"{}"#, #"{"always":null,"count":null,"kind":null}"#] {
            #expect(try JSONDecoder().decode(Record.self, from: Data(json.utf8)) == Record())
        }
        let set = try JSONDecoder().decode(Record.self, from: Data(#"{"always":["a"],"count":2,"kind":"veto"}"#.utf8))
        #expect(set.always == ["a"] && set.count == 2 && set.kind == .veto)
    }

    @Test func aDefaultedFieldIsAlwaysWrittenAndAnOmittedOneOnlyOnceItDiffers() throws {
        #expect(try saved(Record()) == #"{"always":[]}"#)
        var record = Record()
        record.count = 3
        record.kind = .veto
        #expect(try saved(record) == #"{"always":[],"count":3,"kind":"veto"}"#)
    }
}
