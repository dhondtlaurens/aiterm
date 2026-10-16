import Foundation

/// Carries out an accepted task's end (spec §6, `finish_task`), from wherever its publication
/// stands, as far as it goes without waiting:
///
/// 1. push the accepted commit to the task's own branch;
/// 2. find the open request from that branch, or open one — a draft for a draft-MR end, a plain
///    request for a merge end — into the default branch, or a stacked task's parent's branch;
/// 3. a merge end only: wait for a stacked parent's merge, then retarget to the default branch; ask
///    the host whether it can merge, and merge at the accepted commit once it has said so twice,
///    `OperatorTiming.mergePoll` apart, and the request still targets the default branch.
///
/// Before the push the host is asked whether it protects the branch: protected, or no answer, and
/// nothing is pushed. Each completed step is handed to `record`, which saves it before the next starts,
/// so a repeat resumes at the next step — and a step that cannot be saved is the last. Before each step
/// that changes something outside this machine, and right after looking for an open request, `recheck`
/// must still answer nil (the operation running, the task accepted on the same commit and still the
/// operator's) or the publisher stops there. One advance per task runs at a time (the caller's
/// in-flight registry); any partial run may be followed by another.
public struct TaskPublisher: Sendable {
    public struct Context: Sendable {
        public var task: TaskItem, run: OperatorRun, parent: TaskItem?
        public init(task: TaskItem, run: OperatorRun, parent: TaskItem?) { self.task = task; self.run = run; self.parent = parent }
    }

    public enum Outcome: Equatable, Sendable {
        case refused(String)
        /// The end is carried out: a draft opened, or merged.
        case published(TaskPublication)
        /// A merge end, opened, waiting for the host or the parent.
        case waiting(TaskPublication, String)
        /// A merge end the host will not merge without someone acting, or the wait ran out.
        case blocked(TaskPublication, String)
    }

    /// A push that ran out of time. Only git is killed at the deadline — a pre-push hook or ssh can
    /// outlive it — so the commit may be on origin: the next advance asks origin before pushing again.
    public struct PushTimedOut: Error, Equatable, LocalizedError {
        public let branch: String
        public var errorDescription: String? {
            "The push of \(branch) timed out and may have landed on origin; finish_task asks origin before it pushes again."
        }
    }

    /// A first ready read counts for this long: one older is a first read again.
    static let readyCountsFor = 3 * OperatorTiming.mergePoll

    /// Why a merge end the host first called mergeable is not merged yet: its pipelines may not have registered.
    static let confirming = "the host calls it mergeable; AiTerm asks once more in \(Int(OperatorTiming.mergePoll)) seconds before it merges, in case its pipelines had not started"

    let repository: Repository
    let host: any MergeRequestPublishing
    let now: @Sendable () -> Date

    public init(repository: Repository, host: any MergeRequestPublishing, now: @escaping @Sendable () -> Date = Date.init) {
        self.repository = repository; self.host = host; self.now = now
    }

    public func advance(_ context: Context, restart: Bool,
                        recheck: @escaping @Sendable () async -> String?,
                        record: @escaping @Sendable (TaskPublication) async throws -> Void) async throws -> Outcome {
        let task = context.task, branch = task.branch, repository = self.repository
        guard let operated = task.operated else { return .refused(PublicationGuard.notOperated) }
        var publication = operated.publication ?? TaskPublication()
        // A repeat of what is done answers what was done, whatever has changed since.
        if operated.state == .published || publication.merged { return .published(publication) }
        if publication.mergedSHA != nil {
            return .blocked(publication, publication.problem ?? Self.mergedUnaccepted(operated.key, publication))
        }

        let (defaultBranch, tip) = try await BackgroundWork.run { (repository.defaultBranch(), try repository.tip(of: branch)) }
        if let refusal = PublicationGuard.refusal(task: task, run: context.run, parent: context.parent,
                                                  defaultBranch: defaultBranch, branchTip: tip) {
            return .refused(refusal)
        }
        guard let acceptance = operated.acceptance else { return .refused(PublicationGuard.notOperated) }
        let sha = acceptance.resultSHA
        let parentMerged = context.parent?.operated?.publication?.merged == true
        // Nothing builds on a parent merged outside its accepted publication.
        if let parent = context.parent?.operated, !parentMerged, parent.publication?.mergedSHA != nil {
            let reason = parent.publication?.problem ?? "\(parent.key) was merged on the host with commits that weren't accepted"
            return try await blocked(publication, "\(reason): AiTerm publishes nothing on top of it.", record)
        }

        if restart, publication.problem != nil || publication.waitingSince != nil {
            publication.problem = nil
            publication.waitingSince = nil
            try await record(publication)
        }

