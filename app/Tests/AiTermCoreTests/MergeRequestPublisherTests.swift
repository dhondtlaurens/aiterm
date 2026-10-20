import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct MergeRequestPublisherTests {
    let gitLab = GitLabConfig(hostURL: URL(string: "https://git.example.net")!, token: "tok")
    let gitHub = GitHubConfig(token: "ghp_tok")
    let gitLabRemote = ProviderDetector.detect(remoteUrl: "git@git.example.net:web/acme-web.git")
    let gitHubRemote = ProviderDetector.detect(remoteUrl: "git@github.com:octocat/hello.git")

    @Test func aGitLabRemoteIsPublishedOnTheConfiguredGitLab() async throws {
        let stub = StubSession { _ in (201, Data(GitLabPublishTests.created.utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        let request = try await publisher.createRequest(from: "feat/pluto-231-add-gift-card", into: "main",
                                                        title: "PLUTO-231 Add gift card", description: "", draft: true)
        #expect(request.iid == 12)
        #expect(request.targetBranch == "main")
        #expect(stub.lastRequest?.url?.absoluteString == "https://git.example.net/api/v4/projects/web%2Facme-web/merge_requests")
    }

    @Test func aGitHubRemoteIsPublishedOnGitHub() async throws {
        let stub = StubSession { _ in (200, Data("[]".utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        #expect(try await publisher.existingRequest(from: "feat/pluto-231") == nil)
        #expect(stub.lastRequest?.url?.absoluteString.hasPrefix("https://api.github.com/repos/octocat/hello/pulls?") == true)
    }

    @Test func aHostThatIsNotConnectedOrAnotherGitLabIsRefused() {
        #expect(throws: MergeRequestSearch.Unavailable.notConnected(.gitLab)) {
            _ = try MergeRequestPublisher.publisher(for: self.gitLabRemote, gitLab: nil, gitHub: nil)
        }
        let elsewhere = ProviderDetector.detect(remoteUrl: "git@gitlab.other.org:web/acme-web.git")
        #expect(throws: MergeRequestSearch.Unavailable.otherGitLabHost(remote: "gitlab.other.org", configured: "git.example.net")) {
            _ = try MergeRequestPublisher.publisher(for: elsewhere, gitLab: self.gitLab, gitHub: nil)
        }
        #expect(throws: MergeRequestSearch.Unavailable.notConnected(.gitHub)) {
            _ = try MergeRequestPublisher.publisher(for: self.gitHubRemote, gitLab: self.gitLab, gitHub: nil)
        }
    }

    /// A self-hosted GitLab under a domain the detector cannot name is plain git: it is GitLab's to
    /// publish on only when it is the configured host, and never written to otherwise.
    @Test func aRemoteOnNoConfiguredHostIsUnavailableNotGuessed() {
        let selfHosted = ProviderDetector.detect(remoteUrl: "https://code.example.com/web/acme-web.git", repoPath: "/nonexistent")
        #expect(throws: MergeRequestSearch.Unavailable.otherGitLabHost(remote: "code.example.com", configured: "git.example.net")) {
            _ = try MergeRequestPublisher.publisher(for: selfHosted, gitLab: self.gitLab, gitHub: self.gitHub)
        }
        let local = ProviderDetector.detect(remoteUrl: "/srv/git/acme-web.git", repoPath: "/nonexistent")
        #expect(throws: MergeRequestSearch.Unavailable.otherGitLabHost(remote: nil, configured: "git.example.net")) {
            _ = try MergeRequestPublisher.publisher(for: local, gitLab: self.gitLab, gitHub: self.gitHub)
        }
    }

    @Test func searchAndPublishingAskTheSameConnection() throws {
        #expect(try MergeRequestSearch.connection(for: gitLabRemote, gitLab: gitLab, gitHub: nil) == .gitLab(gitLab, project: "web/acme-web"))
        #expect(try MergeRequestSearch.connection(for: gitHubRemote, gitLab: gitLab, gitHub: gitHub) == .gitHub(gitHub, repo: "octocat/hello"))
        let elsewhere = ProviderDetector.detect(remoteUrl: "git@gitlab.other.org:web/acme-web.git")
        #expect(throws: MergeRequestSearch.Unavailable.otherGitLabHost(remote: "gitlab.other.org", configured: "git.example.net")) {
            _ = try MergeRequestSearch.source(for: elsewhere, gitLab: self.gitLab, gitHub: nil)
        }
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
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await publisher.protection(of: "release/1") == .protected("GitLab protects release/*"))
        #expect(try await publisher.protection(of: "feat/pluto-231") == .unprotected)
        // Everything asked is on the configured host, about this project or the group above it.
        let urls = stub.requests.compactMap { $0.url?.absoluteString }
        #expect(urls.allSatisfy { $0.hasPrefix("https://git.example.net/api/v4/projects/web%2Facme-web") || $0.hasPrefix("https://git.example.net/api/v4/groups/web/") })
        #expect(stub.requests.contains { $0.url?.absoluteString.contains("/protected_branches?") == true })
    }

    @Test func protectionThatCannotBeEstablishedThrowsOnBothHostsNeverAnswersUnprotected() async throws {
        let refusing = StubSession { _ in (403, Data()) }
        let onGitLab = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: refusing.session)
        // GitLab's first read, the project, fails as GitLab's own error; the later ones as ProtectionUnknown. Either way it throws.
        await #expect(throws: GitLabError.unauthorized) { _ = try await onGitLab.protection(of: "feat/x") }
        let onGitHub = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: refusing.session)
        await #expect(throws: ProtectionUnknown.self) { _ = try await onGitHub.protection(of: "feat/x") }
    }

    private func sentBody(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Four strings of one type: each distinct, so a swap in an adapter changes what is sent.
    @Test func gitLabCreatesTheRequestWithEachArgumentInItsOwnField() async throws {
        let stub = StubSession { _ in (201, Data(GitLabPublishTests.created.utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        _ = try await publisher.createRequest(from: "feat/source", into: "release/target", title: "The title", description: "The description", draft: true)
        var fields = try sentBody(stub.lastRequest)
        #expect(fields["source_branch"] as? String == "feat/source")
        #expect(fields["target_branch"] as? String == "release/target")
        #expect(fields["title"] as? String == "Draft: The title", "GitLab's draft is its title prefix")
        #expect(fields["description"] as? String == "The description")
        _ = try await publisher.createRequest(from: "feat/source", into: "release/target", title: "The title", description: "The description", draft: false)
        fields = try sentBody(stub.lastRequest)
        #expect(fields["title"] as? String == "The title")
        #expect(stub.lastRequest?.httpMethod == "POST")
    }

    @Test func gitHubCreatesThePullRequestWithEachArgumentInItsOwnField() async throws {
        let stub = StubSession { _ in (201, Data(GitHubPublishTests.pull(draft: true, mergeable: "null", mergeableState: "unknown").utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        let request = try await publisher.createRequest(from: "feat/source", into: "release/target", title: "The title", description: "The description", draft: true)
        #expect(request.iid == 88)
        #expect(stub.lastRequest?.httpMethod == "POST")
        #expect(stub.lastRequest?.url?.absoluteString == GitHubPublishTests.api + "/pulls")
        var fields = try sentBody(stub.lastRequest)
        #expect(fields["head"] as? String == "feat/source")
        #expect(fields["base"] as? String == "release/target")
        #expect(fields["title"] as? String == "The title")
        #expect(fields["body"] as? String == "The description")
        #expect(fields["draft"] as? Bool == true)
        _ = try await publisher.createRequest(from: "feat/source", into: "release/target", title: "The title", description: "The description", draft: false)
        fields = try sentBody(stub.lastRequest)
        #expect(fields["draft"] as? Bool == false)
        #expect(fields["head"] as? String == "feat/source" && fields["base"] as? String == "release/target")
    }

    @Test func gitLabFindsTheOpenRequestFromTheSourceBranchAndMapsWhatItCannotTrust() async throws {
        let listed = "[" + GitLabPublishTests.status(detailed: "mergeable", pipeline: "success") + "]"
        let stub = StubSession { _ in (200, Data(listed.utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
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
        let other = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: forked.session)
        #expect(try await other.existingRequest(from: "feat/pluto-231-add-gift-card") == nil)

        // An answer that cannot be read is an error, never "no request" (which would open a second).
        let garbled = StubSession { _ in (200, Data(#"[{"iid":"twelve"}]"#.utf8)) }
        let broken = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: garbled.session)
        await #expect(throws: GitLabError.decoding) { _ = try await broken.existingRequest(from: "feat/pluto-231-add-gift-card") }
    }

    @Test func gitHubFindsTheOpenPullRequestFromTheSourceBranchAndMapsWhatItCannotTrust() async throws {
        let stub = StubSession { _ in (200, Data(("[" + GitHubPublishTests.pull() + "]").utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
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
        let other = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: forked.session)
        #expect(try await other.existingRequest(from: "feat/pluto-231") == nil)

        let garbled = StubSession { _ in (200, Data(#"[{"number":"eighty-eight"}]"#.utf8)) }
        let broken = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: garbled.session)
        await #expect(throws: GitHubError.decoding) { _ = try await broken.existingRequest(from: "feat/pluto-231") }
    }

    @Test func gitLabReadsMergesAndRetargetsTheRequestByItsIid() async throws {
        let stub = StubSession { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/merge") { return (200, Data(GitLabPublishTests.status(state: "merged", detailed: "not_open", pipeline: "success").utf8)) }
            return (200, Data(GitLabPublishTests.status(detailed: "mergeable", pipeline: "success").utf8))
        }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        let base = "https://git.example.net/api/v4/projects/web%2Facme-web/merge_requests/12"
        #expect(try await publisher.readiness(of: 12) == .ready(head: GitLabPublishTests.head))
        #expect(stub.lastRequest?.url?.absoluteString == base)
        #expect(try await publisher.merge(12, at: GitLabPublishTests.head) == .merged(commit: GitLabPublishTests.mergeCommit, head: GitLabPublishTests.head, target: "main"))
        #expect(stub.lastRequest?.httpMethod == "PUT")
        #expect(stub.lastRequest?.url?.absoluteString == base + "/merge")
        try await publisher.retarget(12, to: "main")
        #expect(stub.lastRequest?.httpMethod == "PUT")
        #expect(stub.lastRequest?.url?.absoluteString == base)
    }

    @Test func gitHubReadsMergesAndRetargetsThePullRequestByItsNumber() async throws {
        let stub = StubSession { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/check-runs") { return (200, Data(GitHubPublishTests.green.utf8)) }
            if path.hasSuffix("/status") { return (200, Data(GitHubPublishTests.statuses([]).utf8)) }
            if path.hasSuffix("/merge") { return (200, Data(#"{"sha":"\#(GitHubPublishTests.mergeCommit)","merged":true}"#.utf8)) }
            return (200, Data(GitHubPublishTests.pull().utf8))
        }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        #expect(try await publisher.readiness(of: 88) == .ready(head: GitHubPublishTests.head))
        #expect(try await publisher.merge(88, at: GitHubPublishTests.head) == .merged(commit: GitHubPublishTests.mergeCommit, head: GitHubPublishTests.head))
        #expect(stub.lastRequest?.httpMethod == "PUT")
        #expect(stub.lastRequest?.url?.absoluteString == GitHubPublishTests.api + "/pulls/88/merge")
        try await publisher.retarget(88, to: "main")
        #expect(stub.lastRequest?.httpMethod == "PATCH")
        #expect(stub.lastRequest?.url?.absoluteString == GitHubPublishTests.api + "/pulls/88")
    }

    @Test func aRefusedMergeIsBlockedAndAFailureToAskThrowsOnBothHosts() async throws {
        let refusing = StubSession { _ in (405, Data()) }
        let onGitLab = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: refusing.session)
        #expect(try await onGitLab.merge(12, at: GitLabPublishTests.head) == .blocked("GitLab refused to merge it (HTTP 405)"))
        let onGitHub = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: refusing.session)
        #expect(try await onGitHub.merge(88, at: GitHubPublishTests.head) == .blocked("GitHub refused to merge it (HTTP 405)"))
        let down = StubSession { _ in (502, Data()) }
        let broken = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: down.session)
        await #expect(throws: GitLabError.badResponse(502)) { _ = try await broken.readiness(of: 12) }
    }
}

/// The scripted host G8's tests rely on: deterministic, and every call in `log` in the order made.
@Suite struct FakeMergeHostTests {
    @Test func everyCallIsLoggedInOrder() async throws {
        let host = FakeMergeHost(.init(protected: ["main": "protected"]))
        #expect(try await host.protection(of: "main") == .protected("protected"))
        #expect(try await host.protection(of: "feat/a") == .unprotected)
        #expect(try await host.existingRequest(from: "feat/a") == nil)
        let request = try await host.createRequest(from: "feat/a", into: "main", title: "T", description: "", draft: true)
        #expect(request.targetBranch == "main" && request.draft && request.url == FakeMergeHost.url)
        _ = try await host.readiness(of: 12)
        _ = try await host.merge(12, at: "abc")
        try await host.retarget(12, to: "dev")
        #expect(host.log == ["protection main", "protection feat/a", "existing feat/a", "create feat/a → main draft",
                             "readiness 12", "merge 12 at abc", "retarget 12 → dev"])
        #expect(try await host.existingRequest(from: "feat/a")?.targetBranch == "dev", "a retarget changes the request it holds")
    }

    @Test func protectionThatFailsThrowsAndIsLogged() async {
        let host = FakeMergeHost(.init(protectionFails: true))
        await #expect(throws: ProtectionUnknown.self) { _ = try await host.protection(of: "feat/a") }
        #expect(host.log == ["protection feat/a"])
    }

    @Test func readinessIsAnsweredInOrderAndTheLastAnswerRepeats() async throws {
        let host = FakeMergeHost(.init(readiness: [.waiting("a"), .ready(head: "h"), .blocked("b")]))
        var answers: [MergeReadiness] = []
        for _ in 0..<5 { answers.append(try await host.readiness(of: 12)) }
        #expect(answers == [.waiting("a"), .ready(head: "h"), .blocked("b"), .blocked("b"), .blocked("b")])
    }

    @Test func aLostCreateReplyLeavesTheRequestOnTheHostForTheRepeatToFind() async throws {
        let host = FakeMergeHost(.init(loseCreateReply: true))
        await #expect(throws: URLError.self) {
            _ = try await host.createRequest(from: "feat/a", into: "main", title: "T", description: "", draft: false)
        }
        #expect(try await host.existingRequest(from: "feat/a")?.iid == 12)
        #expect(host.log == ["create feat/a → main", "existing feat/a"])
        // Lost once: the next create is answered.
        let again = try await host.createRequest(from: "feat/a", into: "main", title: "T", description: "", draft: false)
        #expect(again.iid == 12)
    }

    @Test func aCreateThatFailsLeavesNothingOnTheHost() async throws {
        let host = FakeMergeHost(.init(createFails: true))
        await #expect(throws: URLError.self) {
            _ = try await host.createRequest(from: "feat/a", into: "main", title: "T", description: "", draft: false)
        }
        #expect(try await host.existingRequest(from: "feat/a") == nil)
    }

    @Test func aCreateHeldBeforeItAnswersIsLoggedButHasOpenedNothingYet() async throws {
        let gate = Gate()
        let host = FakeMergeHost(.init(beforeCreate: { await gate.wait() }))
        let create = Task { try await host.createRequest(from: "feat/a", into: "main", title: "T", description: "", draft: false) }
        while host.log.isEmpty { await Task.yield() }
        #expect(host.log == ["create feat/a → main"])
        #expect(try await host.existingRequest(from: "feat/a") == nil)
        await gate.open()
        #expect(try await create.value.iid == 12)
        #expect(try await host.existingRequest(from: "feat/a")?.iid == 12)
    }
}

/// The Review slice's calls (spec §5), each on the client's own requests, through the publisher a remote names.
extension MergeRequestPublisherTests {
    static let gitLabRequest = "https://git.example.net/api/v4/projects/web%2Facme-web/merge_requests/12"

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func gitLabMarkReadyDropsTheDraftPrefix() async throws {
        let stub = StubSession { _ in (200, Data(GitLabPublishTests.created.utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        try await publisher.markReady(12)
        let put = try #require(stub.requests.last)
        #expect(put.httpMethod == "PUT")
        #expect(put.url?.absoluteString == Self.gitLabRequest)
        #expect(try body(put)["title"] as? String == "PLUTO-231 Add gift card")
        #expect(GitLabClient.readyTitle("[Draft] (draft) WIP: Fix it") == "Fix it")
    }

    @Test func gitLabMarkReadyLeavesAReadyRequestAlone() async throws {
        let ready = GitLabPublishTests.created.replacingOccurrences(of: "Draft: ", with: "").replacingOccurrences(of: "\"draft\":true", with: "\"draft\":false")
        let stub = StubSession { _ in (200, Data(ready.utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        try await publisher.markReady(12)
        #expect(stub.requests.map(\.httpMethod) == ["GET"])
    }

    @Test func gitLabAssignsReviewersByTheirIdsBesideTheOnesAsked() async throws {
        let stub = StubSession { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/api/v4/users?") { return (200, Data(#"[{"id":5,"username":"jan","name":"Jan"}]"#.utf8)) }
            if request.httpMethod == "GET" { return (200, Data(#"{"iid":12,"reviewers":[{"id":3,"username":"mia"}]}"#.utf8)) }
            return (200, Data(GitLabPublishTests.created.utf8))
        }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        try await publisher.assignReviewers(12, usernames: ["jan"])
        #expect(stub.requests.first?.url?.absoluteString == "https://git.example.net/api/v4/users?username=jan")
        let put = try #require(stub.requests.last)
        #expect(put.httpMethod == "PUT" && put.url?.absoluteString == Self.gitLabRequest)
        #expect(try body(put)["reviewer_ids"] as? [Int] == [3, 5])
    }

    @Test func gitLabRefusesAReviewerItDoesNotHave() async throws {
        let stub = StubSession { _ in (200, Data("[]".utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        await #expect(throws: GitLabError.noUser("nobody")) { try await publisher.assignReviewers(12, usernames: ["nobody"]) }
        #expect(stub.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func gitLabReadsEachThreadWithItsIdAndLastNote() async throws {
        let discussions = #"""
            [{"id":"d1","notes":[{"resolvable":true,"resolved":false,"body":"Rename this","author":{"username":"jan"},"system":false},
                                  {"resolvable":true,"resolved":false,"body":"changed this line","author":{"username":"aiterm"},"system":true}]},
             {"id":"d2","notes":[{"resolvable":false,"body":"Nice work","author":{"username":"mia"},"system":false}]},
             {"id":"d3","notes":[{"resolvable":true,"resolved":true,"body":"Fixed","author":{"username":"mia"},"system":false}]}]
            """#
        let stub = StubSession { request in Self.page(request) == 1 ? (200, Data(discussions.utf8)) : (200, Data("[]".utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await publisher.threads(of: 12) == [
            ReviewThread(id: "d1", resolved: false, lastAuthor: "jan", lastBody: "Rename this"),
            ReviewThread(id: "d3", resolved: true, lastAuthor: "mia", lastBody: "Fixed"),
        ])
        #expect(stub.lastRequest?.url?.absoluteString.hasPrefix(Self.gitLabRequest + "/discussions?") == true)
    }

    @Test func gitLabRepliesInTheDiscussion() async throws {
        let stub = StubSession { _ in (201, Data(#"{"id":77,"body":"Done"}"#.utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        try await publisher.reply(12, thread: "6a9c1750b37d513a43987b574953fceb50b03ce7", body: "Done in 4f2a91c.")
        let post = try #require(stub.lastRequest)
        #expect(post.httpMethod == "POST")
        #expect(post.url?.absoluteString == Self.gitLabRequest + "/discussions/6a9c1750b37d513a43987b574953fceb50b03ce7/notes")
        #expect(try body(post)["body"] as? String == "Done in 4f2a91c.")
    }

    @Test func gitLabFindsTheProjectsUsersAndWhoApproved() async throws {
        let stub = StubSession { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/approvals") { return (200, Data(#"{"approved_by":[{"user":{"username":"jan","name":"Jan"}}]}"#.utf8)) }
            return (200, Data(#"[{"id":5,"username":"jan","name":"Jan Peeters"},{"bad":true}]"#.utf8))
        }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        #expect(try await publisher.findUsers("jan") == [HostUser(username: "jan", name: "Jan Peeters")])
        #expect(stub.lastRequest?.url?.absoluteString.hasPrefix("https://git.example.net/api/v4/projects/web%2Facme-web/users?search=jan") == true)
        #expect(try await publisher.approvals(of: 12) == ["jan"])
    }

    @Test func gitHubAssignsReviewers() async throws {
        let stub = StubSession { _ in (201, Data(GitHubPublishTests.pull().utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        try await publisher.assignReviewers(88, usernames: ["jan", "mia"])
        let post = try #require(stub.lastRequest)
        #expect(post.httpMethod == "POST")
        #expect(post.url?.absoluteString == "https://api.github.com/repos/octocat/hello/pulls/88/requested_reviewers")
        #expect(try body(post)["reviewers"] as? [String] == ["jan", "mia"])
    }

    @Test func gitHubMarksReadyThroughGraphQL() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/graphql" { return (200, Data(#"{"data":{"markPullRequestReadyForReview":{"pullRequest":{"isDraft":false}}}}"#.utf8)) }
            return (200, Data(GitHubPublishTests.pull(draft: true).replacingOccurrences(of: #""id":1,"#, with: #""id":1,"node_id":"PR_kw88","#).utf8))
        }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        try await publisher.markReady(88)
        let mutation = try #require(stub.lastRequest)
        #expect(mutation.url?.absoluteString == "https://api.github.com/graphql")
        let sent = try body(mutation)
        #expect((sent["query"] as? String)?.contains("markPullRequestReadyForReview") == true)
        #expect((sent["variables"] as? [String: Any])?["id"] as? String == "PR_kw88")
    }

    @Test func gitHubLeavesAReadyPullRequestAloneAndSaysWhatGraphQLRefused() async throws {
        let ready = StubSession { _ in (200, Data(GitHubPublishTests.pull(draft: false).utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: ready.session)
        try await publisher.markReady(88)
        #expect(ready.requests.map(\.httpMethod) == ["GET"])
        let refusing = StubSession { _ in (200, Data(#"{"data":null,"errors":[{"type":"UNPROCESSABLE","message":"Thread is outdated"}]}"#.utf8)) }
        let onGitHub = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: refusing.session)
        await #expect(throws: GitHubError.refused("Thread is outdated")) { try await onGitHub.reply(88, thread: "PRRT_1", body: "Done") }
    }

    @Test func gitHubReadsThreadsAndRepliesByTheirNodeId() async throws {
        let threads = #"""
            {"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
              {"id":"PRRT_1","isResolved":false,"comments":{"nodes":[{"body":"Rename this","author":{"login":"jan"}}]}},
              {"id":"PRRT_2","isResolved":true,"comments":{"nodes":[{"body":"Fixed","author":null}]}}]}}}}}
            """#
        let stub = StubSession { request in
            let query = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["query"] as? String ?? ""
            if query.contains("addPullRequestReviewThreadReply") { return (200, Data(#"{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"C_1"}}}}"#.utf8)) }
            return (200, Data(threads.utf8))
        }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        #expect(try await publisher.threads(of: 88) == [
            ReviewThread(id: "PRRT_1", resolved: false, lastAuthor: "jan", lastBody: "Rename this"),
            ReviewThread(id: "PRRT_2", resolved: true, lastAuthor: nil, lastBody: "Fixed"),
        ])
        try await publisher.reply(88, thread: "PRRT_1", body: "Done in 4f2a91c.")
        let variables = try #require(try body(stub.lastRequest)["variables"] as? [String: Any])
        #expect(variables["thread"] as? String == "PRRT_1" && variables["body"] as? String == "Done in 4f2a91c.")
    }

    @Test func gitHubFindsAssigneesAndTheLatestApprovals() async throws {
        let stub = StubSession { request in
            if request.url?.path.hasSuffix("/reviews") == true {
                if Self.page(request) > 1 { return (200, Data("[]".utf8)) }
                return (200, Data(#"""
                    [{"user":{"login":"jan"},"state":"CHANGES_REQUESTED"},{"user":{"login":"mia"},"state":"APPROVED"},
                     {"user":{"login":"jan"},"state":"APPROVED"},{"user":{"login":"mia"},"state":"COMMENTED"},
                     {"user":{"login":"lou"},"state":"APPROVED"},{"user":{"login":"lou"},"state":"DISMISSED"}]
                    """#.utf8))
            }
            return (200, Data(#"[{"login":"jan-p"},{"login":"mia"},{"login":"JANSSENS"}]"#.utf8))
        }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        #expect(try await publisher.findUsers("@jan") == [HostUser(username: "jan-p", name: nil), HostUser(username: "JANSSENS", name: nil)])
        #expect(try await publisher.approvals(of: 88) == ["jan", "mia"])
    }

    // MARK: - Gate C: what the merge floor and the watcher decide on is read whole, or not at all

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
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
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
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        let threads = try await publisher.threads(of: 88)
        #expect(threads.count == 15)
        #expect(threads.last == ReviewThread(id: "PRRT_14", resolved: false, lastAuthor: nil, lastBody: ""), "the open thread on page 15 is seen")
    }

    /// A cursor that does not move on would read the same page forever: no answer.
    @Test func aGitHubCursorThatRepeatsIsNoAnswer() async throws {
        let stub = StubSession { _ in (200, Self.gitHubThreads(#"{"id":"PRRT_1","isResolved":true,"comments":{"nodes":[]}}"#, next: true)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        await #expect(throws: IncompleteRead.self) { _ = try await publisher.threads(of: 88) }
        #expect(stub.requests.count == 2)
    }

    @Test func aGitHubThreadThatDoesNotReadIsNoAnswer() async throws {
        let stub = StubSession { _ in
            (200, Self.gitHubThreads(#"{"id":"PRRT_1","isResolved":true,"comments":{"nodes":[]}},{"id":"PRRT_2","isResolved":"maybe"}"#, next: false))
        }
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        await #expect(throws: (any Error).self) { _ = try await publisher.threads(of: 88) }
    }

    @Test func gitLabThreadsPastTheCapAreNoAnswer() async throws {
        let full = "[" + Array(repeating: #"{"id":"d","notes":[{"resolvable":true,"resolved":true}]}"#, count: 100).joined(separator: ",") + "]"
        let stub = StubSession { _ in (200, Data(full.utf8)) }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
        await #expect(throws: IncompleteRead.self) { _ = try await publisher.threads(of: 12) }
        #expect(stub.requests.count == GitLabClient.threadPagesRead)
    }

    @Test func aGitLabDiscussionThatDoesNotReadIsNoAnswer() async throws {
        let stub = StubSession { request in
            Self.page(request) == 1 ? (200, Data(#"[{"id":"d1","notes":[{"resolvable":true,"resolved":true}]},{"id":"d2","notes":"unreadable"}]"#.utf8))
                                    : (200, Data("[]".utf8))
        }
        let publisher = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: stub.session)
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
        let publisher = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: stub.session)
        #expect(try await publisher.approvals(of: 88) == [], "jan's later review on page 2 takes the approval back")
        let endless = StubSession { _ in (200, Data(first.utf8)) }
        let capped = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: endless.session)
        await #expect(throws: IncompleteRead.self) { _ = try await capped.approvals(of: 88) }
    }

    /// Marking ready and assigning read the request first: what `beforeWrite` refuses after those reads is not written.
    @Test func aReviewWriteStopsWhenItsLastCheckRefusesAfterTheReads() async throws {
        struct Paused: Error {}
        let draft = StubSession { _ in
            (200, Data(GitHubPublishTests.pull(draft: true).replacingOccurrences(of: #""id":1,"#, with: #""id":1,"node_id":"PR_kw88","#).utf8))
        }
        let onGitHub = try MergeRequestPublisher.publisher(for: gitHubRemote, gitLab: nil, gitHub: gitHub, session: draft.session)
        await #expect(throws: Paused.self) { try await onGitHub.markReady(88, beforeWrite: { throw Paused() }) }
        #expect(draft.requests.map { $0.httpMethod ?? "" } == ["GET"])
        let lab = StubSession { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/users?") { return (200, Data(#"[{"id":5,"username":"jan"}]"#.utf8)) }
            return (200, Data(GitLabPublishTests.created.replacingOccurrences(of: #""title":"#, with: #""reviewers":[{"id":3}],"title":"#).utf8))
        }
        let onGitLab = try MergeRequestPublisher.publisher(for: gitLabRemote, gitLab: gitLab, gitHub: nil, session: lab.session)
        await #expect(throws: Paused.self) { try await onGitLab.assignReviewers(12, usernames: ["jan"], beforeWrite: { throw Paused() }) }
        #expect(lab.requests.allSatisfy { $0.httpMethod == "GET" })
        await #expect(throws: Paused.self) { try await onGitLab.markReady(12, beforeWrite: { throw Paused() }) }
        #expect(lab.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(onGitHub.repository == "github.com/octocat/hello" && onGitLab.repository == "git.example.net/web/acme-web")
    }
}

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiting.append($0) } } }
    func open() { opened = true; waiting.forEach { $0.resume() }; waiting = [] }
}
