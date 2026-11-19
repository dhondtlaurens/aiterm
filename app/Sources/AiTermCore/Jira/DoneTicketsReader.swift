import Foundation

/// Which of some Jira tickets are in a Done lane: their status in Jira's Done category, whatever the
/// board calls the column.
public protocol DoneTicketsReading: Sendable {
    /// The keys among `keys` whose ticket is done. A key Jira does not know is not done; a read that
    /// failed throws.
    func doneKeys(among keys: [String]) async throws -> Set<String>
}

extension JiraClient: DoneTicketsReading {
    /// How many keys one search names. Each answer lists only the done ones, so a page this size
    /// always holds the answer whole.
    static let doneKeysPerSearch = 50

    /// One search per `doneKeysPerSearch` keys, `key in (…) AND statusCategory = Done`. Jira answers
    /// 400 for a whole `key in (…)` when one key no longer resolves; that batch's keys are then asked
    /// one at a time, so only the unknown key is lost.
    public func doneKeys(among keys: [String]) async throws -> Set<String> {
        var done = Set<String>()
        var start = keys.startIndex
        while start < keys.endIndex {
            let batch = Array(keys[start..<min(start + Self.doneKeysPerSearch, keys.endIndex)])
            start += batch.count
            do {
                done.formUnion(try await doneKeys(jql: "key in (\(batch.map(Self.quoted).joined(separator: ", ")))", limit: batch.count))
            } catch JiraError.badResponse(400) {
                for key in batch {
                    do { done.formUnion(try await doneKeys(jql: "key = \(Self.quoted(key))", limit: 1)) }
                    catch JiraError.badResponse(400) { continue }
                }
            }
        }
        return done
    }

    private func doneKeys(jql condition: String, limit: Int) async throws -> Set<String> {
        let page = try await search(jql: "\(condition) AND statusCategory = Done", limit: limit, pageToken: nil)
        return Set(page.tickets.map(\.key))
    }

    /// A key as a JQL string literal.
    private static func quoted(_ key: String) -> String {
        "\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
