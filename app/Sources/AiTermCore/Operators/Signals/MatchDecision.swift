import Foundation

public enum MatchDecision: Equatable, Sendable {
    case start(SignalMatch, pending: [SignalStage])
    case continueTask(UUID, SignalStage)
    case skip(SignalMatch, reason: String)

    public static func decide(matches: [SignalMatch], signals: [Signal], tasks: [TaskItem], projects: [Project] = [], seen: [SignalSeen], complete: Bool) -> [Self] {
        guard complete else { return [] }
        let enabled = signals.filter(\.isRunnable).sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        let ranks = Dictionary(uniqueKeysWithValues: enabled.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = matches.filter { match in
            ranks[match.signal] != nil && match.item.identity != nil && !seen.contains {
                $0.signal == match.signal && $0.item.identity == match.item.identity && $0.disposition == .started && $0.isMatching
            }
        }.sorted { ranks[$0.signal, default: .max] < ranks[$1.signal, default: .max] }
        var decisions: [Self] = [], started: [String: Int] = [:], handled = Set<String>()
        for match in ordered {
            guard let identity = match.item.identity else { continue }
            guard handled.insert(match.signal.uuidString + ":" + identity).inserted else { continue }
            let stage = SignalStage(signal: match.signal, item: match.item, matchedAt: match.matchedAt)
            if let task = tasks.first(where: { candidate in
                if matchesItem(match.item, task: candidate) { return true }
                // A real Jira read can bind an existing request/manual branch before that task
                // has a JiraRef. The linked project and site must agree; a key in an arbitrary
                // branch or on another Jira connection is not enough.
                if candidate.jira == nil, case .ticket(let ticket) = match.item,
                   TicketMergeRequests.jiraKey(in: candidate.branch) == ticket.key.uppercased(),
                   ItemProjectMapper.projects(for: match.item, in: projects).contains(where: { $0.id == candidate.projectId }) { return true }
                if let branch = match.branch, branch == candidate.branch,
                   case .mergeRequest(let request) = match.item,
                   projects.contains(where: { $0.id == candidate.projectId && $0.remoteUrl.flatMap(ItemRef.repository) == ItemRef.repository(request.remote) }) { return true }
                if case .branch(let branch) = match.item {
                    return candidate.branch == branch.name && projects.contains {
                        $0.id == candidate.projectId && $0.remoteUrl.flatMap(ItemRef.repository) == ItemRef.repository(branch.remote)
                    }
                }
                return false
            }) {
                if task.signalTask?.takenOver != true { decisions.append(.continueTask(task.id, stage)) }
            } else if let index = started[identity], case .start(let first, var pending) = decisions[index] {
                pending.append(stage); decisions[index] = .start(first, pending: pending)
            } else if match.project != nil {
                started[identity] = decisions.count; decisions.append(.start(match, pending: []))
            } else { decisions.append(.skip(match, reason: "No project in AiTerm matches this item.")) }
        }
        return decisions
    }

    public static func matchesItem(_ item: ItemRef, task: TaskItem) -> Bool {
        if let identity = item.identity, identity == task.signalTask?.item.identity { return true }
        switch item {
        case .ticket(let ticket):
            guard let jira = task.jira, jira.key.caseInsensitiveCompare(ticket.key) == .orderedSame else { return false }
            guard let url = URL(string: jira.url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            if let browse = components.path.range(of: "/browse/") { components.path = String(components.path[..<browse.lowerBound]) }
            components.query = nil; components.fragment = nil
            return ItemRef.ticket(site: components.string ?? "", key: jira.key).identity == item.identity
        case .mergeRequest(let ref):
            guard let mr = task.mr, mr.iid == ref.number, let url = URL(string: mr.url), let host = url.host else { return false }
            var path = url.path
            if let split = path.range(of: "/-/merge_requests/") ?? path.range(of: "/pull/") { path = String(path[..<split.lowerBound]) }
            return ItemRef.repository("https://" + host + path) == ItemRef.repository(ref.remote)
        case .branch(let ref):
            guard task.branch == ref.name else { return false }
            return task.signalTask?.watchedRequest.map { ItemRef.repository($0.remote) == ItemRef.repository(ref.remote) } ?? false
        case .unknown: return false
        }
    }
}
