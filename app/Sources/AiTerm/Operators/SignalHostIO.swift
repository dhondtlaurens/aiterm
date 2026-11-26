import Foundation
import AiTermCore

/// Binds Done and merge reads to the connected repository. Only the explicit, rechecked merge effect
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
            var ordinary = task; ordinary.signalTask = nil; ordinary.signalOrigin = nil
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
            jql: JiraQueryReader.ticket(ref.key)).poll(since: nil, full: true)
        guard read.complete else { throw IncompleteRead("ticket") }
        return read.items.compactMap(\.ticket).first { $0.key.caseInsensitiveCompare(ref.key) == .orderedSame }
    }
    /// Whether the task has a merge request AiTerm can read: one it knows, or its project's host is connected.
    private func requestReadable(_ task: TaskItem, links: SignalConnections) -> Bool {
        if task.mr != nil || task.signalTask?.watchedRequest != nil { return true }
        if case .mergeRequest = task.signalTask?.current.item { return true }
        return workspace.state.project(id: task.projectId)?.remoteUrl.map { remote in
            switch ProviderDetector.detect(remoteUrl: remote).provider {
            case .gitlab: links.gitLab != nil
            case .github: links.gitHub != nil
            default: false
            }
        } ?? false
    }
    /// The task's merge request on its own branch, by its known number, else by the branch; nil when it has none.
    private func ownRequest(_ task: TaskItem, host: any HostRepository) async throws -> MergeRequest? {
        guard let request = try await request(task, host: host) else { return nil }
        if let number = requestNumber(task), number != request.iid { throw ActionUnavailable("The watched request changed.") }
        guard request.sourceBranch == task.branch else { throw ActionUnavailable("The request belongs to another branch.") }
        return request
    }
    /// The merge request as its account names it: the matched item, else its number under the origin's repository on
    /// the account's host.
    private func accountReference(_ item: ItemRef?, number: Int, origin: String, source: SignalTrigger.Source, links: SignalConnections) throws -> SignalRequestRef {
        if case .mergeRequest(let item) = item, item.number == number { return item }
        guard let remote = RemoteURL(origin), let host = remote.host, !remote.path.isEmpty else { throw ActionUnavailable("Its origin is not a repository URL.") }
        switch source {
        case .gitLab:
            guard let gitLab = links.gitLab, gitLab.matches(remoteHost: host) else { throw ActionUnavailable("Its merge request is not on the connected GitLab.") }
            var base = gitLab.hostURL.absoluteString
            while base.hasSuffix("/") { base.removeLast() }
            return SignalRequestRef(remote: base + "/" + remote.path, number: number)
        case .gitHub:
            guard host.lowercased() == "github.com" else { throw ActionUnavailable("Its pull request is not on GitHub.") }
            return SignalRequestRef(remote: "https://github.com/" + remote.path, number: number)
        case .jira, .schedule, .operator, .person: throw ActionUnavailable("Only a GitLab or GitHub trigger reads a merge request.")
        }
    }
    /// Whether `done`'s query matches the task's own item now: for Jira, its ticket (a merge request task's from the key
    /// in its branch or title); for GitLab or GitHub, its merge request (`request`, found by the caller), named as the
    /// matched `item` names it. No ticket or no merge request means it does not match. An Operator Done never matches:
    /// the Operator's `finish_stage(done)` ends it. Nor does a Done the person decides: it has no query to ask.
    private func doneMatches(_ task: TaskItem, done: SignalTrigger, item: ItemRef?, request: MergeRequest?, origin: String?,
                             links: SignalConnections) async throws -> Bool {
        switch done.source {
        case .operator, .person: return false
        case .jira:
            let own = task.jira.flatMap { $0.source == .jira ? $0.key : nil }
            guard let key = own ?? TicketMergeRequests.jiraKey(in: task.branch) ?? TicketMergeRequests.jiraKey(in: task.title) else { return false }
            guard let jira = links.jira else { throw ActionUnavailable("Connect Jira in Settings to read this Done trigger.") }
            // The task's own ticket is read only on the site it came from; a key found in a branch or title has no site.
            if let ref = task.jira, ref.source == .jira, !ref.url.hasPrefix(jira.siteURL.absoluteString + "/") {
                throw ActionUnavailable("The ticket belongs to another Jira connection.")
            }
            let read = try await JiraQueryReader(client: JiraClient(config: jira, session: links.session),
                jql: JiraQueryReader.ticket(key, matching: done.query)).poll(since: nil, full: true)
            guard read.complete else { throw IncompleteRead("Done trigger") }
            return read.items.contains { $0.ticket?.key.caseInsensitiveCompare(key) == .orderedSame }
        case .gitLab:
            guard let gitLab = links.gitLab else { throw ActionUnavailable("Connect GitLab in Settings to read this Done trigger.") }
            guard let request, let origin else { return false }
            let reference = try accountReference(item, number: request.iid, origin: origin, source: .gitLab, links: links)
            return try await GitLabAccount(config: gitLab, session: links.session).matches(try GitLabQuery.done(done.query), request: reference, branch: task.branch)
        case .gitHub:
            guard let gitHub = links.gitHub else { throw ActionUnavailable("Connect GitHub in Settings to read this Done trigger.") }
            guard let request, let origin else { return false }
            let reference = try accountReference(item, number: request.iid, origin: origin, source: .gitHub, links: links)
            return try await GitHubAccount(config: gitHub, session: links.session).matches(try GitHubQuery.done(done.query), request: reference, branch: task.branch)
        case .schedule: throw ActionUnavailable("A schedule can only start a signal.")
        }
    }
    /// Whether the task's own branch has an open merge request on its host now, found by its known number or by the
    /// branch, for an agreed Operator done to wait for merge when ready. A host AiTerm cannot read, or a read that fails,
    /// throws: it could hold a request merge when ready still has to merge.
    func hasOpenRequest(_ task: TaskItem) async throws -> Bool {
        let links = await connections()
        guard requestReadable(task, links: links) else {
            throw ActionUnavailable("Merge it when it’s ready is on, but AiTerm can’t read its project’s host. Connect it in Settings, or switch the merge off.")
        }
        let (_, host) = try await binding(task, links: links)
        guard let request = try await ownRequest(task, host: host) else { return false }
        return request.state == "opened" || request.state == "open"
    }
    /// The baseline a stage's done edge is read against, before its worker launches.
    func doneMatches(_ task: TaskItem) async throws -> Bool {
        guard let record = task.signalTask else { throw ActionUnavailable("The task is no longer the Operator’s.") }
        let done = record.current.configuration.done
        if done.source == .operator || done.source == .person { return false }
        let links = await connections()
        var request: MergeRequest?, origin: String?
        if done.source != .jira, requestReadable(task, links: links) {
            let (current, host) = try await binding(task, links: links)
            request = try await ownRequest(task, host: host); origin = current
        }
        return try await doneMatches(task, done: done, item: record.current.item, request: request, origin: origin, links: links)
    }
    /// A project signal's Done read for its task: the task's own request (by its known number, else by its branch, as a
    /// scheduled run's item names no request), whether it merged or closed, and whether `done`'s query matches `item`
    /// now. A merged or closed request is done even when the query cannot be read. A Done the person decides asks no
    /// query; with it, or a Jira Done, a code host that cannot be read leaves merged and closed unknown.
    func doneFacts(for task: TaskItem, done: SignalTrigger, item: ItemRef) async throws -> DoneCheck.Facts {
        let links = await connections()
        var facts = DoneCheck.Facts()
        var found: MergeRequest?, origin: String?
        if requestReadable(task, links: links) {
            // A changed repository is refused whatever the Done source; only reading the host may fail quietly.
            let (current, host) = try await binding(task, links: links)
            do {
                found = try await ownRequest(task, host: host); origin = current
                facts.merged = found?.state == "merged"; facts.closed = found?.state == "closed"
            } catch {
                guard done.source == .jira || done.source == .person else { throw error }
                found = nil; origin = nil
            }
        }
        do { facts.doneMatches = try await doneMatches(task, done: done, item: item, request: found, origin: origin, links: links) }
        catch { guard facts.merged || facts.closed else { throw error } }
        return facts
    }
    /// One host watch read: the stage's Done trigger against its own item, and its merge request where it has one,
    /// with everything a merge needs when merge when ready may merge it.
    func read(_ task: TaskItem) async throws -> RequestWatch.Snapshot {
        guard let record = task.signalTask else { throw ActionUnavailable("The task is no longer the Operator’s.") }
        let merges = record.current.configuration.finish.mergesWhenReady && task.kind != .review
        let links = await connections()
        var snapshot = RequestWatch.Snapshot(reference: nil, facts: DoneCheck.Facts(), head: nil, localHead: nil, approvals: false, greenChecks: false)
        var found: MergeRequest?, origin: String?
        // With a Jira Done trigger and no merge, the request only says merged or closed: a code host that cannot be
        // read leaves that unknown rather than stopping the Jira check.
        let requestOptional = !merges && [.jira, .operator, .person].contains(record.current.configuration.done.source)
        if requestReadable(task, links: links) {
            // A changed repository is refused whatever the Done source; only reading the host may fail quietly.
            let (current, host) = try await binding(task, links: links)
            do {
                origin = current
                // A merge watch reads the request and everything about it in one status read; otherwise the request alone.
                var status: RequestStatus?
                if merges { status = try await self.status(task, host: host); found = status?.request }
                else { found = try await ownRequest(task, host: host) }
                if let request = found {
                    if merges {
                        if let number = requestNumber(task), number != request.iid { throw ActionUnavailable("The watched request changed.") }
                        guard request.sourceBranch == task.branch else { throw ActionUnavailable("The request belongs to another branch.") }
                    }
                    snapshot.reference = SignalRequestRef(remote: current, number: request.iid)
                    snapshot.link = MergeRequestRef(iid: request.iid, title: request.title, url: request.url)
                    snapshot.facts.merged = request.state == "merged"; snapshot.facts.closed = request.state == "closed"
                    if let status {
                        let threads = try await host.threads(of: request.iid)
                        snapshot.facts.hostReadComplete = true
                        snapshot.facts.approved = !status.approvedBy.isEmpty
                        snapshot.facts.threadsResolved = threads.allSatisfy(\.resolved)
                        var head = status.head
                        if case .merged(let commit, let mergedHead, _) = status.readiness {
                            snapshot.facts.merged = true; snapshot.mergeCommit = commit.isEmpty ? nil : commit
                            if !mergedHead.isEmpty { head = mergedHead }
                        }
                        let git = git
                        let local = try await BackgroundWork.run { try Repository(task.worktreePath, git: git).commit("HEAD") }
                        let ready: Bool = if case .ready = status.readiness { true } else { false }
                        snapshot.head = head; snapshot.localHead = local
                        snapshot.approvals = snapshot.facts.approved && ready; snapshot.greenChecks = status.pipeline == "success"; snapshot.hostReady = ready
                    }
                }
            } catch {
                guard requestOptional else { throw error }
                found = nil; origin = nil
                snapshot = RequestWatch.Snapshot(reference: nil, facts: DoneCheck.Facts(), head: nil, localHead: nil, approvals: false, greenChecks: false)
            }
        }
        // Merged or closed is done whatever the Done query says, so a Done query that cannot be read does not hide it.
        do {
            snapshot.facts.doneMatches = try await doneMatches(task, done: record.current.configuration.done, item: record.current.item,
                                                               request: found, origin: origin, links: links)
        }
        catch { guard snapshot.facts.merged || snapshot.facts.closed else { throw error } }
        return snapshot
    }
    /// Merges at the snapshot's head after checking the binding, the local head and the claim, and returns the host's
    /// answer. `intend` runs after those checks with no await before the host call, so it saves only a merge that is sent.
    func merge(_ task: TaskItem, snapshot: RequestWatch.Snapshot, intend: @MainActor () throws -> Void = {}) async throws -> MergeReadiness {
        guard let claim = SignalClaim(task), let reference = snapshot.reference, let head = snapshot.head, snapshot.canMerge, task.kind != .review,
              task.signalTask?.current.configuration.finish.mergesWhenReady == true else { throw ActionUnavailable("Automatic merging is not enabled or ready.") }
        let links = await connections(), (remote, host) = try await binding(task, links: links)
        let git = git
        let local = try await BackgroundWork.run { try Repository(task.worktreePath, git: git).commit("HEAD") }
        guard local == head, local == snapshot.localHead else { throw ActionUnavailable("Its local head changed before merging.") }
        guard enabled(), ItemRef.repository(remote) == ItemRef.repository(reference.remote), claim.allows(in: workspace) else { throw ActionUnavailable("The task changed before merging.") }
        try intend()
        return try await host.merge(reference.number, at: head)
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
        // A scheduled run has no ticket or merge request to describe.
        if signal.isScheduled { return "" }
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
