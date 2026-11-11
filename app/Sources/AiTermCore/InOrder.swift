import Foundation

/// `body` for each of `items`, `width` at a time, and the results in the order of `items`. The
/// first failure cancels the bodies still running. The default width limits requests in flight:
/// a number across ten linked Jira projects asks for ten picker lists and ten lookups, which
/// Jira answered with 429 when sent at once.
func inOrder<Item: Sendable, Output: Sendable>(
    _ items: [Item], width: Int = 4, _ body: @escaping @Sendable (Item) async throws -> Output
) async throws -> [Output] {
    precondition(width > 0, "a fan-out of no width never starts")
    return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var pending = items.enumerated().makeIterator()
        func startNext(in group: inout ThrowingTaskGroup<(Int, Output), Error>) {
            guard let (index, item) = pending.next() else { return }
            group.addTask { (index, try await body(item)) }
        }
        for _ in 0..<width { startNext(in: &group) }
        var results = [Output?](repeating: nil, count: items.count)
        while let (index, output) = try await group.next() {
            results[index] = output
            startNext(in: &group)
        }
        // Every item started and none finished twice, so every slot is filled.
        return results.map { $0! }
    }
}
