import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTermTestSupport

/// Synthetic answers in the shape of GitLab CE 19.5.3's GraphQL merge request lists and GitHub's GraphQL
/// search. No account or live merge request is represented.
@Suite struct SignalQueryReadTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let gitLab = GitLabConfig(hostURL: URL(string: "https://gitlab.example.com")!, token: "test")
    let webshop = SignalRequestRef(remote: "https://gitlab.example.com/shop/webshop", number: 7)

    static func node(_ iid: String, status: String = "MERGEABLE", sourceProject: Int = 1) -> String {
        #"{"iid":"\#(iid)","title":"Review","webUrl":"https://gitlab.example.com/shop/webshop/-/merge_requests/\#(iid)","sourceBranch":"work","targetBranch":"main","description":"Closes SHOP-412","updatedAt":"2026-11-14T12:00:00Z","draft":false,"state":"opened","sourceProjectId":\#(sourceProject),"targetProjectId":1,"detailedMergeStatus":"\#(status)","author":{"username":"sam"},"assignees":{"nodes":[{"username":"alex"}]}}"#
    }

    static func page(_ nodes: [String], next: String? = nil, root: String = "currentUser") -> Data {
        let info = next.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false,"endCursor":null}"#
        return Data(#"{"data":{"\#(root)":{"list":{"pageInfo":\#(info),"nodes":[\#(nodes.joined(separator: ","))]}}}}"#.utf8)
    }

    static func body(_ request: URLRequest) -> (query: String, variables: [String: Any]) {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        return (body?["query"] as? String ?? "", body?["variables"] as? [String: Any] ?? [:])
    }

    // MARK: GitLab account

    @Test func gitLabListingPostsTheRoleRootAndFollowsTheCursor() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"alex"}"#.utf8)) }
            #expect(request.url?.path == "/api/graphql" && request.httpMethod == "POST")
            let (query, variables) = Self.body(request)
            #expect(query.contains("currentUser{list:reviewRequestedMergeRequests("))
            #expect(variables["reviewStates"] as? [String] == ["UNREVIEWED"] && variables["state"] as? String == "opened")
            #expect((variables["not"] as? [String: Any])?["assigneeUsernames"] as? [String] == ["alex"])
            guard let after = variables["after"] as? String else {
                return (200, Self.page([Self.node("7", status: "REQUESTED_CHANGES", sourceProject: 2)], next: "second"))
            }
            #expect(after == "second")
            return (200, Self.page([Self.node("8")]))
        }
        let account = GitLabAccount(config: gitLab, session: stub.session)
        let query = try GitLabQuery.start("reviewer:@me review-state:unreviewed -assignee:@me")
        let read = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.requests(matching: query) }
        #expect(read.complete && read.accountUser == "alex" && read.items.count == 2 && stub.requests.count == 3)
        let first = read.items[0]
        #expect(first.item.identity == ItemRef.mergeRequest(webshop).identity)
        #expect(first.mergeRequest?.sourceBranch == "work" && first.mergeRequest?.author == "sam" && first.mergeRequest?.forkHead == "project 2:work")
        #expect(first.changesRequested && first.assignees == ["alex"] && first.description == "Closes SHOP-412" && first.updated != nil)
        #expect(!read.items[1].changesRequested && read.items[1].mergeRequest?.forkHead == nil)
    }

    @Test func gitLabListingReadsEachProjectAndMergesByIdentity() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"alex"}"#.utf8)) }
            let path = Self.body(request).variables["projectPath"] as? String
            return (200, Self.page(path == "shop/api" ? [Self.node("7"), Self.node("9")] : [Self.node("7")]))
        }
        let account = GitLabAccount(config: gitLab, session: stub.session)
        let query = try GitLabQuery.start("author:@me project:shop/webshop,shop/api")
        let read = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.requests(matching: query) }
        #expect(read.complete && read.items.map(\.mergeRequest?.iid) == [7, 9])
        let paths = stub.requests.compactMap { Self.body($0).variables["projectPath"] as? String }
        #expect(Set(paths) == ["shop/webshop", "shop/api"])
    }

    @Test func gitLabErrorsBesideDataFailTheRead() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"alex"}"#.utf8)) }
            return (200, Data(#"{"data":{"currentUser":{"list":{"pageInfo":{"hasNextPage":false},"nodes":[]}}},"errors":[{"message":"Field 'x' doesn't exist"}]}"#.utf8))
        }
        let account = GitLabAccount(config: gitLab, session: stub.session)
        let query = try GitLabQuery.start("author:@me")
        await #expect(throws: GitLabError.refused("Field 'x' doesn't exist")) {
            try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.requests(matching: query) }
        }
    }

    @Test func gitLabUndecodableNodeLeavesTheListingIncomplete() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"alex"}"#.utf8)) }
            return (200, Self.page([Self.node("7"), #"{"iid":"8"}"#, "null"]))
        }
        let account = GitLabAccount(config: gitLab, session: stub.session)
        let query = try GitLabQuery.start("author:@me")
        let read = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.requests(matching: query) }
        #expect(!read.complete && read.cursor == nil && read.items.count == 1)
    }

    @Test func gitLabDoneReadAsksTheRoleRootForThatOneRequest() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"alex"}"#.utf8)) }
            let (query, variables) = Self.body(request)
            #expect(query.contains("currentUser{list:reviewRequestedMergeRequests(") && query.contains("nodes{iid}"))
            #expect(variables["iids"] as? [String] == ["7"] && variables["projectPath"] as? String == "shop/webshop")
            #expect(variables["state"] as? String == "all" && variables["reviewStates"] as? [String] == ["APPROVED"])
            return (200, Self.page([#"{"iid":"7"}"#]))
        }
        let account = GitLabAccount(config: gitLab, session: stub.session)
        let query = try GitLabQuery.done("reviewer:@me review-state:approved")
        let matched = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.matches(query, request: webshop, branch: "work") }
        #expect(matched)
    }

    @Test func gitLabDoneReadWithoutARoleAsksTheProject() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"alex"}"#.utf8)) }
            let (query, variables) = Self.body(request)
            #expect(query.contains("project(fullPath:$fullPath){list:mergeRequests("))
            #expect(variables["fullPath"] as? String == "shop/webshop" && variables["iids"] as? [String] == ["7"])
            return (200, Self.page([], root: "project"))
        }
        let account = GitLabAccount(config: gitLab, session: stub.session)
        let query = try GitLabQuery.done("state:merged")
        let matched = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.matches(query, request: webshop, branch: "work") }
        #expect(!matched)
    }

    /// A Done query's `threads:` tokens hold on that one request's threads, read after the listing found it.
    @Test(arguments: [("sam", false), ("alex", true)])
    func gitLabDoneReadAppliesItsThreadTokens(lastAuthor: String, matches: Bool) async throws {
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"alex"}"#.utf8)) }
            if request.url?.path.hasSuffix("/merge_requests/7/discussions") == true {
                let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
                guard page == "1" else { return (200, Data("[]".utf8)) }
                let note = #"{"resolvable":true,"resolved":false,"author":{"username":"\#(lastAuthor)"},"body":"See this"}"#
                return (200, Data(#"[{"id":"d1","notes":[\#(note)]}]"#.utf8))
            }
            return (200, Self.page([#"{"iid":"7"}"#], root: "project"))
        }
        let account = GitLabAccount(config: gitLab, session: stub.session)
        let query = try GitLabQuery.done("-threads:waiting-on-me")
        let matched = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.matches(query, request: webshop, branch: "work") }
        #expect(matched == matches)
    }

    @Test func gitLabDoneReadOutsideTheQueriesProjectsIsFalseWithoutAsking() async throws {
        let stub = StubSession { _ in Issue.record("Nothing should be asked"); return (500, Data()) }
        let account = GitLabAccount(config: gitLab, session: stub.session)
        let query = try GitLabQuery.done("project:shop/api state:merged")
        #expect(try await account.matches(query, request: webshop, branch: "work") == false)
    }

    @Test func gitLabDoneReadOfAProjectItCannotSeeThrows() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"alex"}"#.utf8)) }
            return (200, Data(#"{"data":{"project":null}}"#.utf8))
        }
        let account = GitLabAccount(config: gitLab, session: stub.session)
        let query = try GitLabQuery.done("state:merged")
        await #expect(throws: GitLabError.projectNotFound("shop/webshop")) {
            try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.matches(query, request: webshop, branch: "work") }
        }
    }

    // MARK: GitHub account

    static let pull = #"{"number":7,"title":"Review","url":"https://github.com/shop/webshop/pull/7","headRefName":"work","baseRefName":"main","isDraft":false,"body":"Details","author":{"login":"sam"},"repository":{"nameWithOwner":"shop/webshop"},"updatedAt":"2026-11-14T12:00:00Z"}"#

    @Test func gitHubSearchCarriesTheNormalisedQuery() async throws {
        let stub = StubSession { request in
            #expect(request.url?.path == "/graphql")
            #expect(Self.body(request).variables["query"] as? String == "is:pr is:open review-requested:@me")
            return (200, Data(#"{"data":{"search":{"issueCount":1,"pageInfo":{"hasNextPage":false},"nodes":[\#(Self.pull)]}}}"#.utf8))
        }
        let account = GitHubAccount(config: GitHubConfig(token: "test"), session: stub.session)
        let read = try await account.requests(matching: GitHubQuery.start("review-requested:@me threads:waiting-on-me"))
        #expect(read.complete && read.items.map(\.mergeRequest?.iid) == [7])
    }

    @Test func gitHubDoneReadAddsTheRepositoryAndBranch() async throws {
        let stub = StubSession { request in
            #expect(Self.body(request).variables["query"] as? String == "is:pr is:merged repo:shop/webshop head:work")
            return (200, Data(#"{"data":{"search":{"issueCount":1,"pageInfo":{"hasNextPage":false},"nodes":[\#(Self.pull)]}}}"#.utf8))
        }
        let account = GitHubAccount(config: GitHubConfig(token: "test"), session: stub.session)
        let query = try GitHubQuery.done("is:merged")
        #expect(try await account.matches(query, request: SignalRequestRef(remote: "https://github.com/shop/webshop", number: 7), branch: "work"))
        #expect(try await account.matches(query, request: SignalRequestRef(remote: "https://github.com/shop/webshop", number: 8), branch: "work") == false)
    }

    // MARK: Readers

    static func request(_ number: Int = 7, updated: Date) -> SignalItem {
        let request = MergeRequest(iid: number, title: "Review", sourceBranch: "work", targetBranch: "main", author: "sam", state: "opened",
                                   draft: false, url: "https://gitlab.example.com/shop/webshop/-/merge_requests/\(number)")
        return SignalItem(item: .request(remote: "https://gitlab.example.com/shop/webshop", number: number), title: "Review",
                          mergeRequest: request, updated: updated)
    }

    struct ThreadCase: Sendable, CustomTestStringConvertible {
        var query: String, threads: [ReviewThread], matches: Bool
        var testDescription: String { "\(query) \(matches)" }
    }

    static let threadCases: [ThreadCase] = [
        ThreadCase(query: "assignee:@me threads:waiting-on-me", threads: [ReviewThread(id: "a", resolved: false, lastAuthor: "sam", lastBody: "Why?")], matches: true),
        ThreadCase(query: "assignee:@me threads:waiting-on-me", threads: [ReviewThread(id: "a", resolved: false, lastAuthor: "Alex", lastBody: "Done")], matches: false),
        ThreadCase(query: "assignee:@me threads:waiting-on-me", threads: [ReviewThread(id: "a", resolved: false, lastAuthor: nil, lastBody: "?")], matches: false),
        ThreadCase(query: "assignee:@me threads:waiting-on-me", threads: [ReviewThread(id: "a", resolved: true, lastAuthor: "sam", lastBody: "Ok")], matches: false),
        ThreadCase(query: "assignee:@me -threads:waiting-on-me", threads: [ReviewThread(id: "a", resolved: false, lastAuthor: "alex", lastBody: "Done")], matches: true),
        ThreadCase(query: "assignee:@me threads:resolved", threads: [ReviewThread(id: "a", resolved: true, lastAuthor: "sam", lastBody: "Ok")], matches: true),
        ThreadCase(query: "assignee:@me threads:resolved", threads: [ReviewThread(id: "a", resolved: true, lastAuthor: "sam", lastBody: "Ok"),
                                                                     ReviewThread(id: "b", resolved: false, lastAuthor: "alex", lastBody: "Hm")], matches: false),
        ThreadCase(query: "assignee:@me -threads:resolved", threads: [ReviewThread(id: "b", resolved: false, lastAuthor: "alex", lastBody: "Hm")], matches: true),
        ThreadCase(query: "assignee:@me threads:resolved", threads: [], matches: true),
    ]

    @Test(arguments: threadCases) func threadTokensKeepOnlyTheRequestsTheyHoldFor(_ row: ThreadCase) async throws {
        let account = QueryAccountStub<GitLabQuery>(read: SignalRead(items: [Self.request(updated: now)], complete: true, accountUser: "alex"), threads: row.threads)
        let reader = GitLabQueryReader(query: try GitLabQuery.start(row.query), account: account, now: { now })
        let read = try await reader.poll(since: nil, full: false)
        #expect(read.items.count == (row.matches ? 1 : 0))
        #expect(read.complete && read.full && read.cursor == now)
    }

    @Test func unchangedRequestsReuseTheirThreadsAndANewUpdateReadsAgain() async throws {
        let waiting = [ReviewThread(id: "a", resolved: false, lastAuthor: "sam", lastBody: "Why?")]
        let account = QueryAccountStub<GitHubQuery>(read: SignalRead(items: [Self.request(updated: now)], complete: true), threads: waiting)
        let reader = GitHubQueryReader(query: try GitHubQuery.start("author:@me threads:waiting-on-me"), account: account, now: { now })
        #expect(try await reader.poll(since: nil, full: true).items.count == 1)
        #expect(try await reader.poll(since: nil, full: true).items.count == 1)
        #expect(await account.threadReads == 1)
        await account.reply(at: now.addingTimeInterval(60), threads: [ReviewThread(id: "a", resolved: false, lastAuthor: "alex", lastBody: "Done")])
        #expect(try await reader.poll(since: nil, full: true).items.isEmpty)
        #expect(await account.threadReads == 2)
    }

    @Test func aQueryWithoutThreadTokensReadsNoThreads() async throws {
        let account = QueryAccountStub<GitLabQuery>(read: SignalRead(items: [Self.request(updated: now)], complete: true, accountUser: "alex"), threads: [])
        let read = try await GitLabQueryReader(query: try GitLabQuery.start("author:@me"), account: account, now: { now }).poll(since: nil, full: false)
        #expect(read.items.count == 1 && read.cursor == now && read.full)
        #expect(await account.threadReads == 0)
    }

    @Test func anIncompleteListingStaysIncomplete() async throws {
        let account = QueryAccountStub<GitLabQuery>(read: SignalRead(items: [Self.request(updated: now)], complete: false, accountUser: "alex"), threads: [])
        let read = try await GitLabQueryReader(query: try GitLabQuery.start("author:@me threads:resolved"), account: account, now: { now }).poll(since: nil, full: true)
        #expect(!read.complete && read.cursor == nil)
        #expect(await account.threadReads == 0)
    }
}

private actor QueryAccountStub<Query: Sendable>: SignalQueryAccount {
    var read: SignalRead
    var threads: [ReviewThread]
    var threadReads = 0
    init(read: SignalRead, threads: [ReviewThread]) { self.read = read; self.threads = threads }
    func user() -> String { "alex" }
    func requests(matching query: Query) -> SignalRead { read }
    func matches(_ query: Query, request: SignalRequestRef, branch: String) -> Bool { false }
    func threads(of request: SignalRequestRef) -> [ReviewThread] { threadReads += 1; return threads }
    func reply(at date: Date, threads: [ReviewThread]) { read.items[0].updated = date; self.threads = threads }
}
