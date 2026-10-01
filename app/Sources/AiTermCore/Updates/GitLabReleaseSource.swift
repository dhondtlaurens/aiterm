import Foundation

/// Releases of one GitLab project, read with the token from Settings. The newest release comes from
/// the release list rather than `releases/permalink/latest`, which only redirects to it, and from a
/// page of them rather than the first; `ReleasePage` picks from it. The disk image is the asset
/// link's `url` — the package-registry API URL, which accepts the token — not its
/// `direct_asset_url`, a web route that redirects there.
///
/// The token goes to the feed's own origin (scheme, host and port) and nowhere else: a request
/// carries it only there, and `HTTPJSON` drops it from any redirect hop that leaves.
public struct GitLabReleaseSource: ReleaseSource {
    public let host: URL, project: String, token: String
    let session: URLSession

    public init(host: URL, project: String, token: String, session: URLSession = .shared) {
        self.host = host; self.project = project; self.token = token; self.session = session
    }

    public func latest() async throws -> Release {
        guard let url = GitLabClient.apiURL(host: host, path: "/api/v4/projects/" + GitLabClient.encodedProject(project) + "/releases",
                                            query: [URLQueryItem(name: "per_page", value: "20")])
        else { throw UpdateError.projectNotFound(.gitLab, project) }
        let (data, response) = try await send(request(url, timeout: 15), listing: true)
        guard let page = try? GitLabClient.decoder.decode([Lenient<ReleasePayload>].self, from: data) else {
            throw UpdateError.badResponse(.gitLab, response.statusCode)
        }
        return try ReleasePage.newest(page.map { $0.value?.entry }, host: .gitLab, status: response.statusCode)
    }

    /// Streamed to disk, not held in memory: the disk image is the whole app bundle.
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

    private func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url)
        // The asset link is whatever a release editor typed.
        if url.isSameOrigin(as: host) { req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN") }
        req.timeoutInterval = timeout
        return req
    }

    private func send(_ req: URLRequest, listing: Bool) async throws -> (Data, HTTPURLResponse) {
        do { return try await HTTPJSON.send(req, session: session) }
        catch { throw mapped(error, listing: listing) }
    }

    /// A 404 for the release list is the project; for a disk image it is only a bad link.
    private func mapped(_ error: Error, listing: Bool) -> Error {
        switch error {
        case HTTPJSON.Failure.transport: return UpdateError.unreachable(host.host ?? host.absoluteString)
        case HTTPJSON.Failure.status(401), HTTPJSON.Failure.status(403): return UpdateError.rejected
        case HTTPJSON.Failure.status(404) where listing: return UpdateError.projectNotFound(.gitLab, project)
        case HTTPJSON.Failure.status(let status): return UpdateError.badResponse(.gitLab, status)
        default: return error
        }
    }
}

/// The fields of one entry of GitLab's release list that an update needs.
private struct ReleasePayload: Decodable {
    struct Assets: Decodable { var links: [Lenient<Link>]? }
    struct Link: Decodable { var name: String?, url: String? }
    var tagName: String?, assets: Assets?

    var entry: ReleaseEntry {
        let links = assets?.links?.compactMap(\.value) ?? []
        let named = links.compactMap { link in link.name.flatMap { name in link.url.flatMap(URL.init(string:)).map { (name, $0) } } }
        return ReleaseEntry(tag: tagName, assets: Dictionary(named, uniquingKeysWith: { first, _ in first }))
    }
}
