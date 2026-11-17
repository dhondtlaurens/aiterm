import Foundation
import Testing
@testable import AiTermCore

/// Which host serves a project's repository, decided from the remote
/// and the connections, before anything is asked of either host.
struct CodeHostsTests {
    let gitLab = GitLabConfig(hostURL: URL(string: "https://GitLab.example.net/")!, token: "t")
    let gitHub = GitHubConfig(token: "t")

    private func repository(_ remote: String?, gitLab: GitLabConfig?, gitHub: GitHubConfig?) throws(CodeHosts.Unavailable) -> any HostRepository {
        try CodeHosts.repository(for: ProviderDetector.detect(remoteUrl: remote, repoPath: "/nonexistent"), gitLab: gitLab, gitHub: gitHub)
    }

    @Test func aGitHubRemoteBindsItsRepositoryOnGitHub() throws {
        let repository = try #require(try repository("git@github.com:octocat/hello.git", gitLab: gitLab, gitHub: gitHub) as? GitHubClient)
        #expect(repository.repo == "octocat/hello")
        #expect(CodeHosts.host(for: ProviderDetector.detect(remoteUrl: "git@github.com:octocat/hello.git")) == .gitHub)
    }

    @Test func aGitLabRemoteOnTheConfiguredHostBindsItsProject() throws {
        let repository = try #require(try repository("git@gitlab.example.net:web/shop/acme.git", gitLab: gitLab, gitHub: gitHub) as? GitLabClient)
        #expect(repository.project == "web/shop/acme")
    }

    /// A self-hosted GitLab the detector can only call plain git is still GitLab's: only `.github`
    /// goes to GitHub.
    @Test func aPlainGitRemoteIsGitLabs() throws {
        let remote = ProviderDetector.detect(remoteUrl: "https://code.example.com/a/b.git", repoPath: "/nonexistent")
        #expect(remote.provider == .git)
        #expect(CodeHosts.host(for: remote) == .gitLab)
        let selfHosted = GitLabConfig(hostURL: URL(string: "https://code.example.com")!, token: "t")
        let repository = try #require(try repository("https://code.example.com/a/b.git", gitLab: selfHosted, gitHub: gitHub) as? GitLabClient)
        #expect(repository.project == "a/b")
    }

    @Test func eachRefusalSaysWhy() {
        #expect(throws: CodeHosts.Unavailable.notConnected(.gitHub)) {
            try repository("git@github.com:octocat/hello.git", gitLab: gitLab, gitHub: nil)
        }
        #expect(throws: CodeHosts.Unavailable.notConnected(.gitLab)) {
            try repository("git@gitlab.example.net:web/acme.git", gitLab: nil, gitHub: gitHub)
        }
        #expect(throws: CodeHosts.Unavailable.otherGitLabHost(remote: "gitlab.com", configured: "GitLab.example.net")) {
            try repository("git@gitlab.com:web/acme.git", gitLab: gitLab, gitHub: gitHub)
        }
        #expect(throws: CodeHosts.Unavailable.otherGitLabHost(remote: nil, configured: "GitLab.example.net")) {
            try repository(nil, gitLab: gitLab, gitHub: gitHub)
        }
        #expect(throws: CodeHosts.Unavailable.otherGitLabHost(remote: "code.example.com", configured: "GitLab.example.net")) {
            try repository("https://code.example.com/web/acme-web.git", gitLab: gitLab, gitHub: gitHub)
        }
        #expect(throws: CodeHosts.Unavailable.otherGitLabHost(remote: nil, configured: "GitLab.example.net")) {
            try repository("/srv/git/acme-web.git", gitLab: gitLab, gitHub: gitHub)
        }
        #expect(throws: CodeHosts.Unavailable.noRepositoryPath(.gitHub)) {
            try CodeHosts.repository(for: RemoteInfo(host: "github.com", path: "", provider: .github), gitLab: nil, gitHub: gitHub)
        }
        #expect(throws: CodeHosts.Unavailable.noRepositoryPath(.gitLab)) {
            try CodeHosts.repository(for: RemoteInfo(host: "gitlab.example.net", path: "", provider: .gitlab), gitLab: gitLab, gitHub: nil)
        }
    }
}
