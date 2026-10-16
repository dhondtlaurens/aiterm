import Foundation

/// M3's re-acceptance (spec §8). A task accepted again on another commit replaces what its `code`
/// dependents were built on: one already accepted loses its acceptance and goes back to working,
/// and every started one is flagged *upstream replaced*, which blocks its publication
/// (`PublicationGuard`) until its worker rebases and the operator accepts it again. A dependent
/// not started yet branches from the new commit when it starts, and an `order` dependent did not
/// build on the code at all; both are left alone. A parent's branch moving past its accepted
/// commit without a new acceptance changes nothing.
public enum UpstreamReplacement {
    public enum Refusal: Error, Equatable, Sendable {
        case notAccepted(String), merged(String)
    }

    /// `id`, accepted already (or published as a draft), accepted again as `acceptance`. Returns the
    /// dependents it changed; the same commit again changes nothing. A task merged on its host, by
    /// AiTerm or before AiTerm's answer came, is never accepted again.
    public static func reaccept(_ id: UUID, as acceptance: TaskAcceptance, in state: inout AppState) throws(Refusal) -> [UUID] {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }), var operated = state.tasks[index].operated else { return [] }
        guard operated.state == .accepted || operated.state == .published else {
            throw .notAccepted("\(operated.key) isn't accepted; mark it accepted instead.")
        }
        guard operated.publication?.merged != true, operated.publication?.mergedSHA == nil else {
            throw .merged("\(operated.key) is merged already; a new commit needs a new task.")
        }
        if let earlier = operated.acceptance?.resultSHA, OperatedTransitions.sameCommit(earlier, acceptance.resultSHA) { return [] }
        operated.acceptance = acceptance
        operated.state = .accepted
        OperatedTransitions.settle(&operated)
        state.tasks[index].operated = operated
        return revokeDependents(of: id, newSHA: acceptance.resultSHA, in: &state)
    }

    /// `parent`'s accepted code dependents back to working and every started one flagged, each once. What
    /// is built on a dependent that changed is built on code that is no longer accepted either, so its own
    /// dependents are replaced the same way, whatever commit they hold.
    public static func revokeDependents(of parent: UUID, newSHA: String, in state: inout AppState) -> [UUID] {
        var changed: [UUID] = [], seen: Set<UUID> = [parent]
        var frontier: [(parent: UUID, newSHA: String?)] = [(parent, newSHA)]
        while !frontier.isEmpty {
            var next: [(parent: UUID, newSHA: String?)] = []
            for (parent, newSHA) in frontier {
                for index in state.tasks.indices {
                    guard var operated = state.tasks[index].operated, !seen.contains(state.tasks[index].id),
                          operated.dependsOn.contains(where: { $0.task == parent && $0.kind == .code }) else { continue }
                    let before = operated
                    switch operated.state {
                    case .planned, .queued, .stopped:
                        continue
                    case .accepted, .noChange:
                        if let newSHA, operated.acceptance?.prerequisiteSHAs.contains(newSHA) == true { continue }
                        operated.acceptance = nil
                        operated.state = .working
                    case .working, .blocked, .failed, .published:
                        break
                    }
                    operated.flags.insert(.upstreamReplaced)
                    seen.insert(state.tasks[index].id)
                    state.tasks[index].operated = operated
                    next.append((state.tasks[index].id, nil))
                    if operated != before { changed.append(state.tasks[index].id) }
                }
            }
            frontier = next
        }
        return changed
    }

    /// Why a task flagged *upstream replaced* cannot be accepted yet: its result must contain each
    /// code parent's accepted commit. `contains` asks git (`Repository.contains(_:in:)` on the
    /// proposed result). Nil when it may — and then the caller clears the flag.
    public static func acceptRefusal(for task: TaskItem, in state: AppState,
                                     contains: (_ parentSHA: String) throws -> Bool) rethrows -> String? {
        guard let operated = task.operated, operated.flags.contains(.upstreamReplaced) else { return nil }
        for dependency in operated.dependsOn where dependency.kind == .code {
            guard let parent = state.tasks.first(where: { $0.id == dependency.task })?.operated,
                  let parentSHA = parent.acceptance?.resultSHA else { continue }
            if try !contains(parentSHA) {
                return "\(operated.key) doesn't contain \(parent.key)'s accepted commit \(parentSHA.prefix(7)) yet: have its worker rebase on it first."
            }
        }
        return nil
    }
}
