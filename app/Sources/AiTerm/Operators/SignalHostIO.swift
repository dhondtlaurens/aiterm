import Foundation
import AiTermCore

/// Binds finish checks to the connected repository. Only the explicit, rechecked merge effect
/// writes to a host; the skills own every other publication.
@MainActor final class SignalHostIO {
    let workspace: WorkspaceStore
    let git: any GitRunning
    var enabled: () -> Bool = { true }
    var connections: @MainActor () async -> SignalConnections
    var remote: @MainActor (Project, TaskItem) async throws -> String
    init(workspace: WorkspaceStore, git: any GitRunning, connections: @escaping @MainActor () async -> SignalConnections) {
        self.workspace = workspace; self.git = git; self.connections = connections
        remote = { project, task in
            try await BackgroundWork.run { try git.run(["remote", "get-url", "origin"], in: task.hasCheckout && FileManager.default.fileExists(atPath: task.worktreePath) ? task.worktreePath : project.path).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
    private func binding(_ task: TaskItem, links: SignalConnections) async throws -> (String, any HostRepository) {
        guard let project = workspace.state.project(id: task.projectId), let saved = project.remoteUrl else { throw ActionUnavailable("Its project has no connected remote.") }
        let current = try await remote(project, task)
        guard let repository = ItemRef.repository(current), repository == ItemRef.repository(saved) else { throw ActionUnavailable("Its origin changed; check the project's repository before continuing.") }
        let references = [task.signalTask?.watchedRequest?.remote, task.signalTask.flatMap { record -> String? in if case .mergeRequest(let ref) = record.current.item { return ref.remote }; return nil }].compactMap { $0 }
        guard references.allSatisfy({ ItemRef.repository($0) == repository }) else {
            throw ActionUnavailable("The saved request belongs to another repository.")
        }
        if let mr = task.mr {
            var ordinary = task; ordinary.signalTask = nil
            guard MatchDecision.matchesItem(.request(remote: current, number: mr.iid), task: ordinary) else {
                throw ActionUnavailable("The request link belongs to another repository.")
            }
        }
        let host = try CodeHosts.repository(for: ProviderDetector.detect(remoteUrl: current), gitLab: links.gitLab, gitHub: links.gitHub, session: links.session)
        return (current, host)
    }
    private func requestNumber(_ task: TaskItem) -> Int? {
        if case .mergeRequest(let reference) = task.signalTask?.current.item { return reference.number }
        return task.mr?.iid ?? task.signalTask?.watchedRequest?.number
    }
    private func request(_ task: TaskItem, host: any HostRepository) async throws -> MergeRequest? {
        if let number = requestNumber(task) {
            return try await host.request(number: number)
        }
        return try await host.request(forBranch: task.branch)
    }
    /// The request's status by its known number; without one, the branch's request is found first.
    private func status(_ task: TaskItem, host: any HostRepository) async throws -> RequestStatus? {
        if let number = requestNumber(task) { return try await host.status(of: number) }
        guard let found = try await host.request(forBranch: task.branch) else { return nil }
        return try await host.status(of: found.iid)
    }
    private func ticket(_ task: TaskItem, links: SignalConnections) async throws -> JiraTicket? {
        guard let ref = task.jira, ref.source == .jira else { return nil }
        guard let jira = links.jira, ref.url.hasPrefix(jira.siteURL.absoluteString + "/") else { throw ActionUnavailable("The ticket belongs to another Jira connection.") }
        let read = try await JiraQueryReader(client: JiraClient(config: jira, session: links.session),
            conditions: JiraConditions(jql: "key = " + JQL.quoted(ref.key))).poll(since: nil, full: true)
        guard read.complete else { throw IncompleteRead("ticket status") }
        return read.items.compactMap(\.ticket).first { $0.key.caseInsensitiveCompare(ref.key) == .orderedSame }
    }
    func read(_ task: TaskItem) async throws -> RequestWatch.Snapshot {
        guard let record = task.signalTask else { throw ActionUnavailable("The task is no longer the Operator’s.") }
        let signal = record.current.configuration
        var facts = DoneCheck.Facts(); facts.operatorJudged = record.operatorJudged == true
        let empty = RequestWatch.Snapshot(reference: nil, facts: facts, head: nil, localHead: nil, approvals: false, greenChecks: false)
        if signal.finish.doneWhen == .operatorJudges && !signal.finish.mergesWhenReady { return empty }
        let links = await connections()
        if case .ticketStatus = signal.finish.doneWhen {
            let value = try await ticket(task, links: links)
            facts.ticketReadComplete = value != nil; facts.ticketStatus = value?.status
            if !signal.finish.mergesWhenReady { var value = empty; value.facts = facts; return value }
        }
        let (remote, host) = try await binding(task, links: links)
        // A merge watch reads the request and everything about it in one status read; any other condition reads the
        // request alone.
        var status: RequestStatus?, found: MergeRequest?
        if signal.finish.mergesWhenReady { status = try await self.status(task, host: host); found = status?.request }
        else { found = try await request(task, host: host) }
        guard let request = found else { var value = empty; value.facts = facts; return value }
        let reference = SignalRequestRef(remote: remote, number: request.iid)
        if let number = requestNumber(task), number != request.iid { throw ActionUnavailable("The watched request changed.") }
        guard request.sourceBranch == task.branch else { throw ActionUnavailable("The request belongs to another branch.") }
        facts.merged = request.state == "merged"; facts.closed = request.state == "closed"
        // Who it waits on, from the request answer just read: the sidebar's line, never a call of its own.
        facts.reviewers = request.reviewers
        let link = MergeRequestRef(iid: request.iid, title: request.title, url: request.url)
        guard let status else {
            switch signal.finish.doneWhen {
            case .hasReviewer: facts.hasReviewer = request.hasReviewer
            case .approved: facts.approved = try await !host.approvals(of: request.iid).isEmpty
            case .threadsResolved:
                let threads = try await host.threads(of: request.iid)
                facts.threadsResolved = threads.allSatisfy(\.resolved); facts.openThreads = threads.filter { !$0.resolved }.count
            case .myReviewPosted: facts.reviewPostedAt = try await host.myReviewPostedAt(of: request.iid)
            default: break
            }
            facts.hostReadComplete = true
            return RequestWatch.Snapshot(reference: reference, facts: facts, head: nil, localHead: nil, approvals: false, greenChecks: false, link: link)
        }
        let threads = try await host.threads(of: request.iid)
        facts.hostReadComplete = true
        facts.hasReviewer = request.hasReviewer
        facts.approved = !status.approvedBy.isEmpty
        facts.threadsResolved = threads.allSatisfy(\.resolved); facts.openThreads = threads.filter { !$0.resolved }.count
        let readiness = status.readiness
        var head = status.head
        if case .merged(_, let mergedHead, _) = readiness { facts.merged = true; if !mergedHead.isEmpty { head = mergedHead } }
        if signal.finish.doneWhen == .myReviewPosted { facts.reviewPostedAt = try await host.myReviewPostedAt(of: request.iid) }
        let git = git
        let local = try await BackgroundWork.run { try Repository(task.worktreePath, git: git).commit("HEAD") }
        let ready: Bool = if case .ready = readiness { true } else { false }
        return RequestWatch.Snapshot(reference: reference, facts: facts, head: head, localHead: local,
                                     approvals: facts.approved && ready, greenChecks: status.pipeline == "success", link: link, hostReady: ready)
    }
    func merge(_ task: TaskItem, snapshot: RequestWatch.Snapshot) async throws {
        guard let claim = SignalClaim(task), let reference = snapshot.reference, let head = snapshot.head, snapshot.canMerge,
              task.signalTask?.current.configuration.finish.mergesWhenReady == true else { throw ActionUnavailable("Automatic merging is not enabled or ready.") }
        let links = await connections(), (remote, host) = try await binding(task, links: links)
        let git = git
        let local = try await BackgroundWork.run { try Repository(task.worktreePath, git: git).commit("HEAD") }
        guard local == head, local == snapshot.localHead else { throw ActionUnavailable("Its local head changed before merging.") }
        guard enabled(), ItemRef.repository(remote) == ItemRef.repository(reference.remote), claim.allows(in: workspace) else { throw ActionUnavailable("The task changed before merging.") }
        _ = try await host.merge(reference.number, at: head)
    }
    private var detailsCache: [UUID: (claim: SignalClaim?, value: JSONValue, at: Date)] = [:]
    var now: () -> Date = Date.init
    func details(_ task: TaskItem) async throws -> JSONValue {
        let claim = SignalClaim(task)
        let ids = Set(workspace.state.allSignalTasks.map(\.id))
        detailsCache = detailsCache.filter { ids.contains($0.key) }
        if let cached = detailsCache[task.id], cached.claim == claim,
           now().timeIntervalSince(cached.at) < OperatorTiming.hostReadCache { return cached.value }
        let links = await connections()
        let value = try await uncachedDetails(task, links: links)
        guard claim?.holds(in: workspace.state) != false else { throw ActionUnavailable("The task changed while its source was read.") }
        detailsCache[task.id] = (claim: claim, value: value, at: now())
        return value
    }
    private func uncachedDetails(_ task: TaskItem, links: SignalConnections) async throws -> JSONValue {
        var value: [String: JSONValue] = [:]
        if let ticket = try await ticket(task, links: links) { value["ticketDescription"] = ticket.description.map(JSONValue.string) ?? .null }
        if task.mr != nil || task.signalTask?.watchedRequest != nil {
            let (_, host) = try await binding(task, links: links)
            if let request = try await request(task, host: host) { value["requestDescription"] = request.description.map(JSONValue.string) ?? .null }
        }
        return .object(value)
    }
    func additionalContext(_ task: TaskItem) async throws -> String {
        guard let record = task.signalTask else { return "" }
        let signal = record.current.configuration
        let needsTicket: Bool = if case .ticket = record.current.item { false } else { signal.work.ticketDescription }
        let needsRequest: Bool = if case .mergeRequest = record.current.item { false } else { signal.work.requestDescription }
        guard needsTicket || needsRequest else { return "" }
        let links = await connections()
        var related = task
        if needsTicket, related.jira == nil, let jira = links.jira,
           let key = TicketMergeRequests.jiraKey(in: task.branch),
           workspace.state.project(id: task.projectId)?.jiraProjects.contains(where: {
               key.hasPrefix($0.key.uppercased() + "-") && $0.siteURL == jira.siteURL
           }) == true {
            related.jira = JiraRef(key: key, summary: "", url: jira.siteURL.appendingPathComponent("browse/" + key).absoluteString)
        }
        let ticketText = needsTicket ? try await ticket(related, links: links)?.description : nil
        var requestText: String?
        if needsRequest {
            let known = task.mr != nil || record.watchedRequest != nil
            let available = workspace.state.project(id: task.projectId)?.remoteUrl.map { remote in
                switch ProviderDetector.detect(remoteUrl: remote).provider {
                case .gitlab: links.gitLab != nil
                case .github: links.gitHub != nil
                default: false
                }
            } ?? false
            if known || available {
                let (_, host) = try await binding(task, links: links)
                requestText = try await request(task, host: host)?.description
            }
        }
        return SignalWork(prompt: "", ticketDescription: needsTicket, requestDescription: needsRequest).workerPrompt(ticket: ticketText, request: requestText)
    }
    func deleteMergedBranch(of task: TaskItem) async {
        guard enabled(), let record = task.signalTask, record.current.configuration.finish.deletesMergedBranch,
              task.kind != .review, workspace.state.signalItem(id: task.id) == nil,
              let project = workspace.state.project(id: task.projectId) else { return }
        do {
            let links = await connections(), (_, host) = try await binding(task, links: links)
            guard let status = try await status(task, host: host),
                  case .merged(_, let head, _) = status.readiness, !head.isEmpty,
                  task.branch != (try await host.defaultBranch()),
                  !workspace.state.tasks.contains(where: { $0.projectId == task.projectId && $0.branch == task.branch }) else { return }
            _ = await MergedBranchCheck.delete(branch: task.branch, acceptedSHA: head, mergedHead: head,
                kind: task.kind, path: project.path, git: git, saveDeletion: { [workspace] in
                    self.enabled() && workspace.canChangeWorkspace && workspace.state.operatorSession?.paused != true
                        && workspace.state.signal(id: record.current.signal)?.enabled != false
                        && workspace.state.signalItem(id: task.id) == nil
                        && !workspace.state.tasks.contains { $0.projectId == task.projectId && $0.branch == task.branch }
                        && workspace.flush()
                })
        } catch { /* An unavailable merge proof keeps the branch. */ }
    }
}
