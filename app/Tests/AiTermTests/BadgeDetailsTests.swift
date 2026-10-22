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

    @Test func aProjectCountTurnedOffLeavesTheMarkAndMenu() throws {
        let project = Project(id: UUID(), name: "AiTerm", path: "/tmp/aiterm", provider: .git, remoteUrl: nil,
                              addedAt: Date(), collapsed: false, jiraProjects: [jira])
        let full = try #require(ProjectJiraBadge.badge(for: project))
        #expect(full.label == "1")
        #expect(full.help == "Jira · SHOP Storefront")

        let compact = try #require(ProjectJiraBadge.badge(for: project, showsCount: false))
        #expect(compact.label == nil)
        #expect(compact.help == full.help)
        #expect(compact.items == full.items)
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
        #expect(TaskRowBadges(row: row(mr: pull), details: BadgeDetails(mergeRequest: false)).mergeRequest?.help == "#87 · Add diff setting")
    }

    @Test func eachDetailTurnsOffOnItsOwn() {
        let all = row(jiraKey: "SHOP-12", jiraUrl: "https://j/SHOP-12", mr: mr, diff: diff)

        let noTicket = TaskRowBadges(row: all, details: BadgeDetails(jiraTicket: false))
        #expect(noTicket.ticket == .init(label: nil, help: "SHOP-12 · https://j/SHOP-12", url: "https://j/SHOP-12"))
        #expect(noTicket.mergeRequest?.label == "!87")
        #expect(noTicket.diff != nil)

        let noMR = TaskRowBadges(row: all, details: BadgeDetails(mergeRequest: false))
        #expect(noMR.mergeRequest == .init(label: nil, help: "!87 · Add diff setting", url: mr.url, host: .gitLab))
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

/// A row too narrow for every badge gives up what it wears, least-needed first, so the status mark keeps
/// its slot: the VS Code counts fold to the plain mark, then whole badges drop from the end — the editor,
/// then the merge request, then the ticket.
@Suite struct TaskRowBadgeFitTests {
    private func badges(jiraKey: String? = "FE-1783", mr: MergeRequestRef? = .init(iid: 45, title: "t", url: "https://gitlab.example.com/mr/45"),
                        diff: BaseDiff? = BaseDiff(base: "main", stat: DiffStat(added: 1416, removed: 1072))) -> TaskRowBadges {
        TaskRowBadges(row: TaskRow(id: UUID(), title: "t", jiraKey: jiraKey, jiraUrl: nil, mr: mr, branch: .none,
                                   avatars: AvatarGroup(marks: [], overflow: 0), status: .idle, diff: diff),
                      details: BadgeDetails())
    }

    @Test func theDiffFoldsBeforeAnyBadgeDrops() {
        #expect(badges().fits(editor: true) == [
            .init(ticket: true, mergeRequest: true, editor: .diff),
            .init(ticket: true, mergeRequest: true, editor: .plain),
            .init(ticket: true, mergeRequest: true, editor: .none),
            .init(ticket: true, mergeRequest: false, editor: .none),
            .init(ticket: false, mergeRequest: false, editor: .none),
        ])
    }

    @Test func onlyWhatTheRowWearsIsGivenUp() {
        #expect(badges(mr: nil, diff: nil).fits(editor: true) == [
            .init(ticket: true, mergeRequest: false, editor: .plain),
            .init(ticket: true, mergeRequest: false, editor: .none),
            .init(ticket: false, mergeRequest: false, editor: .none),
        ])
        // No VS Code: no editor badge, counts or not.
        #expect(badges(jiraKey: nil).fits(editor: false) == [
            .init(ticket: false, mergeRequest: true, editor: .none),
            .init(ticket: false, mergeRequest: false, editor: .none),
        ])
        #expect(badges(jiraKey: nil, mr: nil, diff: nil).fits(editor: false) == [.init(ticket: false, mergeRequest: false, editor: .none)])
    }
}
