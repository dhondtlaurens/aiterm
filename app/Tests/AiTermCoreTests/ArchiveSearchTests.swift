import Testing
import Foundation
@testable import AiTermCore

@Suite struct ArchiveSearchTests {
    func entry(_ title: String, branch: String = "feat/x", jira: String? = nil, summary: String = "", mr: Int? = nil,
               mrTitle: String = "", project: String = "repo", at: TimeInterval = 0) -> ArchiveSearch.Entry {
        let task = TaskItem(id: UUID(), projectId: UUID(), title: title, branch: branch, worktreePath: "/w", baseBranch: "main",
                            jira: jira.map { JiraRef(key: $0, summary: summary, url: "https://j/\($0)") },
                            mr: mr.map { MergeRequestRef(iid: $0, title: mrTitle, url: "https://g/\($0)") },
                            agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(timeIntervalSince1970: 0), windowId: nil)
        return .init(archived: ArchivedTask(task: task, archivedAt: Date(timeIntervalSince1970: at)), projectName: project, provider: .gitlab)
    }

    @Test func anEmptyOrBlankQueryListsEverythingNewestFirst() {
        let old = entry("Old", at: 1), new = entry("New", at: 2)
        #expect(ArchiveSearch.rank([old, new], query: "") == [new, old])
        #expect(ArchiveSearch.rank([old, new], query: "   ") == [new, old])
    }

    @Test func aMergeRequestNumberMatchesInEveryForm() {
        let review = entry("Header refactor", mr: 482), other = entry("Login 482 retry", at: 9)
        for query in ["482", "!482", "#482"] {
            #expect(ArchiveSearch.rank([other, review], query: query).first == review, "\(query)")
        }
        #expect(ArchiveSearch.rank([review], query: "!").isEmpty, "a bang alone is no number")
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

    @Test func theDateReadsRelativeTodayYesterdayThenAsADay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_791_800_000) // 12 Oct 2026, 09:33 UTC
        #expect(ArchiveDate.label(now.addingTimeInterval(-7200), now: now, calendar: calendar, locale: locale).contains("2"))
        #expect(ArchiveDate.label(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: locale) == "yesterday")
        #expect(ArchiveDate.label(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar, locale: locale) == "9 Oct")
        #expect(ArchiveDate.label(now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar, locale: locale) == "7 Sep 2025")
    }
}
