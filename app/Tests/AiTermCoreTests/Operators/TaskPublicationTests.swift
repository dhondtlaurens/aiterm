import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct TaskPublicationTests {
    /// A publication saved before the merge steps existed reads as not merged, nothing waiting.
    @Test func anEarlierPublicationReadsWithItsNewFieldsEmpty() throws {
        let json = Data(#"{"pushedSHA":"4f2a91c","mergeRequestURL":"https://git.example.net/web/acme-web/-/merge_requests/12"}"#.utf8)
        let read = try JSONDecoder().decode(TaskPublication.self, from: json)
        #expect(read == TaskPublication(pushedSHA: "4f2a91c", mergeRequestURL: "https://git.example.net/web/acme-web/-/merge_requests/12"))
        #expect(!read.merged)
    }

    /// An empty object and a key a newer build added both read: nothing is required, nothing unknown fails.
    @Test func anEmptyPublicationAndAnUnknownKeyBothRead() throws {
        #expect(try JSONDecoder().decode(TaskPublication.self, from: Data("{}".utf8)) == TaskPublication())
        let newer = Data(#"{"pushedSHA":"4f2a91c","reviewers":["ann"],"merged":true}"#.utf8)
        #expect(try JSONDecoder().decode(TaskPublication.self, from: newer) == TaskPublication(pushedSHA: "4f2a91c", merged: true))
    }

    @Test func everyStepRoundTripsOnATask() throws {
        var world = OperatedWorld()
        let task = world.addTask("PLUTO-231", run: world.addRun(), state: .accepted, end: .merge, acceptedSHA: "4f2a91c")
        world.update(task) {
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

    @Test func theMergeWaitIsBounded() {
        #expect(OperatorTiming.mergePoll == 30)
        #expect(OperatorTiming.mergeWait == 3600)
    }
}
