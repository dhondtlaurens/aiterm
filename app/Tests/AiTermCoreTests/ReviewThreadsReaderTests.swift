import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// Which host a merge request's threads are asked of, and for which project — read from the
/// address the request was stored with, before anything is asked of either host.
@Suite struct ReviewThreadsReaderTests {
    let gitLab = GitLabConfig(hostURL: URL(string: "https://GitLab.example.net/")!, token: "gl")
    let connected = URL(string: "https://gitlab.example.net")!

    @Test func aPullRequestOnGitHubNamesItsRepository() {
        #expect(ReviewThreadsReader.target(of: "https://github.com/octocat/hello/pull/87", gitLab: nil) == .gitHub(repo: "octocat/hello"))
        #expect(ReviewThreadsReader.target(of: "https://github.com/octocat/hello/issues/87", gitLab: nil) == nil)
        #expect(ReviewThreadsReader.target(of: "https://github.com/octocat", gitLab: nil) == nil)
    }

    @Test func aMergeRequestOnTheConfiguredGitLabNamesItsProject() {
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net/web/shop/acme/-/merge_requests/4", gitLab: gitLab)
                == .gitLab(project: "web/shop/acme"))
    }

    /// Review focus 2: a GitLab served from a sub-path puts it before every project; it is not part
    /// of the project's path.
    @Test func aGitLabServedFromASubPathLeavesItOutOfTheProject() {
        let config = GitLabConfig(hostURL: URL(string: "https://example.com/gitlab")!, token: "gl")
        #expect(ReviewThreadsReader.target(of: "https://example.com/gitlab/web/acme/-/merge_requests/4", gitLab: config)
                == .gitLab(project: "web/acme"))
        #expect(ReviewThreadsReader.target(of: "https://example.com/web/acme/-/merge_requests/4", gitLab: config) == nil)
    }

    /// Review focus 2: a merge request on another GitLab would be another project's discussions,
    /// read with this host's token. It is not asked.
    @Test func aMergeRequestElsewhereIsNotAskedOfTheConfiguredGitLab() {
        #expect(ReviewThreadsReader.target(of: "https://gitlab.com/web/acme/-/merge_requests/4", gitLab: gitLab) == nil)
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net/web/acme/-/merge_requests/4", gitLab: nil) == nil)
        #expect(ReviewThreadsReader.target(of: "https://example/!87", gitLab: gitLab) == nil)
        #expect(ReviewThreadsReader.target(of: "not a url", gitLab: gitLab) == nil)
    }

    @Test func anAddressOnTheConfiguredGitLabWithoutAMergeRequestNamesNoProject() {
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net/web/acme", gitLab: gitLab) == nil)
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net/-/merge_requests/4", gitLab: gitLab) == nil)
    }

    /// Each host is asked with its own connection, for the threads and for the request itself, whose
    /// state says whether it merged: GitHub's pull request merged, GitLab's merge request still open.
    @Test func eachHostIsAskedWithItsOwnConnection() async throws {
        let pull = #"{"number":87,"title":"t","html_url":"https://github.com/octocat/hello/pull/87","state":"closed","merged":true,"head":{"ref":"f"},"base":{"ref":"main"}}"#
        let mergeRequest = #"{"iid":4,"title":"t","source_branch":"f","target_branch":"main","web_url":"https://gitlab.example.net/web/acme/-/merge_requests/4","state":"opened"}"#
        let stub = StubSession { request in
            let path = request.url?.path ?? ""
            if request.url?.host == "api.github.com" {
                return path == "/graphql"
                    ? (200, Data(#"{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"thread","isResolved":true}]}}}}}"#.utf8))
                    : (200, Data(pull.utf8))
            }
            if !path.hasSuffix("/discussions") { return (200, Data(mergeRequest.utf8)) }
            return (200, Data((request.url?.query?.contains("&page=1") == true
                ? #"[{"id":"thread","notes":[{"resolvable":true,"resolved":false}]}]"# : "[]").utf8))
        }
        let reader = ReviewThreadsReader(gitLab: GitLabConfig(hostURL: connected, token: "gl"), gitHub: GitHubConfig(token: "gh"),
                                         session: stub.session)
        #expect(try await reader.threads(of: MergeRequestRef(iid: 87, title: "t", url: "https://github.com/octocat/hello/pull/87"))
                == ReviewThreads(resolved: 1, total: 1, merged: true))
        #expect(try await reader.threads(of: MergeRequestRef(iid: 4, title: "t", url: "https://gitlab.example.net/web/acme/-/merge_requests/4"))
                == ReviewThreads(resolved: 0, total: 1, merged: false))
        // The threads and the request are asked side by side, so in either order.
        let asked = stub.requests.map { request in
            "\(request.url?.absoluteString ?? "") \(request.value(forHTTPHeaderField: "Authorization") ?? "-") \(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") ?? "-")"
        }
        #expect(asked.sorted() == [
            "https://api.github.com/graphql Bearer gh -",
            "https://api.github.com/repos/octocat/hello/pulls/87 Bearer gh -",
            "https://gitlab.example.net/api/v4/projects/web%2Facme/merge_requests/4 - gl",
            "https://gitlab.example.net/api/v4/projects/web%2Facme/merge_requests/4/discussions?per_page=100&page=1 - gl",
            "https://gitlab.example.net/api/v4/projects/web%2Facme/merge_requests/4/discussions?per_page=100&page=2 - gl",
        ])
    }

    /// Review focus 2: no connection, or a merge request on another GitLab, is no count and no request.
    @Test func aHostNotConnectedIsNotAsked() async throws {
        let stub = StubSession { _ in (200, Data("[]".utf8)) }
        let none = ReviewThreadsReader(gitLab: nil, gitHub: nil, session: stub.session)
        #expect(try await none.threads(of: MergeRequestRef(iid: 87, title: "t", url: "https://github.com/octocat/hello/pull/87")) == nil)
        #expect(try await none.threads(of: MergeRequestRef(iid: 4, title: "t", url: "https://gitlab.example.net/web/acme/-/merge_requests/4")) == nil)
        let gitLabOnly = ReviewThreadsReader(gitLab: GitLabConfig(hostURL: connected, token: "gl"), gitHub: nil, session: stub.session)
        #expect(try await gitLabOnly.threads(of: MergeRequestRef(iid: 4, title: "t", url: "https://gitlab.com/web/acme/-/merge_requests/4")) == nil)
        #expect(stub.requests.isEmpty)
    }

    /// A lookalike of github.com is not GitHub, and a github.com request is not asked of GitLab.
    @Test func aLookalikeGitHubHostOrAnUnconnectedGitHubIsNotAsked() async throws {
        let stub = StubSession { _ in (200, Data("[]".utf8)) }
        let both = ReviewThreadsReader(gitLab: GitLabConfig(hostURL: connected, token: "gl"), gitHub: GitHubConfig(token: "gh"), session: stub.session)
        #expect(try await both.threads(of: MergeRequestRef(iid: 1, title: "t", url: "https://github.com.evil.com/o/r/pull/1")) == nil)
        let gitLabOnly = ReviewThreadsReader(gitLab: GitLabConfig(hostURL: connected, token: "gl"), gitHub: nil, session: stub.session)
        #expect(try await gitLabOnly.threads(of: MergeRequestRef(iid: 87, title: "t", url: "https://github.com/octocat/hello/pull/87")) == nil)
        #expect(stub.requests.isEmpty)
    }
}
