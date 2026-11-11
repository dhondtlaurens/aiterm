import Testing
import Foundation
import Synchronization
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// New Review's ticket field: picking a ticket finds its merge request, picking a merge request
/// finds its ticket, and each says so; nothing found says so too.
@Suite @MainActor struct ReviewTicketFieldTests {
    let project = Project(id: UUID(), name: "jarvis", path: "/tmp/p", provider: .gitlab,
                          remoteUrl: "git@git.example.net:jarvis/jarvis.git", addedAt: Date(), collapsed: false)
    let ticket = JiraTicket(key: "JVS-5793", summary: "invoice_to_exact flags unchanged invoices", description: "## Acceptance\n- unchanged",
                            issueType: "Bug", status: "Review", url: "https://example.atlassian.net/browse/JVS-5793")
    let other = JiraTicket(key: "JVS-5744", summary: "add the function switches", description: nil,
                           issueType: "Task", status: "Review", url: "https://example.atlassian.net/browse/JVS-5744")

    private func request(_ iid: Int, _ title: String, branch: String) -> MergeRequest {
        MergeRequest(iid: iid, title: title, sourceBranch: branch, targetBranch: "master", author: nil, state: "opened",
                     draft: true, url: "https://git.example.net/jarvis/jarvis/-/merge_requests/\(iid)")
    }

