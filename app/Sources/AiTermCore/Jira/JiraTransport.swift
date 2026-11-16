import Foundation

extension JiraClient {
    func send(method: String, path: String, json: Data) async throws -> Data {
        var req = request(path: path)
        req.httpMethod = method
        req.httpBody = json
        do { return try await HTTPJSON.send(req, session: session).0 }
        catch let failure as HTTPJSON.Failure { throw Self.error(for: failure) }
    }

    /// Jira's own keys are camelCase; a caller-supplied path identifies a decoding failure in the log.
    func decode<Response: Decodable>(_ type: Response.Type, data: Data, reading path: String? = nil) throws -> Response {
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            if let path {
                Log.network.failed("Reading \(config.siteURL.appendingPathComponent(path).path) as \(Response.self)", error)
            }
            throw JiraError.decoding
        }
    }

}
