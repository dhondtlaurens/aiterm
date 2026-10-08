import Foundation
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm

/// What each sidebar badge prints once the Interface tab has turned its detail off: the mark stays
/// and still links, and the text it dropped moves into the tooltip so it is a hover away.
@Suite struct BadgeDetailsTests {
    private let jira = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront",
                                      siteURL: URL(string: "https://example.atlassian.net")!)

    private func row(jiraKey: String? = nil, jiraUrl: String? = nil, mr: MergeRequestRef? = nil,
                     diff: BaseDiff? = nil) -> TaskRow {
        TaskRow(id: UUID(), title: "t", jiraKey: jiraKey, jiraUrl: jiraUrl, mr: mr, branch: .none,
                avatars: AvatarGroup(marks: [], overflow: 0), status: .idle, diff: diff)
    }

    private let mr = MergeRequestRef(iid: 87, title: "Add diff setting", url: "https://gitlab.example.com/mr/87")
    private let diff = BaseDiff(base: "main", stat: DiffStat(added: 12, removed: 3))

    @Test func aProjectKeyTurnedOffLeavesTheMarkAndMovesTheKeyIntoTheTooltip() {
        let full = ProjectJiraBadge(jira: jira)
        #expect(full.label == "SHOP")
        #expect(full.help == "Storefront — https://example.atlassian.net/browse/SHOP")

        let compact = ProjectJiraBadge(jira: jira, showsKey: false)
        #expect(compact.label == nil)
        #expect(compact.help == "Storefront (SHOP) — https://example.atlassian.net/browse/SHOP")
        #expect(compact.target == full.target)
    }

    @Test func everyDetailOnDrawsTheRowAsItAlwaysWas() {
        let badges = TaskRowBadges(row: row(jiraKey: "SHOP-12", jiraUrl: "https://j/SHOP-12", mr: mr, diff: diff),
                                   details: BadgeDetails())
        #expect(badges.ticket == .init(label: "SHOP-12", help: "https://j/SHOP-12", url: "https://j/SHOP-12"))
        #expect(badges.mergeRequest == .init(label: "!87", help: "Add diff setting", url: mr.url, host: .gitLab))
        #expect(badges.diff == .init(added: 12, removed: 3))
        #expect(badges.editorHelp == diff.help)
    }

    @Test func aGitHubReviewWearsAHashNumber() {
        let pull = MergeRequestRef(iid: 87, title: "Add diff setting", url: "https://github.com/octocat/hello/pull/87")
        let badges = TaskRowBadges(row: row(mr: pull), details: BadgeDetails())
        #expect(badges.mergeRequest?.label == "#87")
        #expect(badges.mergeRequest?.host == .gitHub)
        #expect(TaskRowBadges(row: row(mr: pull), details: BadgeDetails(mergeRequest: false)).mergeRequest?.help == "#87 — Add diff setting")
    }

    @Test func eachDetailTurnsOffOnItsOwn() {
        let all = row(jiraKey: "SHOP-12", jiraUrl: "https://j/SHOP-12", mr: mr, diff: diff)

        let noTicket = TaskRowBadges(row: all, details: BadgeDetails(jiraTicket: false))
        #expect(noTicket.ticket == .init(label: nil, help: "SHOP-12 — https://j/SHOP-12", url: "https://j/SHOP-12"))
        #expect(noTicket.mergeRequest?.label == "!87")
        #expect(noTicket.diff != nil)

        let noMR = TaskRowBadges(row: all, details: BadgeDetails(mergeRequest: false))
        #expect(noMR.mergeRequest == .init(label: nil, help: "!87 — Add diff setting", url: mr.url, host: .gitLab))
        #expect(noMR.ticket?.label == "SHOP-12")

        // The counts leave the badge but not its tooltip, which already spells them out.
        let noDiff = TaskRowBadges(row: all, details: BadgeDetails(diff: false))
        #expect(noDiff.diff == nil)
        #expect(noDiff.editorHelp == diff.help)
        #expect(noDiff.ticket?.label == "SHOP-12")
    }

    @Test func aTicketWithoutALinkStillNamesItsKeyOnHover() {
        let badges = TaskRowBadges(row: row(jiraKey: "SHOP-12"), details: BadgeDetails(jiraTicket: false))
        #expect(badges.ticket == .init(label: nil, help: "SHOP-12", url: nil))
    }

    @Test func aRowWithNothingToShowWearsNoBadges() {
        let badges = TaskRowBadges(row: row(), details: BadgeDetails())
        #expect(badges.ticket == nil)
        #expect(badges.mergeRequest == nil)
        #expect(badges.diff == nil)
        #expect(badges.editorHelp == "Open in VS Code")
    }
}
