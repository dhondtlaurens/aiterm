/// A bounded startAt listing. Each endpoint decides whether another page is needed; `count` is
/// the raw entry count, including malformed entries that were dropped from `items`.
func startAtPages<Item>(limit: Int = 20,
    read: (Int) async throws -> (items: [Item], count: Int, hasMore: Bool)) async throws -> [Item] {
    var startAt = 0, items: [Item] = []
    for _ in 0..<limit {
        let page = try await read(startAt)
        items += page.items
        startAt += page.count
        if page.count == 0 || !page.hasMore { break }
    }
    return items
}
