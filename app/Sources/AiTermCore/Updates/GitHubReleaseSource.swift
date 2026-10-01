import Foundation

/// Releases of one public GitHub repository, read without a token: AiTerm's repository is public,
/// so an update check needs no credential and sends none — not even the token Settings saved for
/// reviews. Drafts and prereleases are never offered. The image is the asset's
/// `browser_download_url`, which GitHub redirects to its CDN.
public struct GitHubReleaseSource: ReleaseSource {
    public let owner: String, repo: String
    let session: URLSession

    public init(owner: String, repo: String, session: URLSession = .shared) {
        self.owner = owner; self.repo = repo; self.session = session
    }

    public func latest() async throws -> Release {
        var components = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repo)/releases")
        components?.queryItems = [URLQueryItem(name: "per_page", value: "20")]
        guard let url = components?.url else { throw UpdateError.projectNotFound(.gitHub, "\(owner)/\(repo)") }
        let (data, response) = try await send(request(url, timeout: 15))
        guard let page = try? Self.decoder.decode([Lenient<ReleasePayload>].self, from: data) else {
            throw UpdateError.badResponse(.gitHub, response.statusCode)
        }
        let published = page.filter { $0.value.map { !$0.isDraft && !$0.isPrerelease } ?? true }
        return try ReleasePage.newest(published.map { $0.value?.entry }, host: .gitHub, status: response.statusCode)
    }

    /// Streamed to disk, not held in memory: the image is the whole app bundle.
    public func download(_ release: Release, to destination: URL) async throws {
        let file: URL
        do { (file, _) = try await HTTPJSON.download(request(release.assetURL, timeout: 300), session: session) }
        catch { throw mapped(error, listing: false) }
        let fm = FileManager.default
        defer { try? fm.removeItem(at: file) }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: file, to: destination)
        } catch {
            throw UpdateError.other(error.localizedDescription)
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = timeout
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await HTTPJSON.send(req, session: session) }
        catch { throw mapped(error, listing: true) }
    }

    /// Unauthenticated, GitHub answers a spent rate limit with 403 or 429. A 404 for the release
    /// list is the repository; for an image it is only a bad link.
    private func mapped(_ error: Error, listing: Bool) -> Error {
        switch error {
        case HTTPJSON.Failure.transport: return UpdateError.unreachable("api.github.com")
        case HTTPJSON.Failure.status(403), HTTPJSON.Failure.status(429): return UpdateError.rateLimited
        case HTTPJSON.Failure.status(404) where listing: return UpdateError.projectNotFound(.gitHub, "\(owner)/\(repo)")
        case HTTPJSON.Failure.status(let status): return UpdateError.badResponse(.gitHub, status)
        default: return error
        }
    }
}

/// The fields of one entry of GitHub's release list that an update needs.
private struct ReleasePayload: Decodable {
    struct Asset: Decodable { var name: String?, browserDownloadUrl: String? }
    var tagName: String?, draft: Bool?, prerelease: Bool?, assets: [Lenient<Asset>]?

    var isDraft: Bool { draft ?? false }
    var isPrerelease: Bool { prerelease ?? false }

    var entry: ReleaseEntry {
        let named = (assets ?? []).compactMap(\.value).compactMap { asset in
            asset.name.flatMap { name in asset.browserDownloadUrl.flatMap(URL.init(string:)).map { (name, $0) } }
        }
        return ReleaseEntry(tag: tagName, assets: Dictionary(named, uniquingKeysWith: { first, _ in first }))
    }
}
