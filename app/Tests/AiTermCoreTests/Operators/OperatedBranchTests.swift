import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// A ticket split into several tasks gets a branch per task.
@Suite struct OperatedBranchTests {
    @Test func aTicketsTasksAreNamedAsNewTaskNamesThem() {
        #expect(OperatedBranch.name(ticket: "PLUTO-231", title: "Gift card API", taken: []) == "feat/pluto-231-gift-card-api")
        #expect(OperatedBranch.name(ticket: nil, title: "Tidy the README", type: .chore, taken: []) == "chore/tidy-the-readme")
    }

    @Test func twoTasksOfOneTicketWithTheSameTitleGetTwoBranches() {
        let first = OperatedBranch.name(ticket: "PLUTO-231", title: "Gift card", taken: [])
        let second = OperatedBranch.name(ticket: "PLUTO-231", title: "Gift card", taken: [first])
        let third = OperatedBranch.name(ticket: "PLUTO-231", title: "Gift card", taken: [first, second])
        #expect([first, second, third] == ["feat/pluto-231-gift-card", "feat/pluto-231-gift-card-2", "feat/pluto-231-gift-card-3"])
    }

    @Test func takenCountsTheProjectsTasksAndItsRepository() {
        var world = OperatedWorld()
        let run = world.addRun()
        world.addTask("PLUTO-231/api", run: run, branch: "feat/pluto-231-gift-card")
        let taken = OperatedBranch.taken(in: world.state, project: world.project.id, repositoryBranches: ["main", "feat/old-work"])
        #expect(taken == ["feat/pluto-231-gift-card", "main", "feat/old-work"])
        #expect(OperatedBranch.name(ticket: "PLUTO-231", title: "Gift card", taken: taken) == "feat/pluto-231-gift-card-2")
    }
}
