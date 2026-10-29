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
}