        // 1 · Push the accepted commit — never to a branch the host protects, nor one it cannot vouch for.
        if publication.pushedSHA != sha {
            let protection: BranchProtection
            do { protection = try await host.protection(of: branch) }
            catch {
                return .refused("AiTerm couldn’t tell whether \(branch) is protected on the host, so it pushed nothing: \(error.localizedDescription)")
            }
            if case .protected(let why) = protection {
                return .refused("\(branch) is protected on the host (\(why)): AiTerm never pushes to a protected branch.")
            }
            // An earlier push that timed out may have landed: if origin has the commit, it is not pushed again.
            if try await BackgroundWork.run({ try repository.originTip(of: branch) }) != sha {
                if let why = await recheck() { return .refused(why) }
                do { try await BackgroundWork.run { try repository.push(sha, as: branch, defaultBranch: defaultBranch) } }
                catch let refusal as PublishRefusal { return .refused(refusal.localizedDescription) }
                catch let error as GitError where error.timedOut { throw PushTimedOut(branch: branch) }
            }
            publication.pushedSHA = sha
            publication.readySince = nil
            try await record(publication)
        }

        // 2 · The request: the one already open from the branch, else a new one.
        let number: Int
        if let recorded = publication.mergeRequestNumber {
            number = recorded
        } else {
            let target = Self.target(parent: context.parent, parentMerged: parentMerged, defaultBranch: defaultBranch)
            if let why = await recheck() { return .refused(why) }
            let open = try await host.existingRequest(from: branch)
            // The look took a while: right before opening one, the task must still be the operator's.
            if let why = await recheck() { return .refused(why) }
            let request: MergeRequest
            if let open {
                // One into another branch is never used as it is. One into the parent's branch opened
                // before the parent merged is AiTerm's own: a merge end retargets it in step 3.
                let openedEarlier = parentMerged && open.targetBranch == context.parent?.branch
                guard open.targetBranch == target || openedEarlier else {
                    return .refused("\(branch) already has an open request into \(open.targetBranch), not \(target): \(open.url). AiTerm never publishes through it as it is: retarget it to \(target) or close it, then call finish_task again.")
                }
                request = open
            } else {
                request = try await host.createRequest(from: branch, into: target,
                                                       title: Self.title(of: task),
                                                       description: Self.description(of: task, run: context.run, acceptance: acceptance),
                                                       draft: operated.end == .draftMR)
            }
            number = request.iid
            publication.mergeRequestNumber = request.iid
            publication.mergeRequestURL = request.url
            publication.targetBranch = request.targetBranch
            publication.readySince = nil
            try await record(publication)
        }
        guard operated.end == .merge else { return .published(publication) }

        // 3 · Merge: after a stacked parent's merge, onto the default branch, once the host can.
        if publication.waitingSince == nil {
            publication.waitingSince = now()
            try await record(publication)
        }
        if let parent = context.parent {
            guard parentMerged else {
                return try await waiting(publication, "waiting for \(parent.operated?.key ?? parent.title) to merge first", record)
            }
            if publication.targetBranch != defaultBranch {
                if let why = await recheck() { return .refused(why) }
                try await host.retarget(number, to: defaultBranch)
                publication.targetBranch = defaultBranch
                publication.readySince = nil
                try await record(publication)
            }
        }
        let answer = try await host.readiness(of: number)
        guard case .ready(let head) = answer else { return try await settle(answer, sha: sha, key: operated.key, branch: branch, expectedTarget: defaultBranch, publication, record) }
        guard head == sha else {
            publication.readySince = nil
            return try await blocked(publication, "The request's branch is at \(head.prefix(7)) on the host, not the accepted \(sha.prefix(7)).", record)
        }
        // Never on the first ready: GitHub with no checks yet, GitLab with no pipeline yet, read ready.
        // A first read long ago — before a pause, a quit, hours unpolled — is a first read again.
        guard let since = publication.readySince, now().timeIntervalSince(since) <= Self.readyCountsFor else {
            if let waited = publication.waitingSince, now().timeIntervalSince(waited) >= OperatorTiming.mergeWait {
                publication.readySince = nil
                return try await blocked(publication, "Still not mergeable after \(Int(OperatorTiming.mergeWait / 60)) minutes: the host called it mergeable only once the wait had run out, too late to read it twice.", record)
            }
            publication.readySince = now()
            try await record(publication)
            return .waiting(publication, Self.confirming)
        }
        guard now().timeIntervalSince(since) >= OperatorTiming.mergePoll else { return .waiting(publication, Self.confirming) }
        if let why = await recheck() { return .refused(why) }
        // The recorded target is what AiTerm last set; someone may have retargeted it on the host
        // since, and a host merges into the request's target as it is now.
        let url = publication.mergeRequestURL ?? "#\(number)"
        let live = try await host.existingRequest(from: branch)
        guard let live, live.iid == number else {
            publication.readySince = nil
            let found = live.map { "\(branch)'s open request on the host is \($0.url) now, not \(url)" } ?? "The request \(url) is no longer open on the host"
            return try await blocked(publication, "\(found), so AiTerm did not merge it.", record)
        }
        guard live.targetBranch == defaultBranch else {
            publication.readySince = nil
            return try await blocked(publication, "The request \(url) targets \(live.targetBranch) on the host now, not \(defaultBranch): AiTerm never merges it there. Retarget it to \(defaultBranch), then call finish_task again.", record)
        }
        if let why = await recheck() { return .refused(why) }
        return try await settle(try await host.merge(number, at: sha), sha: sha, key: operated.key, branch: branch, expectedTarget: defaultBranch, publication, record, verifiedTarget: live.targetBranch)
    }

