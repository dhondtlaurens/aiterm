import Foundation

/// The tasks an Operator effect is running on: a stage's launch, Then, a merge, a worker answer, an agent choice, a
/// message or a work tab. Each effect claims its task at its outermost entry and releases it on exit, so only one runs
/// on a task at a time. An owner that does not hold the claim treats a held task as at work.
@MainActor final class OperatorInFlight {
    private var held: Set<UUID> = []

    nonisolated init() {}

    /// Whether an effect is running on `id`.
    func holds(_ id: UUID) -> Bool { held.contains(id) }

    /// Claims `id` for an effect; false when another effect already holds it.
    func claim(_ id: UUID) -> Bool { held.insert(id).inserted }

    func release(_ id: UUID) { held.remove(id) }
}