    private func model(requests: @escaping @Sendable (JiraTicket) async throws -> TicketMergeRequests.Found = { _ in .init(requests: [], complete: true) },
                       ticket: @escaping @Sendable (MergeRequest) async throws -> JiraTicket? = { _ in nil }) -> ReviewCreationModel {
        let lookup = ReviewTicketLookup(search: { _ in [] }, requests: requests, ticket: ticket,
                                        repository: "jarvis/jarvis", jiraConnected: true, jiraProjects: ["JVS"])
        return ReviewCreationModel(project: project, draft: ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil),
                                   context: .scratch(availableAgents: { [.claude] }, catalogue: ScratchHome.catalogue,
                                                     defaults: ScratchDefaults.make(), canChangeWorkspace: { true }),
                                   searchMergeRequests: { _ in [] }, tickets: lookup, createReview: { _ in }, recover: { _ in })
    }

    @Test func aTicketWithOneOpenRequestPicksItAndSaysWhereItCameFrom() async {
        let only = request(545, "Draft: JVS-5793: invoice_to_exact flags unchanged invoices", branch: "agent/JVS-5793")
        let m = model(requests: { _ in .init(requests: [only], complete: true) })
        m.pickTicket(ticket)
        await m.kind.lookupTask?.value
        #expect(m.draft.mr == only)
        #expect(m.draft.branch == "agent/JVS-5793")
        #expect(m.draft.mrFoundFrom == "JVS-5793")
        #expect(m.ticketLookupNote == nil)
    }

    @Test func severalOpenTheListOnThemAndCountThem() async {
        let found = [request(552, "JVS-5747: retry", branch: "agent/JVS-5747-2"), request(549, "JVS-5747: first", branch: "agent/JVS-5747")]
        let m = model(requests: { _ in .init(requests: found, complete: true) })
        let offers = m.requestListOffers
        m.pickTicket(ticket)
        await m.kind.lookupTask?.value
        #expect(m.draft.mr == nil)
        #expect(m.results == found)
        #expect(m.requestListOffers == offers + 1)
        #expect(m.ticketLookupNote == "2 open merge requests mention JVS-5793.")
    }

    @Test func noneSaysSoAndStartsTheBranchSearchFromTheKey() async {
        let m = model()
        m.pickTicket(other)
        await m.kind.lookupTask?.value
        #expect(m.ticketLookupNote == "No open merge request for JVS-5744 in jarvis/jarvis.")
        #expect(m.branchQuery == "JVS-5744")
        #expect(m.draft.title == "add the function switches")
    }

    /// Past the page cap the sheet claims neither none nor only one.
    @Test func anIncompleteAnswerPicksNothing() async {
        let one = request(12, "JVS-5744 the old one", branch: "JVS-5744")
        let m = model(requests: { _ in .init(requests: [one], complete: false) })
        m.pickTicket(other)
        await m.kind.lookupTask?.value
        #expect(m.draft.mr == nil)
        #expect(m.ticketLookupNote == "1 open merge request mentions JVS-5744.")

        let none = model(requests: { _ in .init(requests: [], complete: false) })
        none.pickTicket(other)
        await none.kind.lookupTask?.value
        #expect(none.ticketLookupNote == "None of the 500 most recent open merge requests in jarvis/jarvis mention JVS-5744.")
    }

    @Test func aRequestPickedByHandFindsItsTicket() async {
        let picked = request(545, "Draft: JVS-5793: invoice", branch: "agent/JVS-5793")
        let m = model(ticket: { _ in self.ticket })
        m.pick(picked)
        await m.kind.lookupTask?.value
        #expect(m.draft.ticket == ticket)
        #expect(m.draft.ticketFoundFrom == "!545")
    }

    /// A merge request picked by hand stays when a ticket is picked after it: no lookup replaces it.
    @Test func aTicketAfterARequestByHandLooksNothingUp() async {
        let picked = request(545, "Draft: JVS-5793: invoice", branch: "agent/JVS-5793")
        let asked = Mutex(0)
        let m = model(requests: { _ in asked.withLock { $0 += 1 }; return .init(requests: [], complete: true) })
        m.pick(picked)
        await m.kind.lookupTask?.value
        m.pickTicket(other)
        await m.kind.lookupTask?.value
        #expect(m.draft.mr == picked)
        #expect(asked.withLock { $0 } == 0)
        #expect(m.ticketLookupNote == nil)
    }

    /// A lookup that answers after another ticket was picked is dropped.
    @Test func aStaleLookupIsDropped() async {
        let slow = request(1, "JVS-5793: slow", branch: "slow")
        let entered = TestLatch(), answer = TestLatch()
        let m = model(requests: { ticket in
            if ticket.key == "JVS-5793" { entered.signal(); await answer.wait() }
            return .init(requests: ticket.key == "JVS-5793" ? [slow] : [], complete: true)
        })
        m.pickTicket(ticket)
        let first = m.kind.lookupTask
        await entered.wait()
        m.pickTicket(other)
        await m.kind.lookupTask?.value
        answer.signal()
        await first?.value
        #expect(m.draft.mr == nil)
        #expect(m.draft.ticket == other)
    }

    @Test func theReviewersPromptCarriesTheTicketUnlessUnticked() {
        let m = model()
        m.pickTicket(ticket)
        m.promptText = "Review this"
        #expect(m.composedPrompt == "Review this\n\nJVS-5793: invoice_to_exact flags unchanged invoices\n\n## Acceptance\n- unchanged")
        m.draft.appendTicket = false
        #expect(m.composedPrompt == "Review this")
    }

    // -- the sidebar's badges -------------------------------------------------------------------

    private func row(ticket key: String?, gitLabIssue: Bool, mr: Int?) -> TaskRow {
        var row = TaskRow(id: UUID(), title: "t", jiraKey: key, jiraUrl: key.map { "https://x/\($0)" },
                          mr: mr.map { MergeRequestRef(iid: $0, title: "MR", url: "https://git.example.net/ai/agentflow/-/merge_requests/\($0)") },
                          branch: .none, avatars: AvatarGroup(marks: [], overflow: 0), status: .idle)
        row.ticketIsGitLabIssue = gitLabIssue
        return row
    }

    /// A GitLab issue beside a GitLab merge request shares one mark; a Jira ticket keeps its own.
    @Test func aGitLabIssueAndItsRequestShareOneMark() {
        let details = BadgeDetails()
        #expect(TaskRowBadges(row: row(ticket: "#53", gitLabIssue: true, mr: 29), details: details).sharesGitLabMark)
        #expect(!TaskRowBadges(row: row(ticket: "JVS-5793", gitLabIssue: false, mr: 545), details: details).sharesGitLabMark)
        #expect(!TaskRowBadges(row: row(ticket: "#53", gitLabIssue: true, mr: nil), details: details).sharesGitLabMark)
        let issue = TaskRowBadges(row: row(ticket: "#53", gitLabIssue: true, mr: nil), details: details)
        #expect(issue.ticket?.host == .gitLab)
    }
}
