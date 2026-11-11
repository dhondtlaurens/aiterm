import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct TaskPublicationTests {
    @Test func everyStepRoundTripsOnATask() throws {
        var world = OperatedWorld()
        let task = world.addTask("PLUTO-231", run: world.addRun(), state: .accepted, end: .merge, acceptedSHA: "4f2a91c")
        world.state.updateOperated(task) {
            $0.publication = TaskPublication(pushedSHA: "4f2a91c", mergeRequestURL: "https://github.com/octocat/hello/pull/88",
                                             mergeRequestNumber: 88, targetBranch: "main",
                                             waitingSince: Date(timeIntervalSince1970: 1_800_000_000),
                                             readySince: Date(timeIntervalSince1970: 1_800_000_030), merged: true,
                                             mergedSHA: "5eed5eed", mergedHead: "4f2a91c", problem: nil)
        }
        let item = try #require(world.state.tasks.first)
        let back = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(item))
        #expect(back == item)
        #expect(back.operated?.end == .merge)
        #expect(back.operated?.publication?.mergeRequestNumber == 88)
    }

    /// A publication's problem keeps its kind beside it, the one key plan 2026-11-10 adds to the saved format: written with
    /// the kind its writer knows, read back as saved, and gone with the problem.
    @Test func aProblemSavesItsKindBesideIt() throws {
        var publication = TaskPublication()
        publication.setProblem(TaskEndChange.mergeWaitsForFinish, kind: .hold)
        let saved = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(publication))
        #expect(saved["problemKind"] == "hold")
        #expect(saved["problem"]?.stringValue == TaskEndChange.mergeWaitsForFinish)
        let back = try JSONDecoder().decode(TaskPublication.self, from: JSONEncoder().encode(publication))
        #expect(back == publication && back.problemOutcome == .hold && back.holdsForOperator)
        publication.problem = nil
        let cleared = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(publication))
        #expect(cleared["problemKind"] == nil && cleared["problem"] == nil)
        #expect(publication.problemOutcome == nil)
    }

    /// What is read is the saved kind, not the wording: a writer that knows a problem holds for the Operator makes it one,
    /// whatever it says, and the card and the requests read it so (`OperatedTask.publicationFailure`).
    @Test func theSavedKindIsWhatIsRead() {
        var publication = TaskPublication()
        publication.setProblem("The pipeline failed.", kind: .hold)
        #expect(publication.holdsForOperator)
        var operated = OperatedTask.make(run: UUID(), key: "T-1", state: .accepted)
        operated.publication = publication
        #expect(operated.publicationFailure == nil)
        operated.publication?.setProblem("The pipeline failed.", kind: .failure)
        #expect(operated.publicationFailure == "The pipeline failed.")
    }

    /// A save from before the kind was kept, its problem alone, is read by the problem's wording, as every build read it
    /// before: AiTerm's holds for the Operator (and the Oracle's refusal a merge watch saved in its own words), a refusal
    /// nothing gets past, and the rest a failure. Saved again unchanged, it keeps its bytes: no kind is written for it.
    @Test(arguments: [
        (TaskEndChange.mergeWaitsForFinish, TaskPublication.ProblemKind.hold), (PublicationGuard.oracleYesNeeded, .hold),
        (PublicationGuard.oracleRefusalOpening + "T-1" + PublicationGuard.oracleRefusalClosing, .hold),
        (PublicationGuard.mergeSliceOff, .permanent), ("The pipeline failed.", .failure),
    ]) func aSaveWithoutTheKindIsReadByItsWording(problem: String, kind: TaskPublication.ProblemKind) throws {
        guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(TaskPublication(problem: problem)))
        else { Issue.record("a publication saves as an object"); return }
        fields["problemKind"] = nil
        let legacy = try JSONEncoder().encode(JSONValue.object(fields))
        let read = try JSONDecoder().decode(TaskPublication.self, from: legacy)
        #expect(read.problemKind == nil)
        #expect(read.problemOutcome == kind)
        #expect(TaskPublication.ProblemKind(matching: problem) == kind)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(read) == encoder.encode(try JSONDecoder().decode(JSONValue.self, from: legacy)))
    }
}
