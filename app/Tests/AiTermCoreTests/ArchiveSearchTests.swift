import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct ArchiveSearchTests {
    func entry(_ title: String, branch: String = "feat/x", jira: String? = nil, summary: String = "", mr: Int? = nil,
               mrTitle: String = "", project: String = "repo", at: TimeInterval = 0) -> ArchiveSearch.Entry {
        let task = TaskItem.make(project: UUID(), title: title, branch: branch, worktreePath: "/w",
            jira: jira.map { JiraRef(key: $0, summary: summary, url: "https://j/\($0)") },
            mr: mr.map { MergeRequestRef(iid: $0, title: mrTitle, url: "https://g/\($0)") })
        return .init(archived: ArchivedTask(task: task, archivedAt: Date(timeIntervalSince1970: at)), projectName: project, provider: .gitlab)
    }

    @Test func anEmptyOrBlankQueryListsEverythingNewestFirst() {
        let old = entry("Old", at: 1), new = entry("New", at: 2)
        #expect(ArchiveSearch.rank([old, new], query: "") == [new, old])
        #expect(ArchiveSearch.rank([old, new], query: "   ") == [new, old])
    }

    /// A GitLab issue's key is `#53`, and searching for it finds the task that carries it.
    @Test func aGitLabIssueKeyFindsItsTask() {
        let task = entry("Constraints file", jira: "#53", summary: "Add a human-editable constraints file"), other = entry("Other", at: 9)
        #expect(ArchiveSearch.rank([other, task], query: "#53").first == task)
    }

    @Test func aMergeRequestNumberMatchesInEveryForm() {
        let review = entry("Header refactor", mr: 482), other = entry("Login 482 retry", at: 9)
        for query in ["482", "!482", "#482"] {
            #expect(ArchiveSearch.rank([other, review], query: query).first == review, "\(query)")
        }
        #expect(ArchiveSearch.rank([review], query: "!").isEmpty, "a bang alone is no number")
    }

    @Test func aMergeRequestNumberIsFoundWhileItIsBeingTyped() {
        let review = entry("Header refactor", mr: 482), other = entry("Login retry", at: 9)
        for query in ["!4", "!48", "#4", "#48", "48"] {
            #expect(ArchiveSearch.rank([other, review], query: query) == [review], "\(query)")
        }
        for query in ["!", "#"] {
            #expect(ArchiveSearch.rank([other, review], query: query).isEmpty, "\(query) alone")
        }
        #expect(ArchiveSearch.rank([review], query: "!9").isEmpty)
    }

    @Test func anExactTicketKeyOutranksEverythingElse() {
        let keyed = entry("Login", jira: "SHOP-12", at: 1), prefixed = entry("SHOP-123 follow-up", at: 2)
        #expect(ArchiveSearch.rank([prefixed, keyed], query: "shop-12") == [keyed, prefixed])
    }

    @Test func thePrefixOfAFieldOutranksTheStartOfAWordWhichOutranksTheMiddle() {
        let prefix = entry("Payment retry", at: 1), word = entry("Checkout payment", at: 2), middle = entry("Prepayments", at: 3)
        #expect(ArchiveSearch.rank([middle, word, prefix], query: "pay") == [prefix, word, middle])
    }

    @Test func aSubsequenceIsTheLastTier() {
        let fuzzy = entry("Checkout payment retry", at: 9), plain = entry("Payment", at: 1)
        #expect(ArchiveSearch.rank([fuzzy, plain], query: "chkpay") == [fuzzy])
        #expect(ArchiveSearch.rank([fuzzy, plain], query: "pay").first == plain)
    }

    @Test func branchProjectSummaryAndMergeRequestTitleAreSearchedToo() {
        let a = entry("A", branch: "fix/cart-totals"), b = entry("B", project: "storefront"),
            c = entry("C", jira: "X-1", summary: "Gift cards"), d = entry("D", mr: 7, mrTitle: "Drop jQuery")
        #expect(ArchiveSearch.rank([a, b, c, d], query: "cart") == [a])
        #expect(ArchiveSearch.rank([a, b, c, d], query: "storef") == [b])
        #expect(ArchiveSearch.rank([a, b, c, d], query: "gift") == [c])
        #expect(ArchiveSearch.rank([a, b, c, d], query: "jquery") == [d])
    }

    @Test func caseAndDiacriticsAreIgnored() {
        let café = entry("Café menu")
        #expect(ArchiveSearch.rank([café], query: "CAFE") == [café])
    }

    @Test func nothingMatchingIsDropped() {
        #expect(ArchiveSearch.rank([entry("Login")], query: "zebra").isEmpty)
    }

    /// The Archive groups by when a row was archived: Today, Yesterday, This week, then each month, with its year once
    /// it is another year's.
    @Test func theGroupIsTodayYesterdayThisWeekThenTheMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.firstWeekday = 2
        let locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_791_800_000 + 3 * 86_400) // Thu 15 Oct 2026, 09:33 UTC
        func group(_ days: Double) -> String {
            ArchiveDate.group(now.addingTimeInterval(-days * 86_400), now: now, calendar: calendar, locale: locale)
        }
        #expect(group(2.0 / 24) == "Today")
        #expect(group(1) == "Yesterday")
        #expect(group(3) == "This week")
        #expect(group(4) == "October")
        #expect(group(20) == "September")
        #expect(group(400) == "September 2025")
    }

}
