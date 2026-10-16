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
        #expect(try await publisher.merge(12, at: GitLabPublishTests.head) == .merged(commit: GitLabPublishTests.mergeCommit))
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
        #expect(try await publisher.merge(88, at: GitHubPublishTests.head) == .merged(commit: GitHubPublishTests.mergeCommit))
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

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiting.append($0) } } }
    func open() { opened = true; waiting.forEach { $0.resume() }; waiting = [] }
}
