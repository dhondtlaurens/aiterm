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
    private func binding(_ task: TaskItem, links: SignalConnections) async throws -> (String, any SignalHostReading) {
        guard let project = workspace.state.project(id: task.projectId), let saved = project.remoteUrl else { throw ActionUnavailable("Its project has no connected remote.") }
        let current = try await remote(project, task)
        guard let repository = ItemRef.repository(current), repository == ItemRef.repository(saved) else { throw ActionUnavailable("Its origin changed; check the project's repository before continuing.") }
        let references = [task.signalTask?.watchedRequest?.remote, task.signalTask.flatMap { record -> String? in if case .mergeRequest(let ref) = record.item { return ref.remote }; return nil }].compactMap { $0 }
        guard references.allSatisfy({ ItemRef.repository($0) == repository }) else {
            throw ActionUnavailable("The saved request belongs to another repository.")
        }
        if let mr = task.mr {
            var ordinary = task; ordinary.signalTask = nil
            guard MatchDecision.matchesItem(.request(remote: current, number: mr.iid), task: ordinary) else {
                throw ActionUnavailable("The request link belongs to another repository.")
            }
        }
        let host = try MergeRequestSearch.signalSource(for: ProviderDetector.detect(remoteUrl: current), gitLab: links.gitLab, gitHub: links.gitHub, session: links.session)
        return (current, host)
    }
    private func request(_ task: TaskItem, host: any SignalHostReading) async throws -> MergeRequest? {
        if let number = task.signalTask?.watchedRequest?.number ?? task.mr?.iid {
            return try await host.mergeRequests(search: String(number)).first { $0.iid == number }
        }
        return try await host.existingRequest(from: task.branch)
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
        guard let record = task.signalTask, let signal = record.configuration ?? workspace.state.signal(id: record.signal) else { throw ActionUnavailable("Its signal is missing.") }
        var facts = DoneCheck.Facts()
        let empty = RequestWatch.Snapshot(reference: nil, facts: facts, head: nil, localHead: nil, approvals: false, greenChecks: false)
        if signal.finish.doneWhen == .operatorJudges && !signal.finish.mergesWhenReady { return empty }
        let links = await connections()
        if case .ticketStatus = signal.finish.doneWhen {
            let value = try await ticket(task, links: links)
            facts.ticketReadComplete = value != nil; facts.ticketStatus = value?.status
            if !signal.finish.mergesWhenReady { var value = empty; value.facts = facts; return value }
        }
        let (remote, host) = try await binding(task, links: links)
        guard let request = try await request(task, host: host) else { var value = empty; value.facts = facts; return value }
        let reference = SignalRequestRef(remote: remote, number: request.iid)
        if let saved = record.watchedRequest, ItemRef.request(remote: remote, number: request.iid).identity != ItemRef.mergeRequest(saved).identity {
            throw ActionUnavailable("The watched request belongs to another repository.")
        }
        let state = try await host.state(of: request)
        let readiness = try await host.readiness(of: request.iid)
        let threads = try await host.threads(of: request.iid)
        facts.hostReadComplete = true
        facts.hasReviewer = try await !host.signalReviewers(of: request.iid).isEmpty
        facts.approved = !state.approvedBy.isEmpty
        facts.threadsResolved = threads.allSatisfy(\.resolved)
        facts.closed = request.state == "closed"
        var head = state.head
        if case .merged(_, let mergedHead, _) = readiness { facts.merged = true; if !mergedHead.isEmpty { head = mergedHead } }
        if signal.finish.doneWhen == .myReviewPosted { facts.reviewPostedAt = try await host.mySignalReviewPostedAt(of: request.iid) }
        let git = git
        let local = try await BackgroundWork.run { try Repository(task.worktreePath, git: git).commit("HEAD") }
        let ready: Bool = if case .ready = readiness { true } else { false }
        return RequestWatch.Snapshot(reference: reference, facts: facts, head: head, localHead: local,
                                     approvals: facts.approved && ready, greenChecks: state.pipeline == "success")
    }
    func merge(_ task: TaskItem, snapshot: RequestWatch.Snapshot) async throws {
        guard let claim = SignalClaim(task), let reference = snapshot.reference, let head = snapshot.head, snapshot.canMerge,
              task.signalTask?.configuration?.finish.mergesWhenReady == true else { throw ActionUnavailable("Automatic merging is not enabled or ready.") }
        let links = await connections(), (remote, host) = try await binding(task, links: links)
        guard enabled(), ItemRef.repository(remote) == ItemRef.repository(reference.remote), workspace.canChangeWorkspace,
              workspace.state.operatorSession?.paused != true, claim.holds(in: workspace.state), !Task.isCancelled else { throw ActionUnavailable("The task changed before merging.") }
        _ = try await host.merge(reference.number, at: head)
    }
    func details(_ task: TaskItem) async throws -> JSONValue {
        let links = await connections()
        var value: [String: JSONValue] = [:]
        if let ticket = try await ticket(task, links: links) { value["ticketDescription"] = ticket.description.map(JSONValue.string) ?? .null }
        if task.mr != nil || task.signalTask?.watchedRequest != nil {
            let (_, host) = try await binding(task, links: links)
            if let request = try await request(task, host: host) { value["requestDescription"] = request.description.map(JSONValue.string) ?? .null }
        }
        return .object(value)
    }
    func additionalContext(_ task: TaskItem) async throws -> String {
        guard let record = task.signalTask, let signal = record.configuration ?? workspace.state.signal(id: record.signal) else { return "" }
        let needsTicket: Bool = if case .ticket = record.item { false } else { signal.work.ticketDescription && task.jira != nil }
        let needsRequest: Bool = if case .mergeRequest = record.item { false } else { signal.work.requestDescription && task.mr != nil }
        guard needsTicket || needsRequest else { return "" }
        let links = await connections()
        let ticketText = needsTicket ? try await ticket(task, links: links)?.description : nil
        var requestText: String?
        if needsRequest { let (_, host) = try await binding(task, links: links); requestText = try await request(task, host: host)?.description }
        return SignalWork(prompt: "", ticketDescription: needsTicket, requestDescription: needsRequest).workerPrompt(ticket: ticketText, request: requestText)
    }
    func deleteMergedBranch(of task: TaskItem) async {
        guard let record = task.signalTask, let signal = record.configuration, signal.finish.deletesMergedBranch,
              task.kind != .review, workspace.state.signalItem(id: task.id) == nil,
              let project = workspace.state.project(id: task.projectId) else { return }
        do {
            let links = await connections(), (_, host) = try await binding(task, links: links)
            guard let request = try await request(task, host: host),
                  case .merged(_, let head, _) = try await host.readiness(of: request.iid), !head.isEmpty,
                  task.branch != (try await host.defaultBranch()),
                  !workspace.state.tasks.contains(where: { $0.projectId == task.projectId && $0.branch == task.branch }) else { return }
            let publication = TaskPublication(merged: true, mergedHead: head)
            _ = await MergedBranchCheck.delete(branch: task.branch, acceptedSHA: head, end: .merge,
                publication: publication, kind: task.kind, path: project.path, git: git, saveDeletion: { [workspace] in
                    workspace.canChangeWorkspace && workspace.state.signalItem(id: task.id) == nil && workspace.flush()
                })
        } catch { /* An unavailable merge proof keeps the branch. */ }
    }
}
