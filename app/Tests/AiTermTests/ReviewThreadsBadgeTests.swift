import Foundation
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm

/// What a merge request's badge says about its review threads: `2/5` behind a bubble once it has
/// one, the same bubble when all are resolved, and nothing it does not know.
@Suite struct ReviewThreadsBadgeTests {
    private let mr = MergeRequestRef(iid: 87, title: "Add diff setting", url: "https://gitlab.example.com/web/shop/-/merge_requests/87")
    private let bubble = IconSource.symbol("bubble.left")

    private func row(mr: MergeRequestRef?) -> TaskRow {
        TaskRow(id: UUID(), title: "t", jiraKey: nil, jiraUrl: nil, mr: mr, branch: .none,
                avatars: AvatarGroup(marks: [], overflow: 0), status: .idle)
    }

    private func badge(_ threads: ReviewThreads?, details: BadgeDetails = BadgeDetails()) -> TaskRowBadges.Link? {
        TaskRowBadges(row: row(mr: mr), details: details, threads: threads).mergeRequest
    }

    @Test func someResolvedReadsAsResolvedOfTotalBehindTheBubble() {
        let link = badge(ReviewThreads(resolved: 2, total: 5))
        #expect(link?.label == "!87")
        #expect(link?.threads == Badge.Suffix(icon: bubble, text: "2/5"))
        #expect(link?.help == "Add diff setting · 2 of 5 threads resolved")
        #expect(link?.accessibilityLabel == "!87, 2 of 5 threads resolved")
    }

    /// Covered, not finished: the count stays, behind the same bubble, with no check and no colour
    /// for the badge to carry.
    @Test func allResolvedStaysTheSameBubble() {
        let link = badge(ReviewThreads(resolved: 6, total: 6))
        #expect(link?.threads == Badge.Suffix(icon: bubble, text: "6/6"))
        #expect(link?.help == "Add diff setting · 6 of 6 threads resolved")
    }

    /// No thread yet, nothing read yet (a host not connected, no good read so far): the badge as it
    /// was before there were counts.
    @Test func noThreadOrNothingReadIsTheBadgeAsToday() {
        let today = TaskRowBadges(row: row(mr: mr), details: BadgeDetails()).mergeRequest
        #expect(today == .init(label: "!87", help: "Add diff setting", url: mr.url, host: .gitLab))
        #expect(badge(ReviewThreads(resolved: 0, total: 0)) == today)
        #expect(badge(nil) == today)
    }

    /// With the number switched off the mark keeps the count; the tooltip already names the reference.
    @Test func withTheNumberOffTheMarkKeepsTheCount() {
        let link = badge(ReviewThreads(resolved: 2, total: 5), details: BadgeDetails(mergeRequest: false))
        #expect(link?.label == nil)
        #expect(link?.threads == Badge.Suffix(icon: bubble, text: "2/5"))
        #expect(link?.help == "!87 · Add diff setting · 2 of 5 threads resolved")
        #expect(link?.accessibilityLabel == "!87 · Add diff setting, 2 of 5 threads resolved")
    }

    @Test func oneThreadIsSingular() {
        #expect(TaskRowBadges.words(ReviewThreads(resolved: 1, total: 1)) == "1 of 1 thread resolved")
        #expect(TaskRowBadges.words(ReviewThreads(resolved: 0, total: 1)) == "0 of 1 thread resolved")
        #expect(TaskRowBadges.words(ReviewThreads(resolved: 0, total: 2)) == "0 of 2 threads resolved")
    }

    @Test func aRowWithoutAMergeRequestHasNoCountToWear() {
        #expect(TaskRowBadges(row: row(mr: nil), details: BadgeDetails(), threads: ReviewThreads(resolved: 2, total: 5)).mergeRequest == nil)
    }

    /// Merged: the mark wears the check, and the tooltip and VoiceOver say so after the count.
    @Test func aMergedRequestIsCheckedAndSaysMerged() {
        let link = badge(ReviewThreads(resolved: 4, total: 4, merged: true))
        #expect(link?.checked == true)
        #expect(link?.threads?.text == "4/4")
        #expect(link?.help == "Add diff setting · 4 of 4 threads resolved · merged")
        #expect(link?.accessibilityLabel == "!87, 4 of 4 threads resolved, merged")
    }

    /// Merged without a thread, and with the number off: still checked, still said.
    @Test func aMergedRequestWithoutThreadsOrNumberIsStillChecked() {
        let bare = badge(ReviewThreads(resolved: 0, total: 0, merged: true))
        #expect(bare?.checked == true)
        #expect(bare?.threads == nil)
        #expect(bare?.help == "Add diff setting · merged")
        #expect(bare?.accessibilityLabel == "!87, merged")
        let markOnly = badge(ReviewThreads(resolved: 0, total: 0, merged: true), details: BadgeDetails(mergeRequest: false))
        #expect(markOnly?.checked == true)
        #expect(markOnly?.accessibilityLabel == "!87 · Add diff setting, merged")
    }

    @Test func anOpenRequestIsNotChecked() {
        #expect(badge(ReviewThreads(resolved: 2, total: 5))?.checked == false)
        #expect(badge(nil)?.checked == false)
    }

    /// A Jira ticket in a Done lane wears the check on its own mark; a GitLab issue is never asked,
    /// so it never does, whatever it is handed.
    @Test func aDoneJiraTicketIsCheckedAndAGitLabIssueNever() {
        func ticket(_ gitLabIssue: Bool, done: Bool) -> TaskRowBadges.Link? {
            var row = TaskRow(id: UUID(), title: "t", jiraKey: gitLabIssue ? "#53" : "SHOP-12", jiraUrl: "https://example/t", mr: nil,
                              branch: .none, avatars: AvatarGroup(marks: [], overflow: 0), status: .idle)
            row.ticketIsGitLabIssue = gitLabIssue
            return TaskRowBadges(row: row, details: BadgeDetails(), ticketDone: done).ticket
        }
        let done = ticket(false, done: true)
        #expect(done?.checked == true)
        #expect(done?.help == "https://example/t · done")
        #expect(done?.accessibilityLabel == "SHOP-12, done")
        #expect(ticket(false, done: false)?.checked == false)
        #expect(ticket(true, done: true)?.checked == false)
        #expect(ticket(true, done: true)?.help == "https://example/t")
    }

    @Test func aGitHubPullRequestCountsTheSameWay() {
        let pull = MergeRequestRef(iid: 12, title: "Faster images", url: "https://github.com/acme/shop/pull/12")
        let link = TaskRowBadges(row: row(mr: pull), details: BadgeDetails(), threads: ReviewThreads(resolved: 1, total: 4)).mergeRequest
        #expect(link?.host == .gitHub)
        #expect(link?.threads?.text == "1/4")
        #expect(link?.accessibilityLabel == "#12, 1 of 4 threads resolved")
    }
}
