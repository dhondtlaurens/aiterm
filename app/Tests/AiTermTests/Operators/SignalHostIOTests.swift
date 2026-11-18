import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalHostIOTests {
    @Test func thePrimaryRequestWinsOverAPreviousStagesWatch() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.tasks[0].mr = .init(iid: 2, title: "Current", url: "https://git.example/shop/web/-/merge_requests/2")
        world.state.updateSignalTask(id) { $0.current.item = .request(remote: "git@git.example:shop/web.git", number: 2); $0.watchedRequest = .init(remote: "git@git.example:shop/web.git", number: 1) }
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
    /// Without merge when ready, a watch reads the request and asks GitLab whether the Done query matches that one
    /// merge request: no approvals, threads, checks or local git.
    @Test func aGitLabDoneWatchAsksAboutItsOwnRequestWithoutChecksThreadsOrLocalGit() async throws {
        var world = SignalWorld(); let signal = world.signal(done: SignalTrigger(source: .gitLab, query: "reviewer:any")), id = world.workingTask(signal: signal)
        world.state.tasks[0].branch = "work"; world.state.tasks[0].mr = .init(iid: 7, title: "Work", url: "https://git.example/shop/web/-/merge_requests/7")
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            if request.url!.path == "/api/v4/user" { return (200, Data(#"{"username":"alex"}"#.utf8)) }
            if request.url!.path == "/api/graphql" {
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let variables = body?["variables"] as? [String: Any]
                #expect(variables?["fullPath"] as? String == "shop/web" && variables?["iids"] as? [String] == ["7"])
                #expect(variables?["reviewerWildcardId"] as? String == "ANY")
                return (200, Data(#"{"data":{"project":{"list":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"iid":"7"}]}}}}"#.utf8))
            }
            return (200, Data(#"{"iid":7,"title":"Work","source_branch":"work","target_branch":"main","web_url":"https://git.example/shop/web/-/merge_requests/7","state":"opened"}"#.utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let git = RecordingGitRunner(), io = SignalHostIO(workspace: h.workspace, git: git, connections: { links }); io.remote = { _, _ in "git@git.example:shop/web.git" }
        let snapshot = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await io.read(try #require(h.workspace.state.task(id: id))) }
        #expect(snapshot.facts.doneMatches && !snapshot.facts.hostReadComplete && !snapshot.canMerge)
        #expect(snapshot.reference == SignalRequestRef(remote: "git@git.example:shop/web.git", number: 7))
        #expect(stub.requests.count == 3, "the request, the account and the Done query: \(stub.requests.map { $0.url!.path })")
        #expect(git.calls.isEmpty)
    }
    /// A ticket's task before its merge request exists: a GitLab Done query does not match, and that is its baseline.
    @Test func aGitLabDoneQueryOnATaskWithoutAMergeRequestDoesNotMatch() async throws {
        var world = SignalWorld(); let signal = world.signal(done: SignalTrigger(source: .gitLab, query: "reviewer:any")), id = world.workingTask(signal: signal)
        world.state.tasks[0].branch = "work"
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            #expect(request.url!.path != "/api/graphql", "no merge request, nothing to ask")
            return (200, Data("[]".utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { links }); io.remote = { _, _ in "git@git.example:shop/web.git" }
        #expect(try await io.doneMatches(try #require(h.workspace.state.task(id: id))) == false)
    }
    /// A merge is done even when the Done query cannot be read: here a Jira Done query, a ticket key in the title and
    /// no Jira connection.
    @Test(arguments: [(false, false), (true, false), (false, true)])
    func aMergeBeforeTheFirstWatchIsFoundFromItsBranch(github: Bool, unreadableDone: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        if unreadableDone { world.state.tasks[0].title = "PAY-7 Safe retries" }
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
        let facts = try await io.read(try #require(h.workspace.state.task(id: id))).facts
        #expect(facts.merged && !facts.doneMatches, "merged is done whatever the Done query says, read or not")
    }
    /// A merge watch with a known number reads the merge request once, its approvals and its discussions, and nothing
    /// else: the request, its head, readiness, pipeline and reviewers all come from that one fetch.
    @Test func aGitLabMergeWatchReadsTheMergeRequestOnce() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true)
        let id = world.workingTask(signal: signal)
        world.state.tasks[0].branch = "work"; world.state.tasks[0].mr = .init(iid: 7, title: "Work", url: "https://git.example/shop/web/-/merge_requests/7")
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            let path = request.url!.path
            if path.hasSuffix("approvals") { return (200, Data(#"{"approved_by":[{"user":{"username":"alex"}}]}"#.utf8)) }
            if path.hasSuffix("discussions") { return (200, Data("[]".utf8)) }
            return (200, Data(#"{"iid":7,"title":"Work","source_branch":"work","target_branch":"main","web_url":"https://git.example/shop/web/-/merge_requests/7","state":"opened","sha":"head","head_pipeline":{"status":"success"},"detailed_merge_status":"mergeable","reviewers":[{"username":"reviewer"}]}"#.utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { links }); io.remote = { _, _ in "git@git.example:shop/web.git" }
        let snapshot = try await io.read(try #require(h.workspace.state.task(id: id)))
        #expect(snapshot.head == "head" && snapshot.hostReady && snapshot.greenChecks && snapshot.approvals)
        #expect(snapshot.facts.hostReadComplete && snapshot.facts.approved && snapshot.facts.threadsResolved)
        let paths = stub.requests.map { $0.url!.path }
        #expect(paths.filter { $0.hasSuffix("/merge_requests/7") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/merge_requests/7/approvals") }.count == 1)
        #expect(paths.allSatisfy { $0.hasSuffix("/merge_requests/7") || $0.hasSuffix("/approvals") || $0.hasSuffix("/discussions") }, "\(paths)")
    }
    /// On GitHub the same watch reads the pull once and never asks for its requested reviewers.
    @Test func aGitHubMergeWatchReadsThePullOnce() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true)
        let id = world.workingTask(signal: signal)
        world.state.updateProject(id: world.project.id) { $0.remoteUrl = "git@github.com:shop/web.git" }
        world.state.tasks[0].branch = "work"; world.state.tasks[0].mr = .init(iid: 7, title: "Work", url: "https://github.com/shop/web/pull/7")
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            let path = request.url!.path
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            if path.hasSuffix("/reviews") { return (200, Data((page == "1" ? #"[{"user":{"login":"alex"},"state":"APPROVED"}]"# : "[]").utf8)) }
            if path.hasSuffix("/check-runs") { return (200, Data(#"{"total_count":1,"check_runs":[{"name":"test","status":"completed","conclusion":"success"}]}"#.utf8)) }
            if path.hasSuffix("/status") { return (200, Data(#"{"total_count":0,"statuses":[]}"#.utf8)) }
            if path == "/graphql" { return (200, Data(#"{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}"#.utf8)) }
            return (200, Data(#"{"number":7,"title":"Work","state":"open","html_url":"https://github.com/shop/web/pull/7","head":{"ref":"work","sha":"head","label":"shop:work","repo":{"full_name":"shop/web"}},"base":{"ref":"main","repo":{"full_name":"shop/web"}},"requested_reviewers":[],"requested_teams":[{"slug":"ios"}],"mergeable":true,"mergeable_state":"clean"}"#.utf8))
        }
        let links = SignalConnections(gitHub: GitHubConfig(token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { links }); io.remote = { _, _ in "git@github.com:shop/web.git" }
        let snapshot = try await io.read(try #require(h.workspace.state.task(id: id)))
        #expect(snapshot.head == "head" && snapshot.hostReady && snapshot.greenChecks && snapshot.approvals)
        let paths = stub.requests.map { $0.url!.path }
        #expect(paths.filter { $0 == "/repos/shop/web/pulls/7" }.count == 1)
        #expect(!paths.contains { $0.contains("requested_reviewers") })
        #expect(paths.count == 6, "the pull, two pages of reviews, the check runs, the statuses and the threads: \(paths)")
    }
    /// A merged branch is deleted only at the head its status says was merged: the merge proof comes from one status
    /// read of the request.
    @Test func aMergedBranchLearnsItsMergedHeadFromTheStatus() async throws {
        var world = SignalWorld(); let signal = world.signal(then: .remove)
        world.state.signals[0].finish.deletesMergedBranch = true
        world.workingTask(signal: signal)
        world.state.tasks[0].branch = "work"; world.state.tasks[0].mr = .init(iid: 7, title: "Work", url: "https://git.example/shop/web/-/merge_requests/7")
        let task = world.state.tasks[0]; world.state.tasks.removeAll()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            let path = request.url!.path
            if path.hasSuffix("approvals") { return (200, Data(#"{"approved_by":[]}"#.utf8)) }
            if path.hasSuffix("/merge_requests/7") {
                return (200, Data(#"{"iid":7,"title":"Work","source_branch":"work","target_branch":"main","web_url":"https://git.example/shop/web/-/merge_requests/7","state":"merged","sha":"merged-head","merge_commit_sha":"merge"}"#.utf8))
            }
            return (200, Data(#"{"default_branch":"main"}"#.utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let git = RecordingGitRunner(), io = SignalHostIO(workspace: h.workspace, git: git, connections: { links })
        io.remote = { _, _ in "git@git.example:shop/web.git" }
        await io.deleteMergedBranch(of: task)
        #expect(git.calls.contains { $0.args == ["rev-parse", "--verify", "refs/heads/work"] }, "the branch is checked against the merged head")
        #expect(stub.requests.filter { $0.url!.path.hasSuffix("/merge_requests/7") }.count == 1)
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
    @Test func mergingRechecksTheLocalHeadAtTheNativeEffectBoundary() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true)
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
        world.state.signals[0].start = SignalTrigger(source: .gitLab, query: "reviewer:@me")
        world.state.signals[0].work.requestDescription = false
        let id = world.workingTask(signal: signal)
        world.state.tasks[0].branch = "feat/PAY-1-work"
        world.state.updateSignalTask(id) { $0.current.item = .request(remote: "git@git.example:shop/web.git", number: 7) }
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
    /// A Jira Done query reads only the task's own ticket, narrowed by the query, and never a code host.
    @Test func aJiraDoneQueryReadsOnlyItsTicketNarrowedByTheQuery() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let ticket = world.ticket().ticket.map(JiraRef.init)
        world.state.updateSignalItem(id) { $0.jira = ticket }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            #expect(request.url!.host == "jira.example" && body?["jql"] as? String == #"key = "PAY-1" AND (status = Done)"#)
            return (200, Data(#"{"issues":[{"key":"PAY-1","fields":{"summary":"Safe retries","status":{"name":"Done"}}}],"isLast":true}"#.utf8))
        }
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: { links })
        io.remote = { _, _ in Issue.record("A Jira Done query must not read a code-host remote."); return "" }
        let snapshot = try await io.read(try #require(h.workspace.state.task(id: id)))
        #expect(snapshot.facts.doneMatches && !snapshot.canMerge && snapshot.reference == nil)
        #expect(stub.requests.count == 1)
    }
    /// A Jira Done query without merge still reads when the project's code host fails: the request only says merged
    /// or closed, which stays unknown.
    @Test func aJiraDoneQueryIsReadWhenTheCodeHostFails() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        world.state.updateProject(id: world.project.id) { $0.remoteUrl = "git@git.example:shop/web.git" }
        world.state.tasks[0].branch = "work"
        let ticket = world.ticket().ticket.map(JiraRef.init)
        world.state.updateSignalItem(id) { $0.jira = ticket }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            guard request.url!.host == "jira.example" else { return (503, Data()) }
            return (200, Data(#"{"issues":[{"key":"PAY-1","fields":{"summary":"Safe retries","status":{"name":"Done"}}}],"isLast":true}"#.utf8))
        }
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "fake"),
                                      gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: RecordingGitRunner(), connections: { links }); io.remote = { _, _ in "git@git.example:shop/web.git" }
        let snapshot = try await io.read(try #require(h.workspace.state.task(id: id)))
        #expect(snapshot.facts.doneMatches && !snapshot.facts.merged && snapshot.reference == nil)
    }
    /// A ticket from another Jira site is not read on the connected one, whose ticket of the same key is unrelated.
    @Test func aJiraDoneQueryRefusesATicketFromAnotherSite() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let ticket = world.ticket().ticket.map(JiraRef.init)
        world.state.updateSignalItem(id) { $0.jira = ticket }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { _ in Issue.record("Nothing is read on another site."); return (500, Data()) }
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://other.example")!, email: "fake", token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: { links })
        await #expect(throws: ActionUnavailable.self) { _ = try await io.read(try #require(h.workspace.state.task(id: id))) }
    }
    /// A merge request's task has the ticket whose key its branch names; with none in its branch or title it does not
    /// match, and nothing is read.
    @Test(arguments: ["feat/PAY-7-retries", "work"]) func aMergeRequestTasksJiraDoneQueryUsesTheKeyInItsBranch(branch: String) async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        world.state.tasks[0].branch = branch
        world.state.updateSignalTask(id) { $0.current.item = .request(remote: "https://git.example/shop/web", number: 7) }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            #expect(body?["jql"] as? String == #"key = "PAY-7" AND (status = Done)"#)
            return (200, Data(#"{"issues":[],"isLast":true}"#.utf8))
        }
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: { links })
        #expect(try await io.doneMatches(try #require(h.workspace.state.task(id: id))) == false)
        #expect(stub.requests.count == (branch == "work" ? 0 : 1))
    }
    @Test func anOldRequestLinkCannotBeReadOrMergedInAChangedRepository() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
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
