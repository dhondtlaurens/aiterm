import Foundation
import Testing
@testable import AiTermCore

@Suite struct ReleaseFeedTests {
    @Test func parsesAGitHubFeed() {
        #expect(ReleaseFeed("github:octocat/hello") == .gitHub(owner: "octocat", repo: "hello"))
        #expect(ReleaseFeed("github:octo-cat/hello.world.git") == .gitHub(owner: "octo-cat", repo: "hello.world"))
    }

    @Test func parsesAGitLabFeed() {
        #expect(ReleaseFeed("gitlab:https://git.example.net/ai/aiterm")
                == .gitLab(host: URL(string: "https://git.example.net")!, project: "ai/aiterm"))
    }

    /// Review focus 2: a typo in the shipped feed would silently stop updates for everyone.
    @Test func theShippedFeedIsAiTermsGitHubRepository() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AiTerm/Resources/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist))
        let feed = try #require(info["AiTermUpdateFeed"] as? String)
        #expect(ReleaseFeed(feed) == .gitHub(owner: "dhondtlaurens", repo: "aiterm"))
    }

    /// Review focus 4: the update check is anonymous, whatever Settings holds.
    @Test func aGitHubSourceNeedsNoToken() throws {
        let secrets = MemorySecretStore(), defaults = ScratchDefaults.make()
        secrets.set("github.token", "ghp_secret")
        let source = try #require(try ReleaseFeed("github:octocat/hello")!.source(secrets: secrets, defaults: defaults) as? GitHubReleaseSource)
        #expect(source.owner == "octocat" && source.repo == "hello")
        #expect(throws: Never.self) { _ = try ReleaseFeed("github:octocat/hello")!.source(secrets: MemorySecretStore(), defaults: defaults) }
    }

    /// Review focus 5: a pasted URL with a subgroup, `.git` and a trailing slash still names the project.
    @Test func toleratesSubgroupsGitSuffixAndSlashes() {
        #expect(ReleaseFeed("gitlab:https://git.example.net:8443/a/b/c.git/")
                == .gitLab(host: URL(string: "https://git.example.net:8443")!, project: "a/b/c"))
    }

    @Test func rejectsWhatItCannotUse() {
        for bad in ["", "gitlab:", "gitlab:https://git.example.net", "gitlab:https://git.example.net/solo",
                    "https://git.example.net/ai/aiterm", "gitlab:not a url/x/y",
                    "github:", "github:owner", "github:owner/", "github:/repo", "github:a/b/c", "github:own er/repo",
                    "github:https://github.com/a/b"] {
            #expect(ReleaseFeed(bad) == nil, "\(bad)")
        }
    }

    /// The token as Settings saves it: the host in defaults, the secret in the store.
    func settings(host: String? = "https://git.example.net", token: String? = "tok\n") -> (MemorySecretStore, UserDefaults) {
        let secrets = MemorySecretStore(), defaults = ScratchDefaults.make()
        if let token { secrets.set("gitlab.token", token) }
        if let host { defaults.set(host, forKey: "gitlab.host") }
        return (secrets, defaults)
    }

    @Test func sourceNeedsAToken() {
        let feed = ReleaseFeed("gitlab:https://git.example.net/ai/aiterm")!
        let (none, noneDefaults) = settings(token: nil)
        #expect(throws: UpdateError.noToken) { _ = try feed.source(secrets: none, defaults: noneDefaults) }
        let (blank, blankDefaults) = settings(token: "  \n")
        #expect(throws: UpdateError.noToken) { _ = try feed.source(secrets: blank, defaults: blankDefaults) }
    }

    @Test func sourceUsesTheFeedHostAndTheSettingsToken() throws {
        let (secrets, defaults) = settings(host: "https://Git.Example.NET./")
        let source = try #require(try ReleaseFeed("gitlab:https://git.example.net/ai/aiterm")!.source(secrets: secrets, defaults: defaults) as? GitLabReleaseSource)
        #expect(source.host == URL(string: "https://git.example.net")!)
        #expect(source.project == "ai/aiterm")
        #expect(source.token == "tok")
    }

    /// Review finding: the feed's host comes from the build, the token from whatever GitLab the
    /// user set up for reviews. A token minted for one server is never offered to another.
    @Test func settingsTokenForAnotherHostIsRefused() {
        let feed = ReleaseFeed("gitlab:https://git.example.net/ai/aiterm")!
        let (secrets, defaults) = settings(host: "https://gitlab.com")
        #expect(throws: UpdateError.tokenForOtherHost("gitlab.com", feed: "git.example.net")) {
            _ = try feed.source(secrets: secrets, defaults: defaults)
        }
        #expect(UpdateError.tokenForOtherHost("gitlab.com", feed: "git.example.net").message
                == "Settings’ GitLab token is for gitlab.com; updates come from git.example.net.")
        let (other, otherDefaults) = settings(host: "https://git.example.net:8443")
        #expect(throws: UpdateError.tokenForOtherHost("git.example.net:8443", feed: "git.example.net")) {
            _ = try feed.source(secrets: other, defaults: otherDefaults)
        }
    }

    /// `:443` on an https URL (`:80` on http) names the port the URL would use anyway.
    @Test func anExplicitDefaultPortIsNoPort() throws {
        let (secrets, defaults) = settings(host: "https://git.example.net:443")
        let source = try #require(try ReleaseFeed("gitlab:https://git.example.net/ai/aiterm")!.source(secrets: secrets, defaults: defaults) as? GitLabReleaseSource)
        #expect(source.token == "tok")
        let (plain, plainDefaults) = settings(host: "http://git.example.net:80")
        #expect(throws: Never.self) { _ = try ReleaseFeed("gitlab:http://git.example.net/ai/aiterm")!.source(secrets: plain, defaults: plainDefaults) }
        let (other, otherDefaults) = settings(host: "https://gitlab.com:443")
        #expect(throws: UpdateError.tokenForOtherHost("gitlab.com", feed: "git.example.net")) {
            _ = try ReleaseFeed("gitlab:https://git.example.net:443/ai/aiterm")!.source(secrets: other, defaults: otherDefaults)
        }
    }

    /// No saved host is no GitLab set up in Settings, whatever a stray Keychain item says.
    @Test func aTokenWithoutAHostIsNoToken() {
        let (secrets, defaults) = settings(host: nil)
        #expect(throws: UpdateError.noToken) {
            _ = try ReleaseFeed("gitlab:https://git.example.net/ai/aiterm")!.source(secrets: secrets, defaults: defaults)
        }
    }

    @Test func missingFeedIsNoFeed() {
        let (secrets, defaults) = settings()
        #expect(throws: UpdateError.noFeed) { _ = try ReleaseFeed.source(for: nil, secrets: secrets, defaults: defaults) }
        #expect(throws: UpdateError.noFeed) { _ = try ReleaseFeed.source(for: "nonsense", secrets: secrets, defaults: defaults) }
    }
}
