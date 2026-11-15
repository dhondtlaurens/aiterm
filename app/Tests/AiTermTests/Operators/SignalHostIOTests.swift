import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalHostIOTests {
    @Test func thePrimaryRequestWinsOverAPreviousStagesWatch() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.tasks[0].mr = .init(iid: 2, title: "Current", url: "https://git.example/shop/web/-/merge_requests/2")
        world.state.updateSignalTask(id) { $0.item = .request(remote: "git@git.example:shop/web.git", number: 2); $0.watchedRequest = .init(remote: "git@git.example:shop/web.git", number: 1) }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            let number = request.url!.lastPathComponent == "2" ? 2 : 1
            let text = number == 2 ? "Current description" : "Previous description"
            return (200, Data("{\"iid\":\(number),\"title\":\"Request\",\"source_branch\":\"work\",\"target_branch\":\"main\",\"web_url\":\"https://git.example/shop/web/-/merge_requests/\(number)\",\"description\":\"\(text)\",\"state\":\"opened\"}".utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { links }); io.remote = { _, _ in "git@git.example:shop/web.git" }
        #expect(try await io.details(try #require(h.workspace.state.task(id: id)))["requestDescription"] == "Current description")
    }
    @Test func aReviewerOnlyWatchReadsItsConditionWithoutChecksThreadsOrLocalGit() async throws {
        var world = SignalWorld(); let signal = world.signal(done: .hasReviewer), id = world.workingTask(signal: signal)
        world.state.tasks[0].branch = "work"; world.state.tasks[0].mr = .init(iid: 7, title: "Work", url: "https://git.example/shop/web/-/merge_requests/7")
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            if request.url!.path.hasSuffix("approvals") { return (200, Data(#"{"approved_by":[]}"#.utf8)) }
            if request.url!.path.hasSuffix("discussions") { return (200, Data("[]".utf8)) }
            return (200, Data(#"{"iid":7,"title":"Work","source_branch":"work","target_branch":"main","web_url":"https://git.example/shop/web/-/merge_requests/7","state":"opened","sha":"head","head_pipeline":{"status":"success"},"detailed_merge_status":"mergeable","reviewers":[{"username":"reviewer"}]}"#.utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let git = RecordingGitRunner(), io = SignalHostIO(workspace: h.workspace, git: git, connections: { links }); io.remote = { _, _ in "git@git.example:shop/web.git" }
        #expect(try await io.read(try #require(h.workspace.state.task(id: id))).facts.hasReviewer)
        #expect(stub.requests.count == 2 && git.calls.isEmpty)
    }
    @Test(arguments: [false, true]) func aMergeBeforeTheFirstWatchIsFoundFromItsBranch(github: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(done: .merged), id = world.workingTask(signal: signal)
        let remote = github ? "git@github.com:shop/web.git" : "git@git.example:shop/web.git"
        world.state.updateProject(id: world.project.id) { $0.remoteUrl = remote }
        world.state.tasks[0].branch = "work"
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let direct = request.url!.path.hasSuffix("/pulls/7")
            guard direct || query.contains(where: { $0.name == "state" && $0.value == "all" }) else { return (200, Data("[]".utf8)) }
            let body = github
                ? #"[{"number":7,"title":"Merged","state":"closed","merged":true,"html_url":"https://github.com/shop/web/pull/7","head":{"ref":"work","sha":"head","label":"shop:work","repo":{"full_name":"shop/web"}},"base":{"ref":"main","repo":{"full_name":"shop/web"}}}]"#
                : #"[{"iid":7,"title":"Merged","source_branch":"work","target_branch":"main","web_url":"https://git.example/shop/web/-/merge_requests/7","state":"merged","source_project_id":1,"target_project_id":1}]"#
            return (200, Data((direct ? String(body.dropFirst().dropLast()) : body).utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), gitHub: GitHubConfig(token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { links }); io.remote = { _, _ in remote }
        #expect(try await io.read(try #require(h.workspace.state.task(id: id))).facts.merged)
    }
    @Test func repeatedStatusDetailsReuseTheHostReadButAChangedAuthorityDoesNot() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.tasks[0].jira = world.ticket().ticket.map(JiraRef.init)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { _ in (200, Data(#"{"issues":[{"key":"PAY-1","fields":{"summary":"Retries","description":"Details"}}],"isLast":true}"#.utf8)) }
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { links })
        let task = try #require(h.workspace.state.task(id: id))
        _ = try await io.details(task); _ = try await io.details(task)
        #expect(stub.requests.count == 1)
        h.workspace.mutate { $0.updateSignalTask(id) { $0.ownership += 1 } }
        _ = try await io.details(try #require(h.workspace.state.task(id: id)))
        #expect(stub.requests.count == 2)
    }
    @Test func aStatusReadHasItsOwnBudgetAndNeverCachesATimedOutAnswer() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.tasks[0].jira = world.ticket().ticket.map(JiraRef.init)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return (200, Data(#"{"issues":[],"isLast":true}"#.utf8))
        }
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { links }); io.hostTimeout = .milliseconds(10)
        await #expect(throws: (any Error).self) { try await io.details(try #require(h.workspace.state.task(id: id))) }
    }
    @Test func mergingRechecksTheLocalHeadAtTheNativeEffectBoundary() async throws {
        var world = SignalWorld(); let signal = world.signal(done: .approved)
        world.state.signals[0].finish.mergesWhenReady = true
        let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { _ in (200, Data(#"{"state":"merged"}"#.utf8)) }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { links })
        io.remote = { _, _ in "git@git.example:shop/web.git" }
        var facts = DoneCheck.Facts(); facts.hostReadComplete = true; facts.threadsResolved = true
        let snapshot = RequestWatch.Snapshot(reference: SignalRequestRef(remote: "git@git.example:shop/web.git", number: 7),
            facts: facts, head: "accepted-head", localHead: "accepted-head", approvals: true, greenChecks: true)
        await #expect(throws: (any Error).self) { try await io.merge(try #require(h.workspace.state.task(id: id)), snapshot: snapshot) }
        #expect(stub.requests.isEmpty, "An unknown or changed local head cannot send a merge request.")
    }
    @Test func aTicketSignalFindsTheRelatedRequestDescriptionFromItsBranch() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.tasks[0].branch = "feat/PAY-1"
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            #expect(request.url!.path.contains("merge_requests"))
            return (200, Data(#"[{"iid":7,"title":"DO NOT COPY THIS TITLE","source_branch":"feat/PAY-1","target_branch":"main","web_url":"https://git.example/shop/web/-/merge_requests/7","description":"Only the request description.","state":"opened"}]"#.utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: { links })
        io.remote = { _, _ in "git@git.example:shop/web.git" }
        let prompt = try await io.additionalContext(try #require(h.workspace.state.task(id: id)))
        #expect(prompt.contains("Only the request description."))
        #expect(!prompt.contains("DO NOT COPY THIS TITLE") && !prompt.contains("PAY-1"))
    }
    @Test func aRequestSignalResolvesItsLinkedJiraDescriptionWithoutAddingTheKeyOrTitle() async throws {
        var world = SignalWorld(); let signal = world.signal()
        world.state.signals[0].source = .gitLab(RequestConditions(event: .reviewRequested))
        world.state.signals[0].work.requestDescription = false
        let id = world.workingTask(signal: signal)
        world.state.tasks[0].branch = "feat/PAY-1-work"
        world.state.updateSignalTask(id) { $0.item = .request(remote: "git@git.example:shop/web.git", number: 7) }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            #expect(request.url!.host == "jira.example")
            return (200, Data(#"{"issues":[{"key":"PAY-1","fields":{"summary":"DO NOT COPY THIS TITLE","description":"Only the ticket description.","status":{"name":"Open"}}}],"isLast":true}"#.utf8))
        }
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: { links })
        let prompt = try await io.additionalContext(try #require(h.workspace.state.task(id: id)))
        #expect(prompt.contains("Only the ticket description."))
        #expect(!prompt.contains("DO NOT COPY THIS TITLE") && !prompt.contains("PAY-1"))
    }
    @Test func ticketStatusNeedsOnlyItsJiraReadAndNeverRequiresARequest() async throws {
        var world = SignalWorld(); let signal = world.signal(done: .ticketStatus("Done")); let id = world.workingTask(signal: signal)
        let ticket = world.ticket().ticket.map(JiraRef.init)
        world.state.updateSignalItem(id) { $0.jira = ticket }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            #expect(request.url!.host == "jira.example" && request.httpMethod == "POST")
            return (200, Data(#"{"issues":[{"key":"PAY-1","fields":{"summary":"Safe retries","status":{"name":"Done"}}}],"isLast":true}"#.utf8))
        }
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: { links })
        io.remote = { _, _ in Issue.record("A ticket status must not read a code-host remote."); return "" }
        let snapshot = try await io.read(try #require(h.workspace.state.task(id: id)))
        #expect(snapshot.facts.ticketReadComplete && snapshot.facts.ticketStatus == "Done")
        #expect(!snapshot.canMerge && snapshot.reference == nil)
        #expect(stub.requests.count == 1)
    }
    @Test func operatorJudgmentSpendsNoSourceRead() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: {
            Issue.record("A judgment-only stage needs no source read."); return SignalConnections()
        })
        let snapshot = try await io.read(try #require(h.workspace.state.task(id: id)))
        #expect(!snapshot.canMerge && !snapshot.facts.operatorJudged)
    }
    @Test func anOldRequestLinkCannotBeReadOrMergedInAChangedRepository() async throws {
        var world = SignalWorld(); let signal = world.signal(done: .hasReviewer); let id = world.workingTask(signal: signal)
        world.state.updateSignalItem(id) {
            $0.mr = MergeRequestRef(iid: 7, title: "Old request", url: "https://git.example/other/web/-/merge_requests/7")
        }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { _ in
            Issue.record("A request bound to another repository must be refused before any host read.")
            return (404, Data())
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: { links })
        io.remote = { _, _ in "git@git.example:shop/web.git" }
        await #expect(throws: (any Error).self) { try await io.read(try #require(h.workspace.state.task(id: id))) }
        #expect(stub.requests.isEmpty)
    }
}
