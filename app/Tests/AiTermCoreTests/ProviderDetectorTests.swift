import Testing
import Foundation
@testable import AiTermCore

@Suite struct ProviderDetectorTests {
    @Test func testTable() {
        let cases: [(String?, Provider, String?)] = [
            ("git@git.example.net:web/acme-web.git", .gitlab, "git.example.net"),
            ("https://gitlab.example.com/group/sub/repo.git", .gitlab, "gitlab.example.com"),
            ("ssh://git@code.example.com:2222/a/b/c.git", .gitlab, "code.example.com"),
            ("git@gitlab.com:group/repo.git", .gitlab, "gitlab.com"),
            ("git@github.com:octocat/AiTerm.git", .github, "github.com"),
            ("https://github.com/octocat/hello.git", .github, "github.com"),
            ("ssh://git@ssh.github.com:443/octocat/hello.git", .github, "ssh.github.com"),
            ("https://code.example.com/a/b.git", .git, "code.example.com"),
            ("/Users/me/bare-repo.git", .git, nil),
            ("file:///Users/me/bare-repo.git", .git, nil),
        ]
        for (url, provider, host) in cases {
            let info = ProviderDetector.detect(remoteUrl: url, repoPath: "/nonexistent")
            #expect(info.provider == provider, "\(url ?? "nil")")
            #expect(info.host == host, "\(url ?? "nil")")
        }
    }

    @Test func testLocalRepoWithoutRemoteIsGitAndNonRepoIsNone() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        #expect(ProviderDetector.detect(remoteUrl: nil, repoPath: repo).provider == .git)
        try Data().write(to: URL(fileURLWithPath: repo + "/.gitlab-ci.yml"))
        #expect(ProviderDetector.detect(remoteUrl: "https://code.example.com/a/b.git", repoPath: repo).provider == .gitlab, "CI file marks a self-hosted GitLab")
        #expect(ProviderDetector.detect(remoteUrl: nil, repoPath: nil).provider == .none)
    }

    /// A GitHub repository that carries a `.gitlab-ci.yml` (a mirror, say) is still GitHub's.
    @Test func gitHubWinsOverTheGitLabCheckoutHints() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: repo + "/.gitlab-ci.yml"))
        #expect(ProviderDetector.detect(remoteUrl: "git@github.com:octocat/hello.git", repoPath: repo).provider == .github)
    }

    @Test func testPathIsNormalised() {
        #expect(ProviderDetector.detect(remoteUrl: "git@gitlab.com:g/r.git/", repoPath: nil).path == "g/r")
        #expect(ProviderDetector.detect(remoteUrl: "https://user:pw@gitlab.com/a/b.git", repoPath: nil).path == "a/b")
    }
}
