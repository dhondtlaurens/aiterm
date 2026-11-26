import Foundation

public enum MatchDecision: Equatable, Sendable {
    case start(SignalMatch, pending: [SignalStage])
    case continueTask(UUID, SignalStage)
    case skip(SignalMatch, reason: String)
    /// A project signal's pick-up: an ordinary task or review in the match's project, owing the signal's prompt.
    case startOrdinary(SignalMatch)
    /// A project signal's match on a task it marked before, or on a task made by hand: the task is marked with the
    /// signal and its prompt runs in the task's conversation.
    case rematch(UUID, SignalMatch)

    static let operatorRuns = "The Operator runs this item’s task."
    static let fromFork = "From a fork: AiTerm checks out only branches of the project’s own repository."
    static let noProject = "No project in AiTerm matches this item."
    static func severalProjects(_ projects: [Project]) -> String {
        "Several projects in AiTerm match this item: " + projects.map(\.name).sentenceList + "."
    }

    /// Runnable project signals rank first, in their order in `signals`, then Operator signals in theirs: when several
    /// match one item, the highest takes it. A project signal's item is its alone in this call; an Operator signal's
    /// lower matches wait as the taker's pending stages. An identity in `claimed` (a project pick-up queued or under
    /// way) yields nothing for an Operator signal.
    public static func decide(matches: [SignalMatch], signals: [Signal], tasks: [TaskItem], projects: [Project] = [], seen: [SignalSeen],
                              complete: Bool, claimed: Set<String> = []) -> [Self] {
        guard complete else { return [] }
        let enabled = signals.filter(\.isRunnable)
        let ranked = enabled.filter(\.isProject) + enabled.filter { !$0.isProject }
        let ranks = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element.id, $0.offset) })
        let ordered = matches.filter { match in
            ranks[match.signal] != nil && match.item.identity != nil && !seen.contains { prior in
                guard prior.signal == match.signal && prior.item.identity == match.item.identity else { return false }
                return prior.disposition == .started && prior.isMatching
            }
        }.sorted { ranks[$0.signal, default: .max] < ranks[$1.signal, default: .max] }
        var decisions: [Self] = [], started: [String: Int] = [:], handled = Set<String>()
        // The identities a project signal took in this call, by a pick-up or a re-match.
        var taken = Set<String>()
        for match in ordered {
            guard let identity = match.item.identity, let signal = enabled.first(where: { $0.id == match.signal }) else { continue }
            guard handled.insert(match.signal.uuidString + ":" + identity).inserted else { continue }
            if signal.isProject {
                guard !taken.contains(identity) else { continue }
                guard let decision = project(match, tasks: tasks, projects: projects) else { continue }
                switch decision {
                case .startOrdinary, .rematch: taken.insert(identity)
                default: break
                }
                decisions.append(decision)
                continue
            }
            guard !claimed.contains(identity), !taken.contains(identity) else { continue }
            let stage = SignalStage(signal: match.signal, item: match.item, matchedAt: match.matchedAt, configuration: signal)
            // A scheduled run is always a new task in its signal's project; it never continues another.
            if case .run = match.item {
                if match.project != nil { decisions.append(.start(match, pending: [])) }
                else { decisions.append(.skip(match, reason: ScheduleDecision.projectGone)) }
                continue
            }
            if let task = task(for: match, in: tasks, projects: projects) {
                // A task a person took over is theirs, and one a project signal marked is the person's: neither is
                // continued nor adopted.
                if !task.takenOver && !(task.signalOrigin != nil && task.signalTask == nil) { decisions.append(.continueTask(task.id, stage)) }
            } else if let index = started[identity], case .start(let first, var pending) = decisions[index] {
                pending.append(stage); decisions[index] = .start(first, pending: pending)
            } else if match.project != nil {
                started[identity] = decisions.count; decisions.append(.start(match, pending: []))
            } else { decisions.append(.skip(match, reason: noProject)) }
        }
        return decisions
    }

    /// A project signal's decision on one match, or nil when it yields nothing and leaves no record.
    private static func project(_ match: SignalMatch, tasks: [TaskItem], projects: [Project]) -> Self? {
        if case .run = match.item {
            return match.project != nil ? .startOrdinary(match) : .skip(match, reason: ScheduleDecision.projectGone)
        }
        // A fork's branch is not in the project's repository, and a same-named branch there is other code.
        if match.fromFork { return .skip(match, reason: fromFork) }
        if let task = task(for: match, in: tasks, projects: projects) {
            // A task a person took over is theirs.
            if task.takenOver { return nil }
            if task.signalTask != nil { return .skip(match, reason: operatorRuns) }
            // Its own task, or one made by hand, runs the prompt again; another project signal's task stays that
            // signal's, and the first signal keeps the item.
            if let origin = task.signalOrigin, origin.signal != match.signal { return nil }
            return .rematch(task.id, match)
        }
        let candidates = ItemProjectMapper.projects(for: match.item, in: projects)
        if candidates.count > 1 { return .skip(match, reason: severalProjects(candidates)) }
        return match.project != nil ? .startOrdinary(match) : .skip(match, reason: noProject)
    }

    /// The task, in the sidebar or archived, that already holds the match's item.
    private static func task(for match: SignalMatch, in tasks: [TaskItem], projects: [Project]) -> TaskItem? {
        tasks.first { candidate in
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
        }
    }

    public static func matchesItem(_ item: ItemRef, task: TaskItem) -> Bool {
        if let identity = item.identity,
           identity == task.signalTask?.current.item.identity || identity == task.signalOrigin?.item.identity { return true }
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
        case .run: return false
        }
    }
}

public struct SignalMatch: Equatable, Sendable {
    public var signal: UUID
    public var item: ItemRef
    public var project: UUID?
    public var branch: String?
    public var matchedAt: Date
    /// A merge request whose source branch lives in a fork.
    public var fromFork: Bool
    public init(signal: UUID, item: ItemRef, project: UUID?, matchedAt: Date, branch: String? = nil, fromFork: Bool = false) {
        self.signal = signal; self.item = item; self.project = project; self.matchedAt = matchedAt; self.branch = branch
        self.fromFork = fromFork
    }
}

public struct SignalSeen: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Hashable, Sendable {
        case started, skipped
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
    /// The records kept: those of a live item, those younger than 90 days, and, whatever its age, a live project
    /// signal's started record of an item that still matches, so a removed task's item never starts again while it
    /// matches.
    public static func pruned(_ values: [Self], liveItems: Set<String>, now: Date, projectSignals: Set<UUID> = []) -> [Self] {
        values.filter { value in
            if projectSignals.contains(value.signal) && value.disposition == .started && value.isMatching { return true }
            return value.item.identity.map(liveItems.contains) == true || now.timeIntervalSince(value.at) <= 90 * 86400
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
