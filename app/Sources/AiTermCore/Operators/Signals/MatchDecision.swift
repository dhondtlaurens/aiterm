import Foundation

public enum MatchDecision: Equatable, Sendable {
    case start(SignalMatch, pending: [SignalStage])
    case continueTask(UUID, SignalStage)
    case skip(SignalMatch, reason: String)

    /// `signals` come in heading order, which is their priority: when several match one item, the
    /// highest takes it and the others wait as its pending stages.
    public static func decide(matches: [SignalMatch], signals: [Signal], tasks: [TaskItem], projects: [Project] = [], seen: [SignalSeen], complete: Bool) -> [Self] {
        guard complete else { return [] }
        let enabled = signals.filter(\.isRunnable)
        let ranks = Dictionary(uniqueKeysWithValues: enabled.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = matches.filter { match in
            ranks[match.signal] != nil && match.item.identity != nil && !seen.contains { prior in
                guard prior.signal == match.signal && prior.item.identity == match.item.identity else { return false }
                if case .unknown = prior.disposition { return true }
                return prior.disposition == .started && prior.isMatching
            }
        }.sorted { ranks[$0.signal, default: .max] < ranks[$1.signal, default: .max] }
        var decisions: [Self] = [], started: [String: Int] = [:], handled = Set<String>()
        for match in ordered {
            guard let identity = match.item.identity, let signal = enabled.first(where: { $0.id == match.signal }) else { continue }
            guard handled.insert(match.signal.uuidString + ":" + identity).inserted else { continue }
            let stage = SignalStage(signal: match.signal, item: match.item, matchedAt: match.matchedAt, configuration: signal)
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
                return false
            }) {
                // A task a person took over is theirs: it is neither continued nor adopted.
                if !task.takenOver { decisions.append(.continueTask(task.id, stage)) }
            } else if let index = started[identity], case .start(let first, var pending) = decisions[index] {
                pending.append(stage); decisions[index] = .start(first, pending: pending)
            } else if match.project != nil {
                started[identity] = decisions.count; decisions.append(.start(match, pending: []))
            } else { decisions.append(.skip(match, reason: "No project in AiTerm matches this item.")) }
        }
        return decisions
    }

    public static func matchesItem(_ item: ItemRef, task: TaskItem) -> Bool {
        if let identity = item.identity, identity == task.signalTask?.current.item.identity { return true }
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
        case .unknown: return false
        }
    }
}

public struct SignalMatch: Equatable, Sendable {
    public var signal: UUID
    public var item: ItemRef
    public var project: UUID?
    public var branch: String?
    public var matchedAt: Date
    public init(signal: UUID, item: ItemRef, project: UUID?, matchedAt: Date, branch: String? = nil) {
        self.signal = signal; self.item = item; self.project = project; self.matchedAt = matchedAt; self.branch = branch
    }
}

public struct SignalSeen: Codable, Equatable, Sendable {
    public enum Disposition: OpenStringEnum, Hashable, Sendable {
        case started, skipped
        case unknown(String)
        static let knownCases: [Self] = [.started, .skipped]
        var savedName: String {
            switch self {
            case .started: "started"
            case .skipped: "skipped"
            case .unknown(let value): value
            }
        }
    }
    public var signal: UUID
    public var item: ItemRef
    public var disposition: Disposition
    public var at: Date
    public var reason: String?
    public var isMatching: Bool
    public init(signal: UUID, item: ItemRef, disposition: Disposition, at: Date, reason: String? = nil, isMatching: Bool = true) {
        self.signal = signal; self.item = item; self.disposition = disposition; self.at = at; self.reason = reason
        self.isMatching = isMatching
    }
    public static func pruned(_ values: [Self], liveItems: Set<String>, now: Date) -> [Self] {
        values.filter { value in
            value.item.identity.map(liveItems.contains) == true || now.timeIntervalSince(value.at) <= 90 * 86400
        }
    }
}

/// The mapped items from a complete read that have not already started and stayed matching for this signal.
public enum SignalStarts {
    public static func items(in items: [SignalItem], signal: UUID?, projects: [Project], seen: [SignalSeen]) -> [SignalItem] {
        items.filter { item in
            !ItemProjectMapper.projects(for: item.item, in: projects).isEmpty && !seen.contains {
                $0.signal == signal && $0.item.identity == item.item.identity && $0.disposition == .started && $0.isMatching
            }
        }
    }
}
