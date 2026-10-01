import Foundation
import Testing
@testable import AiTermCore

@Suite struct GitLabReleaseSourceTests {
    let host = URL(string: "https://git.example.net")!
    let assetURL = "https://git.example.net/api/v4/projects/ai%2Faiterm/packages/generic/aiterm/0.3.0/AiTerm-0.3.0.dmg"

    func releases(tag: String = "v0.3.0", links: [[String: Any]]? = nil) -> Data {
        let links = links ?? [["name": "AiTerm-0.3.0.dmg", "url": assetURL,
                               "direct_asset_url": "https://git.example.net/ai/aiterm/-/releases/v0.3.0/downloads/AiTerm-0.3.0.dmg"]]
        return try! JSONSerialization.data(withJSONObject: [["tag_name": tag, "assets": ["links": links]]])
    }

    func source(_ handler: @escaping StubURLProtocol.Handler) -> (GitLabReleaseSource, StubSession) {
        let stub = StubSession(handler: handler)
        return (GitLabReleaseSource(host: host, project: "ai/aiterm", token: "tok", session: stub.session), stub)
    }

    @Test func latestReadsNewestReleaseAndItsPackageLink() async throws {
        let (src, stub) = source { _ in (200, self.releases()) }
        let release = try await src.latest()
        #expect(release == Release(version: ReleaseVersion("0.3.0")!, assetURL: URL(string: assetURL)!))
        let req = try #require(stub.lastRequest)
        #expect(req.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "tok")
        #expect(req.url?.absoluteString == "https://git.example.net/api/v4/projects/ai%2Faiterm/releases?per_page=20")
    }

    func release(_ tag: String, asset: Bool = true) -> [String: Any] {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let name = ReleaseVersion(version).map(Release.assetName(for:)) ?? "AiTerm-\(version).dmg"
        let links: [[String: Any]] = asset ? [["name": name, "url": "https://git.example.net/packages/\(version).dmg"]] : []
        return ["tag_name": tag, "assets": ["links": links]]
    }

    /// One stray release — a tag that is not a version, or one published before its disk image was
    /// attached — used to hide every good release behind it.
    @Test func latestSkipsReleasesItCannotInstallAndTakesTheHighestVersion() async throws {
        let list = try JSONSerialization.data(withJSONObject: [release("nightly"), release("v0.5.0", asset: false), release("v0.3.1"), release("v0.4.0"), release("v0.2.0")])
        let (src, _) = source { _ in (200, list) }
        #expect(try await src.latest() == Release(version: ReleaseVersion("0.4.0")!, assetURL: URL(string: "https://git.example.net/packages/0.4.0.dmg")!))
    }

