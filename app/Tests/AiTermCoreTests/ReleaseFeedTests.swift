import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct ReleaseFeedTests {
    @Test func parsesAGitHubFeed() {
        #expect(ReleaseFeed("github:octocat/hello") == .gitHub(owner: "octocat", repo: "hello"))
        #expect(ReleaseFeed("github:octo-cat/hello.world.git") == .gitHub(owner: "octo-cat", repo: "hello.world"))
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

    @Test func aGitHubSourceNeedsNoToken() throws {
        let source = try #require(ReleaseFeed("github:octocat/hello")!.source() as? GitHubReleaseSource)
        #expect(source.owner == "octocat" && source.repo == "hello")
    }

    @Test func rejectsWhatItCannotUse() {
        for bad in ["", "gitlab:", "gitlab:https://git.example.net", "gitlab:https://git.example.net/solo",
                    "https://git.example.net/ai/aiterm", "gitlab:not a url/x/y",
                    "github:", "github:owner", "github:owner/", "github:/repo", "github:a/b/c", "github:own er/repo",
                    "github:https://github.com/a/b"] {
            #expect(ReleaseFeed(bad) == nil, "\(bad)")
        }
    }

    @Test func missingFeedIsNoFeed() {
        #expect(throws: UpdateError.noFeed) { _ = try ReleaseFeed.source(for: nil) }
        #expect(throws: UpdateError.noFeed) { _ = try ReleaseFeed.source(for: "nonsense") }
    }
}
