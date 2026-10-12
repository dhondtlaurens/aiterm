import Foundation

/// Orders the archive for the Archive sheet's search field: a pure function over what is in hand, so
/// it is tested without a sheet. Each row scores its best field — title, ticket key and summary,
/// merge request number and title, branch, project — in five tiers, because a long archive buries
/// the one you mean under a plain substring match:
///
/// 0. the exact ticket key, or the merge request's number written `482`, `!482` or `#482`;
/// 1. a field that starts with the query, which for the merge request number counts with or without
///    the `!` or `#`, so `!4` and `!48` find !482 while it is being typed;
/// 2. a word in a field that starts with it (words split on space, `/`, `-`, `_` and `.`);
/// 3. the query anywhere in a field;
/// 4. every letter of the query in order in a field — the fuzzy tier.
///
/// Within a tier, and for an empty query, the most recently archived comes first.
public enum ArchiveSearch {
    public struct Entry: Equatable, Sendable {
        public let archived: ArchivedTask
        public let projectName: String
        /// Which host's mark the row's merge request badge wears.
        public let provider: Provider
        public init(archived: ArchivedTask, projectName: String, provider: Provider) {
            self.archived = archived; self.projectName = projectName; self.provider = provider
        }
    }

    public static func rank(_ entries: [Entry], query: String) -> [Entry] {
        let newestFirst = entries.sorted { $0.archived.archivedAt > $1.archived.archivedAt }
        let query = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return newestFirst }
        return newestFirst.enumerated()
            .compactMap { position, entry in tier(of: entry, query: query).map { (tier: $0, position: position, entry: entry) } }
            .sorted { ($0.tier, $0.position) < ($1.tier, $1.position) }
            .map(\.entry)
    }

    static func tier(of entry: Entry, query: String) -> Int? {
        let task = entry.archived.task
        if let iid = task.mr?.iid, number(in: query) == iid { return 0 }
        if let key = task.jira?.key, normalized(key) == query { return 0 }
        // The number is a field bare, without its `!`: a lone `!` is no number and must not match every request.
        if let iid = task.mr?.iid, let digits = sigilDigits(in: query), String(iid).hasPrefix(digits) { return 1 }
        let fields = [task.title, task.jira?.key, task.jira?.summary, task.mr.map { String($0.iid) }, task.mr?.title,
                      task.branch, entry.projectName].compactMap { $0 }.map(normalized)
        if fields.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if fields.contains(where: { words(of: $0).contains { $0.hasPrefix(query) } }) { return 2 }
        if fields.contains(where: { $0.contains(query) }) { return 3 }
        let letters = query.filter { !$0.isWhitespace }
        if fields.contains(where: { isSubsequence(letters, of: $0) }) { return 4 }
        return nil
    }

    /// The merge request number a query names: digits, after an optional `!` or `#`.
    static func number(in query: String) -> Int? {
        let digits = query.hasPrefix("!") || query.hasPrefix("#") ? String(query.dropFirst()) : query
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// The digits typed after a leading `!` or `#` — the start of a merge request number — or nil when
    /// there is no such sigil or nothing but digits follows it. A lone sigil names no number.
    static func sigilDigits(in query: String) -> String? {
        guard query.hasPrefix("!") || query.hasPrefix("#") else { return nil }
        let digits = String(query.dropFirst())
        return !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber) ? digits : nil
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func words(of text: String) -> [Substring] {
        text.split { $0 == " " || $0 == "/" || $0 == "-" || $0 == "_" || $0 == "." }
    }

    static func isSubsequence(_ query: String, of text: String) -> Bool {
        guard !query.isEmpty else { return false }
        var rest = text[...]
        for letter in query {
            guard let found = rest.firstIndex(of: letter) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }
}
