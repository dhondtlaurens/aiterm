import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// GitLab issues as tickets, the one ticket search over both sources, and a ticket's merge requests.
@Suite struct TicketSourcesTests {
    let config = GitLabConfig(hostURL: URL(string: "https://git.example.net")!, token: "tok")

    private func request(_ iid: Int, title: String, branch: String, description: String? = nil,
                         state: String = "opened", project: String = "jarvis/jarvis") -> [String: Any] {
        var payload: [String: Any] = ["iid": iid, "title": title, "source_branch": branch, "target_branch": "master",
                                      "state": state, "draft": false,
                                      "web_url": "https://git.example.net/\(project)/-/merge_requests/\(iid)"]
        if let description { payload["description"] = description }
        return payload
    }

    private func issue(_ iid: Int, title: String, labels: [String], updated: String) -> [String: Any] {
        ["iid": iid, "title": title, "labels": labels, "description": "Body of \(iid)", "updated_at": updated,
         "web_url": "https://git.example.net/ai/agentflow/-/issues/\(iid)"]
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    // -- GitLab issues --------------------------------------------------------------------------

    @Test func issuesBecomeTicketsKeyedByNumber() async throws {
        let stub = StubSession { _ in (200, self.json([self.issue(55, title: "Opt-in Entire", labels: ["priority::medium", "enhancement"],
                                                                  updated: "2026-11-02T10:00:00.000Z")])) }
        let found = try await GitLabClient(config: config, project: "ai/agentflow", session: stub.session).issues(search: "")
        let ticket = try #require(found.first)
        #expect(ticket.key == "#55")
        #expect(ticket.status == "enhancement")
        #expect(ticket.source == .gitLab(project: "ai/agentflow"))
        #expect(ticket.issueNumber == 55)
        #expect(ticket.branchKey == "55")
        #expect(ticket.description == "Body of 55")
        #expect(ticket.updated != nil)
        let url = try #require(stub.lastRequest?.url?.absoluteString)
        #expect(url == "https://git.example.net/api/v4/projects/ai%2Fagentflow/issues?state=opened&order_by=updated_at&per_page=25")
    }

    @Test(arguments: ["#53", "53"])
    func aNumberIsThatIssue(_ query: String) async throws {
        let stub = StubSession { _ in (200, self.json(self.issue(53, title: "Constraints", labels: [], updated: "2026-05-17T10:00:00Z"))) }
        let found = try await GitLabClient(config: config, project: "ai/agentflow", session: stub.session).issues(search: query)
        #expect(found.map(\.key) == ["#53"])
        #expect(found.first?.status == nil)
        #expect(stub.lastRequest?.url?.path.hasSuffix("/issues/53") == true)
    }

    /// A project whose issues are off, or that the token cannot see, simply has none.
    @Test(arguments: [403, 404])
    func issuesOffIsNoIssues(_ status: Int) async throws {
        let stub = StubSession { _ in (status, Data("{}".utf8)) }
        let found = try await GitLabClient(config: config, project: "jarvis/jarvis", session: stub.session).issues(search: "")
        #expect(found.isEmpty)
    }

    /// A token GitLab no longer accepts is a failure the picker shows, not a project without issues.
    @Test func anExpiredTokenIsAnError() async {
        let stub = StubSession { _ in (401, Data("{}".utf8)) }
        let client = GitLabClient(config: config, project: "ai/agentflow", session: stub.session)
        await #expect(throws: GitLabError.unauthorized) { try await client.issues(search: "") }
    }

    @Test func anIssuesLabelsChooseTheBranchType() {
        #expect(BranchType(issueType: "bugfix priority::medium") == .fix)
        #expect(BranchType(issueType: "priority::low refactor") == .chore)
        #expect(BranchType(issueType: "enhancement priority::high") == .feat)
    }

    @Test func anIssueNamesItsBranchByNumber() {
        let ticket = JiraTicket(key: "#55", summary: "Opt-in Entire (entire.io) integration", description: nil,
                                issueType: "enhancement", status: "enhancement", url: "u", source: .gitLab(project: "ai/agentflow"))
        var draft = TaskDraft(ticket: nil, baseBranch: "master", agent: .claude, model: "opus", reasoning: nil)
        draft.apply(ticket: ticket)
        #expect(draft.branch == "feat/55-opt-in-entire-entire-io-integration")
    }

    // -- the one search -------------------------------------------------------------------------

    private func ticket(_ key: String, _ seconds: TimeInterval?, gitLab: Bool = false) -> JiraTicket {
        JiraTicket(key: key, summary: key, description: nil, issueType: nil, status: nil, url: key,
                   source: gitLab ? .gitLab(project: "ai/agentflow") : .jira,
                   updated: seconds.map { Date(timeIntervalSince1970: $0) })
    }

    struct Failed: LocalizedError { let errorDescription: String? }

    @Test func bothSourcesInOneListNewestFirst() async throws {
        let search = TicketSearch(jira: { _ in [self.ticket("JVS-1", 100), self.ticket("JVS-2", 300)] }, jiraUnavailable: "connect",
                                  gitLabIssues: { _ in [self.ticket("#5", 200, gitLab: true), self.ticket("#6", nil, gitLab: true)] })
        #expect(try await search.tickets(matching: "").map(\.key) == ["JVS-2", "#5", "JVS-1", "#6"])
    }

    /// A typed search keeps the sources' own order, the exact key first, however old it is.
    @Test func aSearchKeepsTheExactKeyFirst() async throws {
        let prefixes = (570...575).map { self.ticket("JVS-\($0)", TimeInterval(100 + $0)) }
        let search = TicketSearch(jira: { _ in [self.ticket("JVS-57", 1)] + prefixes }, jiraUnavailable: "connect",
                                  gitLabIssues: { _ in [self.ticket("#57", 999, gitLab: true)] })
        #expect(try await search.tickets(matching: "jvs-57").prefix(2).map(\.key) == ["JVS-57", "JVS-570"])
        #expect(try await search.tickets(matching: "57").first?.key == "#57")
    }

    @Test func jiraNotConnectedLeavesTheIssuesWithNoLine() async throws {
        let search = TicketSearch(jira: nil, jiraUnavailable: "Connect Jira",
                                  gitLabIssues: { _ in [self.ticket("#5", 1, gitLab: true)] })
        #expect(try await search.tickets(matching: "").map(\.key) == ["#5"])
    }

    @Test func jiraNotConnectedAndNoIssuesSaysConnect() async {
        let search = TicketSearch(jira: nil, jiraUnavailable: "Connect Jira", gitLabIssues: { _ in [] })
        await #expect { try await search.tickets(matching: "") } throws: { $0.localizedDescription == "Connect Jira" }
    }

    /// With Jira not connected, GitLab failing is the reason shown, not "connect Jira".
    @Test func gitLabFailingWithoutJiraSaysWhatGitLabSaid() async {
        let search = TicketSearch(jira: nil, jiraUnavailable: "Connect Jira",
                                  gitLabIssues: { _ in throw GitLabError.unauthorized })
        await #expect(throws: GitLabError.unauthorized) { try await search.tickets(matching: "") }
    }

    @Test func gitLabFailingShowsJiraAndSaysSo() async throws {
        let search = TicketSearch(jira: { _ in [self.ticket("JVS-1", 1)] }, jiraUnavailable: "connect",
                                  gitLabIssues: { _ in throw Failed(errorDescription: "down") })
        do {
            _ = try await search.tickets(matching: "")
            Issue.record("expected a partial answer")
        } catch let partial as PartialSearch<JiraTicket> {
            #expect(partial.items.map(\.key) == ["JVS-1"])
            #expect(partial.message == TicketSearch.issuesFailed)
        }
    }

    @Test func jiraFailingWithIssuesShowsTheIssuesAndJirasReason() async throws {
        let search = TicketSearch(jira: { _ in throw Failed(errorDescription: "Jira is down") }, jiraUnavailable: "connect",
                                  gitLabIssues: { _ in [self.ticket("#5", 1, gitLab: true)] })
        do {
            _ = try await search.tickets(matching: "")
            Issue.record("expected a partial answer")
        } catch let partial as PartialSearch<JiraTicket> {
            #expect(partial.items.map(\.key) == ["#5"])
            #expect(partial.message == "Jira is down")
        }
    }

    // -- a ticket's merge requests --------------------------------------------------------------

    private func publisher(_ handler: @escaping StubURLProtocol.Handler) -> (GitLabClient, StubSession) {
        let stub = StubSession(handler: handler)
        return (GitLabClient(config: config, project: "jarvis/jarvis", session: stub.session), stub)
    }

    private let jiraTicket = JiraTicket(key: "JVS-5744", summary: "switches", description: nil, issueType: nil, status: "Review", url: "u")

    @Test func aKeyIsAWholeToken() {
        func mr(_ title: String, _ branch: String, _ body: String? = nil) -> MergeRequest {
            MergeRequest(iid: 1, title: title, sourceBranch: branch, targetBranch: "master", author: nil, state: "opened",
                         draft: false, url: "u", description: body)
        }
        #expect(TicketMergeRequests.mentions("JVS-5744", mr("JVS-5744 add switches", "x")))
        #expect(TicketMergeRequests.mentions("JVS-5744", mr("Draft: stub", "agent/JVS-5744-2")))
        #expect(TicketMergeRequests.mentions("JVS-5744", mr("Stub", "x", "Part of jvs-5744.")))
        #expect(!TicketMergeRequests.mentions("JVS-57", mr("JVS-5744 add switches", "JVS-5744")))
        #expect(!TicketMergeRequests.mentions("JVS-5744", mr("XJVS-5744", "JVS-57440")))
    }

    /// GitLab's text search reads titles and descriptions only, so the open requests are read and
    /// matched here: a key only in the branch, on the second page, is found.
    @Test func aKeyOnlyInTheBranchOnPageTwoIsFound() async throws {
        let firstPage = (1...100).map { request($0, title: "Other \($0)", branch: "other-\($0)") }
        let secondPage = [request(540, title: "Draft: stub change", branch: "agent/JVS-5744"),
                          request(541, title: "JVS-57 something", branch: "JVS-57")]
        let first = json(firstPage), second = json(secondPage)
        let (repository, stub) = publisher { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            return (200, page == "2" ? second : first)
        }
        let found = try await TicketMergeRequests.requests(for: jiraTicket, in: repository)
        #expect(found.requests.map(\.iid) == [540])
        #expect(found.complete)
        #expect(stub.requests.count == 2)
    }

    /// Past the page cap the answer is incomplete: neither none nor only one can be claimed.
    @Test func thePageCapMakesTheAnswerIncomplete() async throws {
        let full = (1...100).map { request($0, title: "Other \($0)", branch: "other-\($0)") }
        let older = [request(12, title: "JVS-5744 the old one", branch: "JVS-5744")]
        let olderData = json(older), fullData = json(full)
        let (repository, stub) = publisher { request in
            let searched = request.url!.query?.contains("search=") == true
            return (200, searched ? olderData : fullData)
        }
        let found = try await TicketMergeRequests.requests(for: jiraTicket, in: repository)
        // The host's own search still finds an older one by its title; the answer stays incomplete.
        #expect(found.requests.map(\.iid) == [12])
        #expect(!found.complete)
        #expect(stub.requests.count == TicketMergeRequests.pages + 1)
    }

    @Test func anIssuesRequestsAreTheOpenOnesHereThatCloseOrMentionIt() async throws {
        let closing = [request(29, title: "Constraints file", branch: "53-add-constraints", project: "ai/agentflow")]
        let related = [request(29, title: "Constraints file", branch: "53-add-constraints", project: "ai/agentflow"),
                       request(30, title: "Merged one", branch: "x", state: "merged", project: "ai/agentflow"),
                       request(7, title: "Elsewhere", branch: "y", project: "ai/other")]
        let closingData = json(closing), relatedData = json(related)
        let stub = StubSession { request in
            (200, request.url!.path.hasSuffix("closed_by") ? closingData : relatedData)
        }
        let repository = GitLabClient(config: config, project: "ai/agentflow", session: stub.session)
        let issue = JiraTicket(key: "#53", summary: "Constraints", description: nil, issueType: nil, status: nil, url: "u",
                               source: .gitLab(project: "ai/agentflow"))
        let found = try await TicketMergeRequests.requests(for: issue, in: repository)
        #expect(found.requests.map(\.iid) == [29])
        #expect(found.complete)
        #expect(stub.requests.count == 2) // concurrency would still make these same two requests; dropped.
    }

    @Test func aRequestNamesItsTicket() {
        func mr(_ title: String, _ branch: String, _ body: String? = nil) -> MergeRequest {
            MergeRequest(iid: 1, title: title, sourceBranch: branch, targetBranch: "master", author: nil, state: "opened",
                         draft: false, url: "u", description: body)
        }
        #expect(TicketMergeRequests.reference(of: mr("Draft: JVS-5793: invoice", "agent/JVS-5793"), issues: false) == .jira("JVS-5793"))
        #expect(TicketMergeRequests.reference(of: mr("Dependency updates", "feat/fe-1783-deps"), issues: false) == .jira("FE-1783"))
        #expect(TicketMergeRequests.reference(of: mr("feat: constraints", "53-add-constraints", "Entire-Checkpoint\n\nCloses #53"), issues: true) == .gitLabIssue(53))
        #expect(TicketMergeRequests.reference(of: mr("feat: constraints", "53-add-constraints"), issues: true) == .gitLabIssue(53))
        #expect(TicketMergeRequests.reference(of: mr("Tidy up", "chore/tidy"), issues: true) == nil)
    }

    /// An MR picked from the list carries its description, where `Closes #53` is.
    @Test func thePickersRequestsCarryTheirDescription() async throws {
        let stub = StubSession { _ in (200, self.json([self.request(29, title: "feat", branch: "x", description: "Closes #53")])) }
        let found = try await GitLabClient(config: config, project: "ai/agentflow", session: stub.session).mergeRequests(search: "")
        #expect(found.first?.description == "Closes #53")
    }

    // -- saves, prompts and publishing ----------------------------------------------------------

    @Test func aSavedRefWithoutASourceIsJiraAndJiraIsWrittenWithoutOne() throws {
        let old = try JSONDecoder().decode(JiraRef.self, from: Data(#"{"key":"FE-1","summary":"s","url":"u"}"#.utf8))
        #expect(old.source == .jira)
        let written = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!written.contains("source"))
        let issue = JiraRef(key: "#53", summary: "s", url: "u", source: .gitLab(project: "ai/agentflow"))
        #expect(try JSONDecoder().decode(JiraRef.self, from: JSONEncoder().encode(issue)) == issue)
    }

    /// An operated task with a GitLab issue links it from the request's description, not its title.
    @Test func thePublishedRequestClosesItsIssue() {
        func task(_ ref: JiraRef) -> TaskItem {
            TaskItem(id: UUID(), projectId: UUID(), title: "Constraints file", branch: "feat/53-constraints", worktreePath: "/w",
                     baseBranch: "master", jira: ref, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil,
                     appendTicket: true, createdAt: Date(timeIntervalSince1970: 0), windowId: nil)
        }
        let issue = task(JiraRef(key: "#53", summary: "s", url: "u", source: .gitLab(project: "ai/agentflow")))
        let jira = task(JiraRef(key: "FE-1", summary: "s", url: "u"))
        let accepted = TaskAcceptance(resultSHA: "abc", prerequisiteSHAs: [], checkOutput: "", note: nil, at: Date(timeIntervalSince1970: 0))
        #expect(TaskPublisher.title(of: issue) == "Constraints file")
        #expect(TaskPublisher.description(of: issue, acceptance: accepted).contains("Closes #53"))
        #expect(TaskPublisher.title(of: jira) == "FE-1: Constraints file")
        #expect(!TaskPublisher.description(of: jira, acceptance: accepted).contains("Closes"))
    }

    @Test func anIssuesPromptBlockAsksForClosesInTheRequest() {
        let issue = JiraTicket(key: "#55", summary: "Opt-in Entire", description: "Details", issueType: nil, status: nil, url: "u",
                               source: .gitLab(project: "ai/agentflow"))
        #expect(AgentCommand.composePrompt(userText: "Plan first", ticket: issue, appendTicket: true) ==
                "Plan first\n\nGitLab issue #55: Opt-in Entire\n\nDetails\n\nPut `Closes #55` in the merge request’s description.")
    }
}
