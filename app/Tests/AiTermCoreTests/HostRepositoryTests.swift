import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct HostRepositoryTests {
    let gitLab = GitLabConfig(hostURL: URL(string: "https://git.example.net")!, token: "tok")
    let gitHub = GitHubConfig(token: "ghp_tok")
    let gitLabRemote = ProviderDetector.detect(remoteUrl: "git@git.example.net:web/acme-web.git")
    let gitHubRemote = ProviderDetector.detect(remoteUrl: "git@github.com:octocat/hello.git")

    @Test(arguments: [CodeHost.gitHub, .gitLab])
    func requestByNumberAndNumericSearchShareOneRead(host: CodeHost) async throws {
        let number = host == .gitHub ? 88 : 12
        let payload = host == .gitHub ? GitHubPublishTests.pull() : GitLabPublishTests.status(detailed: "mergeable", pipeline: "success")
        let base = host == .gitHub ? GitHubPublishTests.api + "/pulls/" : Self.gitLabRequest.replacingOccurrences(of: "/12", with: "/")
        let stub = StubSession { request in
            request.url?.absoluteString == base + String(number) ? (200, Data(payload.utf8)) : (404, Data())
        }
        let repository = try CodeHosts.repository(for: host == .gitHub ? gitHubRemote : gitLabRemote,
                                                  gitLab: gitLab, gitHub: gitHub, session: stub.session)
        let found = try #require(try await repository.request(number: number))
        #expect(found.iid == number)
        #expect(stub.requests.count == 1)
        #expect(try await repository.mergeRequests(search: String(number)) == [found])
        #expect(stub.requests.count == 2)
        #expect(try await repository.request(number: 999) == nil)
        #expect(stub.requests.count == 3)
        #expect(try await repository.mergeRequests(search: "999") == [])
        #expect(stub.requests.count == 4)
        #expect(stub.requests.compactMap { $0.url?.absoluteString } == [base + String(number), base + String(number), base + "999", base + "999"])
        #expect(stub.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test(arguments: [CodeHost.gitHub, .gitLab], [200, 401, 403, 502])
    func aFailedRequestReadThrowsInsteadOfLookingAbsent(host: CodeHost, status: Int) async throws {
        let stub = StubSession { _ in (status, Data("{}".utf8)) }
        let repository = try CodeHosts.repository(for: host == .gitHub ? gitHubRemote : gitLabRemote,
                                                  gitLab: gitLab, gitHub: gitHub, session: stub.session)
        await #expect(throws: (any Error).self) { try await repository.request(number: 7) }
        await #expect(throws: (any Error).self) { try await repository.mergeRequests(search: "7") }
        #expect(stub.requests.count == 2)
    }

    @Test func aGitLabRemoteIsReadOnTheConfiguredGitLab() async throws {
        let stub = StubSession { _ in (200, Data("[]".utf8)) }
        let publisher = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await publisher.existingRequest(from: "feat/pluto-231-add-gift-card") == nil)
        #expect(stub.lastRequest?.url?.absoluteString.hasPrefix("https://git.example.net/api/v4/projects/web%2Facme-web/merge_requests?") == true)
    }

    @Test func aGitHubRemoteIsReadOnGitHub() async throws {
        let stub = StubSession { _ in (200, Data("[]".utf8)) }
        let publisher = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        #expect(try await publisher.existingRequest(from: "feat/pluto-231") == nil)
        #expect(stub.lastRequest?.url?.absoluteString.hasPrefix("https://api.github.com/repos/octocat/hello/pulls?") == true)
    }

    @Test func repositoryBindingUsesTheResolvedConnection() throws {
        #expect(try CodeHosts.connection(for: gitLabRemote, gitLab: gitLab, gitHub: nil) == .gitLab(gitLab, project: "web/acme-web"))
        #expect(try CodeHosts.connection(for: gitHubRemote, gitLab: gitLab, gitHub: gitHub) == .gitHub(gitHub, repo: "octocat/hello"))
    }

    // MARK: Each call is the host client's, on the project the remote names

    @Test func theProtectionAskedIsTheProjectsOnItsHost() async throws {
        // The project, whose namespace says whose rules also apply, then its rules: one page, then an empty one.
        let stub = StubSession { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/protected_branches") {
                return (200, Data((URLComponents(string: url)?.queryItems?.first { $0.name == "page" }?.value ?? "1") == "1"
                                  ? GitLabPublishTests.protected.utf8 : "[]".utf8))
            }
            if url.contains("/api/v4/groups/") || url.contains("/repository/branches/") { return (404, Data("{}".utf8)) }
            return (200, Data(GitLabPublishTests.project().utf8))
        }
        let publisher = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await publisher.protection(of: "release/1") == .protected("GitLab protects release/*"))
        #expect(try await publisher.protection(of: "feat/pluto-231") == .unprotected)
        // Everything asked is on the configured host, about this project or the group above it.
        let urls = stub.requests.compactMap { $0.url?.absoluteString }
        #expect(urls.allSatisfy { $0.hasPrefix("https://git.example.net/api/v4/projects/web%2Facme-web") || $0.hasPrefix("https://git.example.net/api/v4/groups/web/") })
        #expect(stub.requests.contains { $0.url?.absoluteString.contains("/protected_branches?") == true })
    }

    @Test func protectionThatCannotBeEstablishedThrowsOnBothHostsNeverAnswersUnprotected() async throws {
        let refusing = StubSession { _ in (403, Data()) }
        let onGitLab = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: refusing.session)
        // GitLab's first read, the project, fails as GitLab's own error; the later ones as ProtectionUnknown. Either way it throws.
        await #expect(throws: GitLabError.unauthorized) { _ = try await onGitLab.protection(of: "feat/x") }
        let onGitHub = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: refusing.session)
        await #expect(throws: ProtectionUnknown.self) { _ = try await onGitHub.protection(of: "feat/x") }
    }

    @Test func gitLabFindsTheOpenRequestFromTheSourceBranchAndMapsWhatItCannotTrust() async throws {
        let listed = "[" + GitLabPublishTests.status(detailed: "mergeable", pipeline: "success") + "]"
        let stub = StubSession { _ in (200, Data(listed.utf8)) }
        let publisher = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        let found = try await publisher.existingRequest(from: "feat/pluto-231-add-gift-card")
        #expect(found?.iid == 12)
        #expect(found?.targetBranch == "main", "the request carries where it points")
        let url = try #require(stub.lastRequest?.url)
        #expect(url.absoluteString.hasPrefix("https://git.example.net/api/v4/projects/web%2Facme-web/merge_requests?"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "source_branch" }?.value == "feat/pluto-231-add-gift-card")
        #expect(query.first { $0.name == "state" }?.value == "opened")
        #expect(stub.lastRequest?.httpMethod == "GET")

        // A fork's request of the same branch name is not the task's: none, not a wrong one.
        let fork = GitLabPublishTests.status(detailed: "mergeable", pipeline: "success")
            .replacingOccurrences(of: #""project_id":42"#, with: #""source_project_id":99,"target_project_id":42"#)
        let forked = StubSession { _ in (200, Data(("[" + fork + "]").utf8)) }
        let other = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: forked.session)
        #expect(try await other.existingRequest(from: "feat/pluto-231-add-gift-card") == nil)

        // An answer that cannot be read is an error, never "no request" (which would open a second).
        let garbled = StubSession { _ in (200, Data(#"[{"iid":"twelve"}]"#.utf8)) }
        let broken = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: garbled.session)
        await #expect(throws: GitLabError.decoding) { _ = try await broken.existingRequest(from: "feat/pluto-231-add-gift-card") }
    }

    @Test func gitHubFindsTheOpenPullRequestFromTheSourceBranchAndMapsWhatItCannotTrust() async throws {
        let stub = StubSession { _ in (200, Data(("[" + GitHubPublishTests.pull() + "]").utf8)) }
        let publisher = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        let found = try await publisher.existingRequest(from: "feat/pluto-231")
        #expect(found?.iid == 88)
        #expect(found?.targetBranch == "main")
        let url = try #require(stub.lastRequest?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/repos/octocat/hello/pulls")
        #expect(query.first { $0.name == "head" }?.value == "octocat:feat/pluto-231")
        #expect(query.first { $0.name == "state" }?.value == "open")

        let fork = GitHubPublishTests.pull(headRepo: "mallory/hello", headLabel: "mallory:feat/pluto-231")
        let forked = StubSession { _ in (200, Data(("[" + fork + "]").utf8)) }
        let other = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: forked.session)
        #expect(try await other.existingRequest(from: "feat/pluto-231") == nil)

        let garbled = StubSession { _ in (200, Data(#"[{"number":"eighty-eight"}]"#.utf8)) }
        let broken = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: garbled.session)
        await #expect(throws: GitHubError.decoding) { _ = try await broken.existingRequest(from: "feat/pluto-231") }
    }

    @Test func gitLabReadsAndMergesTheRequestByItsIid() async throws {
        let stub = StubSession { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/merge") { return (200, Data(GitLabPublishTests.status(state: "merged", detailed: "not_open", pipeline: "success").utf8)) }
            return (200, Data(GitLabPublishTests.status(detailed: "mergeable", pipeline: "success").utf8))
        }
        let publisher = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        let base = "https://git.example.net/api/v4/projects/web%2Facme-web/merge_requests/12"
        #expect(try await publisher.readiness(of: 12) == .ready(head: GitLabPublishTests.head))
        #expect(stub.lastRequest?.url?.absoluteString == base)
        #expect(try await publisher.merge(12, at: GitLabPublishTests.head) == .merged(commit: GitLabPublishTests.mergeCommit, head: GitLabPublishTests.head, target: "main"))
        #expect(stub.lastRequest?.httpMethod == "PUT")
        #expect(stub.lastRequest?.url?.absoluteString == base + "/merge")
    }

    @Test func gitHubReadsAndMergesThePullRequestByItsNumber() async throws {
        let stub = StubSession { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/check-runs") { return (200, Data(GitHubPublishTests.green.utf8)) }
            if path.hasSuffix("/status") { return (200, Data(GitHubPublishTests.statuses([]).utf8)) }
            if path.hasSuffix("/merge") { return (200, Data(#"{"sha":"\#(GitHubPublishTests.mergeCommit)","merged":true}"#.utf8)) }
            return (200, Data(GitHubPublishTests.pull().utf8))
        }
        let publisher = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        #expect(try await publisher.readiness(of: 88) == .ready(head: GitHubPublishTests.head))
        #expect(try await publisher.merge(88, at: GitHubPublishTests.head) == .merged(commit: GitHubPublishTests.mergeCommit, head: GitHubPublishTests.head))
        #expect(stub.lastRequest?.httpMethod == "PUT")
        #expect(stub.lastRequest?.url?.absoluteString == GitHubPublishTests.api + "/pulls/88/merge")
    }

    @Test func aRefusedMergeIsBlockedAndAFailureToAskThrowsOnBothHosts() async throws {
        let refusing = StubSession { _ in (405, Data()) }
        let onGitLab = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: refusing.session)
        #expect(try await onGitLab.merge(12, at: GitLabPublishTests.head) == .blocked("GitLab refused to merge it (HTTP 405)"))
        let onGitHub = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: refusing.session)
        #expect(try await onGitHub.merge(88, at: GitHubPublishTests.head) == .blocked("GitHub refused to merge it (HTTP 405)"))
        let down = StubSession { _ in (502, Data()) }
        let broken = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: down.session)
        await #expect(throws: GitLabError.badResponse(502)) { _ = try await broken.readiness(of: 12) }
    }
}

extension HostRepositoryTests {
    static let gitLabRequest = "https://git.example.net/api/v4/projects/web%2Facme-web/merge_requests/12"

    @Test func gitLabReadsEachThreadWithItsIdAndLastNote() async throws {
        let discussions = #"""
            [{"id":"d1","notes":[{"resolvable":true,"resolved":false,"body":"Rename this","author":{"username":"jan"},"system":false},
                                  {"resolvable":true,"resolved":false,"body":"changed this line","author":{"username":"aiterm"},"system":true}]},
             {"id":"d2","notes":[{"resolvable":false,"body":"Nice work","author":{"username":"mia"},"system":false}]},
             {"id":"d3","notes":[{"resolvable":true,"resolved":true,"body":"Fixed","author":{"username":"mia"},"system":false}]}]
            """#
        let stub = StubSession { request in Self.page(request) == 1 ? (200, Data(discussions.utf8)) : (200, Data("[]".utf8)) }
        let publisher = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await publisher.threads(of: 12) == [
            ReviewThread(id: "d1", resolved: false, lastAuthor: "jan", lastBody: "Rename this"),
            ReviewThread(id: "d3", resolved: true, lastAuthor: "mia", lastBody: "Fixed"),
        ])
        #expect(stub.lastRequest?.url?.absoluteString.hasPrefix(Self.gitLabRequest + "/discussions?") == true)
    }

    @Test func gitLabReadsWhoApproved() async throws {
        let stub = StubSession { _ in
            (200, Data(#"{"approved_by":[{"user":{"username":"jan","name":"Jan"}}]}"#.utf8))
        }
        let publisher = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await publisher.approvals(of: 12) == ["jan"])
    }

    @Test func gitHubReadsThreadsByTheirNodeId() async throws {
        let threads = #"""
            {"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
              {"id":"PRRT_1","isResolved":false,"comments":{"nodes":[{"body":"Rename this","author":{"login":"jan"}}]}},
              {"id":"PRRT_2","isResolved":true,"comments":{"nodes":[{"body":"Fixed","author":null}]}}]}}}}}
            """#
        let stub = StubSession { _ in (200, Data(threads.utf8)) }
        let publisher = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        #expect(try await publisher.threads(of: 88) == [
            ReviewThread(id: "PRRT_1", resolved: false, lastAuthor: "jan", lastBody: "Rename this"),
            ReviewThread(id: "PRRT_2", resolved: true, lastAuthor: nil, lastBody: "Fixed"),
        ])
    }

    @Test func gitHubReadsTheLatestApprovals() async throws {
        let stub = StubSession { request in
            if Self.page(request) > 1 { return (200, Data("[]".utf8)) }
            return (200, Data(#"""
                    [{"user":{"login":"jan"},"state":"CHANGES_REQUESTED"},{"user":{"login":"mia"},"state":"APPROVED"},
                     {"user":{"login":"jan"},"state":"APPROVED"},{"user":{"login":"mia"},"state":"COMMENTED"},
                     {"user":{"login":"lou"},"state":"APPROVED"},{"user":{"login":"lou"},"state":"DISMISSED"}]
                """#.utf8))
        }
        let publisher = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        #expect(try await publisher.approvals(of: 88) == ["jan", "mia"])
    }

    // MARK: The merge floor and the watcher require complete reads

    /// The `page` a request asked for; 1 when it named none.
    static func page(_ request: URLRequest) -> Int {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
    }

    /// One page of GitHub's review threads: `nodes` as JSON, and whether another follows.
    static func gitHubThreads(_ nodes: String, next: Bool) -> Data {
        Data(#"{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":\#(next),"endCursor":"c"},"nodes":[\#(nodes)]}}}}}"#.utf8)
    }

    @Test func gitHubThreadsPastTheCapAreNoAnswer() async throws {
        let stub = StubSession { request in
            let after = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["variables"] as? [String: Any])?["after"] as? String
            let next = (Int(after ?? "0") ?? 0) + 1
            return (200, Data(#"{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"\#(next)"},"nodes":[{"id":"PRRT_\#(next)","isResolved":true,"comments":{"nodes":[]}}]}}}}}"#.utf8))
        }
        let publisher = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        await #expect(throws: IncompleteRead.self) { _ = try await publisher.threads(of: 88) }
        #expect(stub.requests.count == GitHubClient.threadPagesRead, "every page up to the cap was read")
    }

    @Test func gitHubThreadsReadToTheLastPage() async throws {
        let stub = StubSession { request in
            let after = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["variables"] as? [String: Any])?["after"] as? String
            let index = Int(after ?? "0") ?? 0
            let node = #"{"id":"PRRT_\#(index)","isResolved":\#(index != 14),"comments":{"nodes":[]}}"#
            return (200, Data(#"{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":\#(index < 14),"endCursor":"\#(index + 1)"},"nodes":[\#(node)]}}}}}"#.utf8))
        }
        let publisher = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        let threads = try await publisher.threads(of: 88)
        #expect(threads.count == 15)
        #expect(threads.last == ReviewThread(id: "PRRT_14", resolved: false, lastAuthor: nil, lastBody: ""), "the open thread on page 15 is seen")
    }

    /// A cursor that does not move on would read the same page forever: no answer.
    @Test func aGitHubCursorThatRepeatsIsNoAnswer() async throws {
        let stub = StubSession { _ in (200, Self.gitHubThreads(#"{"id":"PRRT_1","isResolved":true,"comments":{"nodes":[]}}"#, next: true)) }
        let publisher = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        await #expect(throws: IncompleteRead.self) { _ = try await publisher.threads(of: 88) }
        #expect(stub.requests.count == 2)
    }

    @Test func aGitHubThreadThatDoesNotReadIsNoAnswer() async throws {
        let stub = StubSession { _ in
            (200, Self.gitHubThreads(#"{"id":"PRRT_1","isResolved":true,"comments":{"nodes":[]}},{"id":"PRRT_2","isResolved":"maybe"}"#, next: false))
        }
        let publisher = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        await #expect(throws: (any Error).self) { _ = try await publisher.threads(of: 88) }
    }

    @Test func gitLabThreadsPastTheCapAreNoAnswer() async throws {
        let full = "[" + Array(repeating: #"{"id":"d","notes":[{"resolvable":true,"resolved":true}]}"#, count: 100).joined(separator: ",") + "]"
        let stub = StubSession { _ in (200, Data(full.utf8)) }
        let publisher = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        await #expect(throws: IncompleteRead.self) { _ = try await publisher.threads(of: 12) }
        #expect(stub.requests.count == GitLabClient.threadPagesRead)
    }

    @Test func aGitLabDiscussionThatDoesNotReadIsNoAnswer() async throws {
        let stub = StubSession { request in
            Self.page(request) == 1 ? (200, Data(#"[{"id":"d1","notes":[{"resolvable":true,"resolved":true}]},{"id":"d2","notes":"unreadable"}]"#.utf8))
                                    : (200, Data("[]".utf8))
        }
        let publisher = try CodeHosts.repository(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        await #expect(throws: (any Error).self) { _ = try await publisher.threads(of: 12) }
    }

    @Test func gitHubApprovalsReadEveryPage() async throws {
        let first = "[" + (Array(repeating: #"{"user":{"login":"mia"},"state":"COMMENTED"}"#, count: 99)
                           + [#"{"user":{"login":"jan"},"state":"APPROVED"}"#]).joined(separator: ",") + "]"
        let stub = StubSession { request in
            switch Self.page(request) {
            case 1: return (200, Data(first.utf8))
            case 2: return (200, Data(#"[{"user":{"login":"jan"},"state":"CHANGES_REQUESTED"}]"#.utf8))
            default: return (200, Data("[]".utf8))
            }
        }
        let publisher = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        #expect(try await publisher.approvals(of: 88) == [], "jan's later review on page 2 takes the approval back")
        let endless = StubSession { _ in (200, Data(first.utf8)) }
        let capped = try CodeHosts.repository(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: endless.session)
        await #expect(throws: IncompleteRead.self) { _ = try await capped.approvals(of: 88) }
    }

}