    @Test func aPageWithNothingInstallableNamesTheNewestProblem() async {
        await #expect(throws: UpdateError.missingAsset(.gitLab, "0.5.0")) {
            let list = try JSONSerialization.data(withJSONObject: [self.release("nightly"), self.release("v0.4.0", asset: false), self.release("v0.5.0", asset: false)])
            _ = try await self.source { _ in (200, list) }.0.latest()
        }
        await #expect(throws: UpdateError.unreadableTag(.gitLab, "nightly")) {
            let list = try JSONSerialization.data(withJSONObject: [self.release("nightly"), self.release("beta")])
            _ = try await self.source { _ in (200, list) }.0.latest()
        }
    }

    /// One entry that does not decode — a tag that is not a string, a malformed link — is a stray
    /// like any other: it must not fail the whole page.
    @Test func anEntryThatDoesNotDecodeIsSkipped() async throws {
        let list = try JSONSerialization.data(withJSONObject: [["tag_name": 5], release("v0.4.0")])
        let (src, _) = source { _ in (200, list) }
        #expect(try await src.latest().version == ReleaseVersion("0.4.0")!)

        var badLink = release("v0.5.0")
        badLink["assets"] = ["links": [["name": 7], ["name": "AiTerm-0.5.0.dmg", "url": "https://git.example.net/packages/0.5.0.dmg"]]]
        let linkedList = try JSONSerialization.data(withJSONObject: [badLink])
        let (linked, _) = source { _ in (200, linkedList) }
        #expect(try await linked.latest().version == ReleaseVersion("0.5.0")!, "a malformed link drops only itself")
    }

    /// With the entry that did not decode skipped, "the first tag" is the first one that did; a
    /// page on which nothing decodes is no release list at all.
    @Test func theFirstTagNamedIsTheFirstThatDecoded() async {
        await #expect(throws: UpdateError.unreadableTag(.gitLab, "nightly")) {
            let list = try JSONSerialization.data(withJSONObject: [["tag_name": 5], self.release("nightly")])
            _ = try await self.source { _ in (200, list) }.0.latest()
        }
        await #expect(throws: UpdateError.badResponse(.gitLab, 200)) {
            _ = try await self.source { _ in (200, try! JSONSerialization.data(withJSONObject: [["tag_name": 5]])) }.0.latest()
        }
    }

    @Test func emptyListIsNoRelease() async {
        await #expect(throws: UpdateError.noRelease(.gitLab)) {
            _ = try await source { _ in (200, Data("[]".utf8)) }.0.latest()
        }
    }

    @Test func statusCodesMapToErrors() async {
        for (status, error) in [(401, UpdateError.rejected), (403, .rejected), (404, .projectNotFound(.gitLab, "ai/aiterm")), (500, .badResponse(.gitLab, 500))] {
            await #expect(throws: error) { _ = try await source { _ in (status, Data()) }.0.latest() }
        }
    }

    @Test func tagThatIsNotAVersion() async {
        await #expect(throws: UpdateError.unreadableTag(.gitLab, "nightly")) {
            _ = try await source { _ in (200, self.releases(tag: "nightly")) }.0.latest()
        }
    }

    @Test func releaseWithoutTheDiskImage() async {
        await #expect(throws: UpdateError.missingAsset(.gitLab, "0.3.0")) {
            _ = try await source { _ in (200, self.releases(links: [["name": "notes.txt", "url": "https://x/notes.txt"]])) }.0.latest()
        }
    }

    @Test func garbageBodyIsABadResponse() async {
        await #expect(throws: UpdateError.badResponse(.gitLab, 200)) {
            _ = try await source { _ in (200, Data("<html>".utf8)) }.0.latest()
        }
    }

    @Test func downloadWritesTheBodyWithTheToken() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (src, stub) = source { _ in (200, Data("dmg-bytes".utf8)) }
        let release = Release(version: ReleaseVersion("0.3.0")!, assetURL: URL(string: assetURL)!)
        let destination = dir.appendingPathComponent("AiTerm-0.3.0.dmg")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("an earlier attempt".utf8).write(to: destination)
        try await src.download(release, to: destination)
        #expect(try Data(contentsOf: destination) == Data("dmg-bytes".utf8))
        #expect(stub.lastRequest?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "tok")
        #expect(stub.lastRequest?.url?.absoluteString == assetURL)
    }

    /// Review finding: anyone who can edit a release could point its link elsewhere and collect
    /// the Settings token of everyone who updates.
    @Test func tokenIsNotSentToAnotherHost() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (src, stub) = source { _ in (200, Data("dmg-bytes".utf8)) }
        let release = Release(version: ReleaseVersion("0.3.0")!, assetURL: URL(string: "https://evil.example.com/AiTerm-0.3.0.dmg")!)
        try await src.download(release, to: dir.appendingPathComponent("AiTerm-0.3.0.dmg"))
        #expect(stub.lastRequest?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil)
    }

    /// GitLab answers a package download with a redirect to object storage, and URLSession
    /// re-sends custom headers on every hop: the token must stop at the feed's own origin.
    @Test func tokenDoesNotFollowARedirectToAnotherHost() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = URL(string: "https://storage.example.com/bucket/AiTerm-0.3.0.dmg?sig=x")!
        let stub = RedirectSession(redirects: [URL(string: assetURL)!: storage], body: Data("dmg-bytes".utf8))
        let src = GitLabReleaseSource(host: host, project: "ai/aiterm", token: "tok", session: stub.session)
        let destination = dir.appendingPathComponent("AiTerm-0.3.0.dmg")
        try await src.download(Release(version: ReleaseVersion("0.3.0")!, assetURL: URL(string: assetURL)!), to: destination)
        #expect(try Data(contentsOf: destination) == Data("dmg-bytes".utf8))
        let hops = stub.requests
        #expect(hops.map(\.url) == [URL(string: assetURL)!, storage])
        #expect(hops.first?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "tok")
        #expect(hops.last?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil)
    }

    @Test func tokenFollowsARedirectWithinTheFeedsOrigin() async throws {
        let moved = URL(string: "https://git.example.net/api/v4/projects/42/releases?per_page=20")!
        let listURL = URL(string: "https://git.example.net/api/v4/projects/ai%2Faiterm/releases?per_page=20")!
        let stub = RedirectSession(redirects: [listURL: moved], body: releases())
        let src = GitLabReleaseSource(host: host, project: "ai/aiterm", token: "tok", session: stub.session)
        _ = try await src.latest()
        #expect(stub.requests.map { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") } == ["tok", "tok"])
    }

    /// Each hop is judged on its own: staying on the feed's origin for a hop keeps the token, and the
    /// first hop off it loses it.
    @Test func tokenStopsAtTheFirstHopOffTheFeedsOrigin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let internalHop = URL(string: "https://git.example.net/api/v4/projects/42/packages/generic/aiterm/0.3.0/AiTerm-0.3.0.dmg")!
        let storage = URL(string: "https://storage.example.com/bucket/AiTerm-0.3.0.dmg")!
        let stub = RedirectSession(redirects: [URL(string: assetURL)!: internalHop, internalHop: storage], body: Data("dmg-bytes".utf8))
        let src = GitLabReleaseSource(host: host, project: "ai/aiterm", token: "tok", session: stub.session)
        try await src.download(Release(version: ReleaseVersion("0.3.0")!, assetURL: URL(string: assetURL)!), to: dir.appendingPathComponent("AiTerm-0.3.0.dmg"))
        #expect(stub.requests.map(\.url) == [URL(string: assetURL)!, internalHop, storage])
        #expect(stub.requests.map { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") } == ["tok", "tok", nil])
    }

    @Test func tokenDoesNotFollowADowngradeToHTTPOnTheSameHost() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = URL(string: "http://git.example.net/api/v4/projects/ai%2Faiterm/packages/generic/aiterm/0.3.0/AiTerm-0.3.0.dmg")!
        let stub = RedirectSession(redirects: [URL(string: assetURL)!: plain], body: Data("dmg-bytes".utf8))
        let src = GitLabReleaseSource(host: host, project: "ai/aiterm", token: "tok", session: stub.session)
        try await src.download(Release(version: ReleaseVersion("0.3.0")!, assetURL: URL(string: assetURL)!), to: dir.appendingPathComponent("AiTerm-0.3.0.dmg"))
        #expect(stub.requests.map(\.url) == [URL(string: assetURL)!, plain])
        #expect(stub.requests.map { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") } == ["tok", nil])
    }

    /// A feed written with `:443` is the same origin as asset links written without it.
    @Test func anExplicitDefaultPortIsTheSameOrigin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubSession { _ in (200, Data("dmg-bytes".utf8)) }
        let src = GitLabReleaseSource(host: URL(string: "https://git.example.net:443")!, project: "ai/aiterm", token: "tok", session: stub.session)
        try await src.download(Release(version: ReleaseVersion("0.3.0")!, assetURL: URL(string: assetURL)!), to: dir.appendingPathComponent("AiTerm-0.3.0.dmg"))
        #expect(stub.lastRequest?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "tok")
    }

    /// Same host, different scheme: `http://` would put the token on the wire in the clear.
    @Test func tokenIsNotSentOverAnotherScheme() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (src, stub) = source { _ in (200, Data("dmg-bytes".utf8)) }
        let plain = URL(string: "http://git.example.net/api/v4/projects/ai%2Faiterm/packages/generic/aiterm/0.3.0/AiTerm-0.3.0.dmg")!
        try await src.download(Release(version: ReleaseVersion("0.3.0")!, assetURL: plain), to: dir.appendingPathComponent("AiTerm-0.3.0.dmg"))
        #expect(stub.lastRequest?.url == plain)
        #expect(stub.lastRequest?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil)
    }

    @Test func failedDownloadWritesNothing() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = dir.appendingPathComponent("AiTerm-0.3.0.dmg")
        let release = Release(version: ReleaseVersion("0.3.0")!, assetURL: URL(string: assetURL)!)
        await #expect(throws: UpdateError.badResponse(.gitLab, 404)) {
            try await source { _ in (404, Data()) }.0.download(release, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