    /// What a readiness read that is not ready, or a merge's answer, makes of the publication. Any
    /// answer but merged means the next ready is a first one again. Merged with another head than the
    /// accepted `sha`, or into another target, is recorded as it happened and is no published end.
    private func settle(_ answer: MergeReadiness, sha: String, key: String, branch: String, expectedTarget: String, _ publication: TaskPublication,
                        _ record: @Sendable (TaskPublication) async throws -> Void, verifiedTarget: String? = nil) async throws -> Outcome {
        var publication = publication
        let wasReady = publication.readySince != nil
        publication.readySince = nil
        switch answer {
        case .merged(let commit, let head, let target):
            publication.mergedSHA = commit
            publication.mergedHead = head
            let liveTarget: String?
            if let target = target ?? verifiedTarget { liveTarget = target }
            else {
                let live = try? await host.existingRequest(from: branch)
                liveTarget = live?.iid == publication.mergeRequestNumber ? live?.targetBranch : nil
            }
            publication.targetBranch = liveTarget
            guard head == sha else { return try await blocked(publication, Self.mergedUnaccepted(key, publication), record) }
            guard liveTarget == expectedTarget else {
                return try await blocked(publication, "\(key) was merged on the host into \(liveTarget ?? "an unknown branch"), not \(expectedTarget): AiTerm does not count it as the task’s merge.", record)
            }
            publication.merged = true
            publication.problem = nil
            try await record(publication)
            return .published(publication)
        case .blocked(let why):
            return try await blocked(publication, why, record)
        case .waiting(let why):
            if wasReady { try await record(publication) }
            return try await waiting(publication, why, record)
        case .ready:
            if wasReady { try await record(publication) }
            return try await waiting(publication, "the host has not merged it yet", record)
        }
    }

    private func blocked(_ publication: TaskPublication, _ why: String,
                         _ record: @Sendable (TaskPublication) async throws -> Void) async throws -> Outcome {
        var publication = publication
        publication.problem = why
        try await record(publication)
        return .blocked(publication, why)
    }

    /// Still waiting — unless the wait has run out, which is a problem with the last reason given.
    private func waiting(_ publication: TaskPublication, _ why: String,
                         _ record: @Sendable (TaskPublication) async throws -> Void) async throws -> Outcome {
        if let since = publication.waitingSince, now().timeIntervalSince(since) >= OperatorTiming.mergeWait {
            return try await blocked(publication, "Still not mergeable after \(Int(OperatorTiming.mergeWait / 60)) minutes: \(why).", record)
        }
        return .waiting(publication, why)
    }

    /// Where the task's request goes: the default branch, or a stacked task's parent's branch until
    /// the parent has merged — then the default branch, where a merge end's retarget would take it,
    /// as the parent's branch may be gone from the host.
    static func target(parent: TaskItem?, parentMerged: Bool, defaultBranch: String) -> String {
        guard let parent, !parentMerged else { return defaultBranch }
        return parent.branch
    }

    /// Why a request the host merged with another head than the accepted one is not this task's end.
    static func mergedUnaccepted(_ key: String, _ publication: TaskPublication) -> String {
        let head = publication.mergedHead.map { $0.isEmpty ? "a head it didn't name" : String($0.prefix(7)) } ?? "a head it didn't name"
        return "\(key) was merged on the host at \(head), not the accepted \(publication.pushedSHA.map { String($0.prefix(7)) } ?? "commit"): it holds commits that weren't accepted."
    }

    /// The request's title: the task's, after its ticket key unless it already starts with it.
    static func title(of task: TaskItem) -> String {
        guard let key = task.jira?.key, !task.title.hasPrefix(key) else { return task.title }
        return "\(key) \(task.title)"
    }

    /// The request's description: the task's brief, who opened it, and the worker's check output.
    static func description(of task: TaskItem, run: OperatorRun, acceptance: TaskAcceptance) -> String {
        var lines = [task.operated?.brief ?? task.title, "", "Opened by AiTerm for \(run.persona.name)'s operation “\(run.name)”."]
        if let note = acceptance.note, !note.isEmpty { lines += ["", note] }
        if !acceptance.checkOutput.isEmpty {
            lines += ["", "Checks run by the agent:", "```", String(acceptance.checkOutput.suffix(4000)), "```"]
        }
        return lines.joined(separator: "\n")
    }
}
