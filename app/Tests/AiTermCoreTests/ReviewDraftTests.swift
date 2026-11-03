import Testing
import Foundation
@testable import AiTermCore

@Suite struct ReviewDraftTests {
    let mr = MergeRequest(iid: 4, title: "Add gift card", sourceBranch: "feat-gift-card",
                          targetBranch: "main", author: "Sam Rivera", state: "opened", draft: false,
                          url: "https://git.example.net/web/acme-web/-/merge_requests/4")

    private func draft() -> ReviewDraft {
        ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil)
    }

    @Test func testPickingAMergeRequestFillsTheNameAndBranch() {
        var d = draft()
        d.apply(mr: mr)
        #expect(d.title == "Add gift card")
        #expect(d.branch == "feat-gift-card")
    }

    @Test func testHandEditedFieldsSurviveALaterPick() {
        var d = draft()
        d.setTitle("Second pass on the hero")
        d.apply(mr: mr)
        #expect(d.title == "Second pass on the hero")
        #expect(d.branch == "feat-gift-card")
    }

    /// A clickable `!4` chip above a branch that is not the merge request's source branch would be
    /// a lie that navigates somewhere, so editing the branch drops the merge request.
    @Test func testEditingTheBranchClearsTheMergeRequest() {
        var d = draft()
        d.apply(mr: mr)
        d.setBranch("feat-something-else")
        #expect(d.mr == nil)
        #expect(d.branch == "feat-something-else")
        #expect(d.title == "Add gift card")
    }

    /// SwiftUI writes a TextField's value back through its binding when editing begins and ends,
    /// not only when the text changes — so being handed the value it already holds must be a no-op
    /// or a click into another field would clear the merge request.
    @Test func testBeingHandedTheSameBranchIsANoOp() {
        var d = draft()
        d.apply(mr: mr)
        d.setBranch("feat-gift-card")
        #expect(d.mr == mr)
    }

    @Test func testClearingTheMergeRequestLeavesTheBranchAndName() {
        var d = draft()
        d.apply(mr: mr)
        d.apply(mr: nil)
        #expect(d.mr == nil)
        #expect(d.branch == "feat-gift-card")
        #expect(d.title == "Add gift card")
    }

    // -- the ticket, and the merge request and ticket filling each other ------------------------

    let ticket = JiraTicket(key: "JVS-5793", summary: "invoice_to_exact flags unchanged invoices", description: nil,
                            issueType: "Bug", status: "Review", url: "https://example.atlassian.net/browse/JVS-5793")
    let other = JiraTicket(key: "JVS-5744", summary: "add the function switches", description: nil,
                           issueType: "Task", status: "Review", url: "https://example.atlassian.net/browse/JVS-5744")

    @Test func aTicketAloneNamesTheReview() {
        var d = draft()
        d.apply(ticket: ticket)
        #expect(d.title == "invoice_to_exact flags unchanged invoices")
        #expect(d.branch.isEmpty)
        #expect(d.appendTicket)
    }

    @Test func aMergeRequestFoundFromTheTicketFillsTheNameAndBranchAndSaysSo() {
        var d = draft()
        d.apply(ticket: ticket)
        d.found(mr: mr, from: "JVS-5793")
        #expect(d.mr == mr)
        #expect(d.title == "Add gift card")
        #expect(d.branch == "feat-gift-card")
        #expect(d.mrFoundFrom == "JVS-5793")
        #expect(d.ticketFoundFrom == nil)
    }

    @Test func aTicketFoundFromTheMergeRequestSaysSo() {
        var d = draft()
        d.apply(mr: mr)
        d.found(ticket: ticket, from: "!4")
        #expect(d.ticket == ticket)
        #expect(d.ticketFoundFrom == "!4")
        #expect(d.mrFoundFrom == nil)
    }

    /// A field set by hand is never overwritten by what the other field's lookup finds.
    @Test func aLookupNeverReplacesAPickByHand() {
        var d = draft()
        d.apply(mr: mr)
        d.apply(ticket: ticket)
        let found = MergeRequest(iid: 9, title: "Other", sourceBranch: "other", targetBranch: "main",
                                 author: nil, state: "opened", draft: false, url: "u9")
        d.found(mr: found, from: "JVS-5793")
        #expect(d.mr == mr)
        #expect(d.mrFoundFrom == nil)

        var e = draft()
        e.apply(ticket: other)
        e.apply(mr: mr)
        e.found(ticket: ticket, from: "!4")
        #expect(e.ticket == other)
    }

    /// Picking another ticket by hand drops the merge request the first one found, and the branch
    /// it filled, so the new ticket's lookup can fill them again.
    @Test func anotherTicketByHandDropsWhatTheFirstFound() {
        var d = draft()
        d.apply(ticket: ticket)
        d.found(mr: mr, from: "JVS-5793")
        d.apply(ticket: other)
        #expect(d.mr == nil)
        #expect(d.mrFoundFrom == nil)
        #expect(d.branch.isEmpty)
        #expect(d.title == "add the function switches")
        let next = MergeRequest(iid: 25, title: "JVS-5744 add switches", sourceBranch: "JVS-5744", targetBranch: "master",
                                author: nil, state: "opened", draft: false, url: "u25")
        d.found(mr: next, from: "JVS-5744")
        #expect(d.mr == next)
        #expect(d.branch == "JVS-5744")
    }

    /// Picking another merge request by hand drops the ticket the first one found.
    @Test func anotherMergeRequestByHandDropsTheTicketTheFirstFound() {
        var d = draft()
        d.apply(mr: mr)
        d.found(ticket: ticket, from: "!4")
        let next = MergeRequest(iid: 9, title: "Other", sourceBranch: "other", targetBranch: "main",
                                author: nil, state: "opened", draft: false, url: "u9")
        d.apply(mr: next)
        #expect(d.ticket == nil)
        #expect(d.ticketFoundFrom == nil)
    }

    /// A branch typed while the ticket's lookup ran is kept: the request it finds afterwards is refused.
    @Test func aRequestFoundAfterABranchWasTypedIsRefused() {
        var d = draft()
        d.apply(ticket: ticket)
        d.setBranch("feat/elsewhere")
        d.found(mr: mr, from: "JVS-5793")
        #expect(d.mr == nil)
        #expect(d.mrFoundFrom == nil)
        #expect(d.branch == "feat/elsewhere")
    }

    /// Editing the branch drops the merge request, and with it the line saying where it was found.
    @Test func editingTheBranchDropsTheFoundLine() {
        var d = draft()
        d.apply(ticket: ticket)
        d.found(mr: mr, from: "JVS-5793")
        d.setBranch("elsewhere")
        #expect(d.mr == nil)
        #expect(d.mrFoundFrom == nil)
        #expect(d.ticket == ticket)
    }

    @Test func testReviewWorktreeDirectoryIsPrefixed() {
        #expect(BranchNaming.reviewSlug(branch: "feat/gift-card") == "review-gift-card")
        #expect(BranchNaming.reviewSlug(branch: "feat-gift-card") == "review-feat-gift-card")
    }
}
