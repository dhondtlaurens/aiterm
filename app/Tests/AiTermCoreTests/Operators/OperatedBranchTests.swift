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

    @Test func theKeyIsNotRepeated() {
        #expect(OperatedBranch.name(ticket: "FE-1783", title: "FE-1783 Dependency updates: Vue and Vite", taken: [])
                == "chore/fe-1783-dependency-updates-vue-and-vite")
        #expect(OperatedBranch.name(ticket: "FE-1783", title: "fe-1783: Shop banner", taken: []) == "feat/fe-1783-shop-banner")
    }

    @Test func aJiraBugIsAFix() {
        #expect(OperatedBranch.name(ticket: "FE-2", title: "Cart total is off", issueType: "Bug", taken: []) == "fix/fe-2-cart-total-is-off")
    }

    @Test func theIssueTypeWinsOverTheTitle() {
        #expect(OperatedBranch.name(ticket: "FE-3", title: "Upgrade checkout", issueType: "Story", taken: []) == "feat/fe-3-upgrade-checkout")
        #expect(OperatedBranch.name(ticket: "FE-3", title: "Upgrade checkout", issueType: "chore", taken: []) == "chore/fe-3-upgrade-checkout")
        #expect(OperatedBranch.name(ticket: nil, title: "Shop banner", issueType: "fix", taken: []) == "fix/shop-banner")
    }

    @Test func aBlankIssueTypeLeavesItToTheTitle() {
        #expect(OperatedBranch.name(ticket: nil, title: "Bump Vite", issueType: " ", taken: []) == "chore/bump-vite")
    }

    @Test func aPlainTitleIsAFeature() {
        #expect(OperatedBranch.name(ticket: "FE-4", title: "Shop banner", taken: []) == "feat/fe-4-shop-banner")
    }

    @Test func anExplicitTypeIsKept() {
        #expect(OperatedBranch.name(ticket: nil, title: "Bump Vite", type: .feat, taken: []) == "feat/bump-vite")
    }
}
