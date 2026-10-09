import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// Which host a merge request's threads are asked of, and for which project — read from the
/// address the request was stored with, before anything is asked of either host.
@Suite struct ReviewThreadsReaderTests {
    let gitLabHost = URL(string: "https://GitLab.example.net/")!
    let connected = URL(string: "https://gitlab.example.net")!

    @Test func aPullRequestOnGitHubNamesItsRepository() {
        #expect(ReviewThreadsReader.target(of: "https://github.com/octocat/hello/pull/87", gitLabHost: nil) == .gitHub(repo: "octocat/hello"))
        #expect(ReviewThreadsReader.target(of: "https://github.com/octocat/hello/issues/87", gitLabHost: nil) == nil)
        #expect(ReviewThreadsReader.target(of: "https://github.com/octocat", gitLabHost: nil) == nil)
    }

    @Test func aMergeRequestOnTheConfiguredGitLabNamesItsProject() {
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net/web/shop/acme/-/merge_requests/4", gitLabHost: gitLabHost)
                == .gitLab(project: "web/shop/acme"))
        // GitLab before 12.0 wrote the path without `/-/`.
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net/web/acme/merge_requests/4", gitLabHost: gitLabHost)
                == .gitLab(project: "web/acme"))
    }

    /// Review focus 2: a GitLab served from a sub-path puts it before every project; it is not part
    /// of the project's path.
    @Test func aGitLabServedFromASubPathLeavesItOutOfTheProject() {
        let host = URL(string: "https://example.com/gitlab")!
        #expect(ReviewThreadsReader.target(of: "https://example.com/gitlab/web/acme/-/merge_requests/4", gitLabHost: host)
                == .gitLab(project: "web/acme"))
        #expect(ReviewThreadsReader.target(of: "https://example.com/web/acme/-/merge_requests/4", gitLabHost: host) == nil)
    }

    /// Review focus 2: a merge request on another GitLab would be another project's discussions,
    /// read with this host's token. It is not asked.
    @Test func aMergeRequestElsewhereIsNotAskedOfTheConfiguredGitLab() {
        #expect(ReviewThreadsReader.target(of: "https://gitlab.com/web/acme/-/merge_requests/4", gitLabHost: gitLabHost) == nil)
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net/web/acme/-/merge_requests/4", gitLabHost: nil) == nil)
        #expect(ReviewThreadsReader.target(of: "https://example/!87", gitLabHost: gitLabHost) == nil)
        #expect(ReviewThreadsReader.target(of: "not a url", gitLabHost: gitLabHost) == nil)
    }

    /// Another GitLab instance on the same hostname but another port is another instance: this
    /// host's token is not sent to it. A port that is the scheme's own names nothing different.
    @Test func aMergeRequestOnAnotherPortIsNotAskedOfTheConfiguredGitLab() {
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net:8443/web/acme/-/merge_requests/4", gitLabHost: gitLabHost) == nil)
        let custom = URL(string: "https://gitlab.example.net:8443")!
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net/web/acme/-/merge_requests/4", gitLabHost: custom) == nil)
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net:8443/web/acme/-/merge_requests/4", gitLabHost: custom)
                == .gitLab(project: "web/acme"))
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net:443/web/acme/-/merge_requests/4", gitLabHost: gitLabHost)
                == .gitLab(project: "web/acme"))
        #expect(ReviewThreadsReader.target(of: "http://gitlab.example.net/web/acme/-/merge_requests/4", gitLabHost: gitLabHost)
                == .gitLab(project: "web/acme"))
    }

    @Test func anAddressOnTheConfiguredGitLabWithoutAMergeRequestNamesNoProject() {
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net/web/acme", gitLabHost: gitLabHost) == nil)
        #expect(ReviewThreadsReader.target(of: "https://gitlab.example.net/-/merge_requests/4", gitLabHost: gitLabHost) == nil)
    }

    @Test func eachHostIsAskedWithItsOwnConnection() async throws {
        let stub = StubSession { request in
            request.url?.host == "api.github.com"
                ? (200, Data(#"{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true}]}}}}}"#.utf8))
                : (200, Data(#"[{"notes":[{"resolvable":true,"resolved":false}]}]"#.utf8))
        }
        let reader = ReviewThreadsReader(gitLab: GitLabConfig(hostURL: connected, token: "gl"), gitHub: GitHubConfig(token: "gh"),
                                         session: stub.session)
        #expect(try await reader.threads(of: MergeRequestRef(iid: 87, title: "t", url: "https://github.com/octocat/hello/pull/87"))
                == ReviewThreads(resolved: 1, total: 1))
        #expect(try await reader.threads(of: MergeRequestRef(iid: 4, title: "t", url: "https://gitlab.example.net/web/acme/-/merge_requests/4"))
                == ReviewThreads(resolved: 0, total: 1))
        #expect(stub.requests.map { $0.url?.absoluteString } == [
            "https://api.github.com/graphql",
            "https://gitlab.example.net/api/v4/projects/web%2Facme/merge_requests/4/discussions?per_page=100&page=1",
        ])
        #expect(stub.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer gh", nil])
        #expect(stub.requests.map { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") } == [nil, "gl"])
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
