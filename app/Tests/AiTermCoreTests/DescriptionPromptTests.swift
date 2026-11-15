import Foundation
import Testing
@testable import AiTermCore

@Suite struct DescriptionPromptTests {
    @Test func contextContainsOnlyTheDescriptionsThatWereChosen() {
        let ticket = JiraTicket(key: "PAY-1", summary: "Ticket title", description: "Ticket description", issueType: "Task", status: "Open", url: "https://jira.example/PAY-1")
        let request = MergeRequest(iid: 7, title: "Request title", sourceBranch: "work", targetBranch: "main", author: "colleague", state: "open", draft: true, url: "https://git.example/7", description: "Request description")
        let prompt = AgentCommand.composePrompt(userText: "Review it", ticket: ticket, appendTicket: true, request: request, appendRequest: true) ?? ""
        #expect(prompt.contains("Ticket description") && prompt.contains("Request description"))
        #expect(!prompt.contains("Ticket title") && !prompt.contains("Request title") && !prompt.contains("PAY-1"))
        #expect(AgentCommand.composePrompt(userText: "Review it", ticket: ticket, appendTicket: false, request: request, appendRequest: false) == "Review it")
        #expect(AgentCommand.composePrompt(userText: " ", ticket: nil, appendTicket: true) == nil)
    }

    @Test func typingAWholeBranchKeepsItsExactNameAndStopsNameDerivation() {
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "m", reasoning: nil)
        draft.setTitle("First name")
        draft.setFullBranch("custom/topic")
        draft.setTitle("Another name")
        #expect(draft.branch == "custom/topic")
        draft.setFullBranch("plain-branch")
        #expect(draft.branch == "plain-branch")
        draft.setFullBranch("")
        #expect(draft.worktreeSlug.isEmpty)
    }
}
