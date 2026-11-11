import Foundation
import Synchronization
import AiTermCore

/// A code host for finish_task's tests: every call recorded as a line in `log`, in the order the
/// calls were made, readiness answered from a script in order (the last answer repeats), and a
/// request it opened kept, as a real host keeps it — so a repeat after a lost reply finds it.
final class FakeMergeHost: MergeRequestPublishing {
    struct Script: Sendable {
        /// The branches the host protects, and why.
        var protected: [String: String] = [:]
        /// The host cannot say what it protects.
        var protectionFails = false
        /// Thrown by the protection check instead: a host's own error, a GitLab or GitHub one.
        var protectionError: (any Error)?
        /// Awaited inside a create, after it is logged: a test holds a create in flight with it.
        var beforeCreate: (@Sendable () async -> Void)?
        var existing: MergeRequest?
        /// Thrown by `existingRequest(from:)` instead, after it is logged: a host that can't say what is open now.
        var existingError: (any Error)?
        /// Awaited inside `existingRequest(from:)` after it is logged: a test holds the read in flight with it.
        var beforeExisting: (@Sendable () async -> Void)?
        var readiness: [MergeReadiness] = [.waiting("its pipeline is running")]
        /// Once the host has marked the request ready, reading its readiness fails (a timeout on the way).
        var readinessFailsAfterReady = false
        /// The next this many readiness reads fail (a timeout on the way), one fewer each read.
        var readinessFailures = 0
        /// Awaited inside a readiness read, after it is logged: a test holds a merge watch's poll in flight with it.
        var beforeReadiness: (@Sendable () async -> Void)?
        /// The merge's answer; nil: merged as `5eed5eed`, at the commit it was asked to merge.
        var merge: MergeReadiness?
        /// The create fails before the host has it (a timeout on the way there).
        var createFails = false
        /// The host opens it, then the answer is lost.
        var loseCreateReply = false
        /// What the host says of the request (`state(of:)`); nil: built from `existing` (its draft flag) and `approvals`.
        var state: MergeRequestState?
        /// Thrown by `state(of:)` instead, or awaited inside it after it is logged: a host that errors, or never answers.
        var stateError: (any Error)?
        var beforeState: (@Sendable () async -> Void)?
        /// The request's review threads and approvals, as the Review slice reads them.
        var threads: [ReviewThread] = []
        var approvals: [String] = []
        /// The host replaces this list after its read, just as GitLab does.
        var reviewers: [String] = []
        /// The people `findUsers` searches.
        var users: [HostUser] = []
        /// Thrown by every Review slice call while set.
        var reviewError: (any Error)?
        /// The username the token acts as.
        var me = "aiterm"
        /// The next this many lookups of the token's user fail, as a host that did not answer.
        var userFailures = 0
        /// The repository the host is bound to: the project's origin as it resolves now.
        var repository = FakeMergeHost.repository
        /// Awaited after a Review slice call is logged, with its line: a test holds a call in flight with it.
        var onCall: (@Sendable (String) async -> Void)?
        /// The next reply reaches the host, then its answer is lost.
        var loseReply = false
        /// A response delayed after the host committed its reviewer replacement.
        var afterAssignment: (@Sendable () async -> Void)?
        /// Thrown by `updateRequest` after it is logged, before the host changes anything, until cleared.
        var editError: (any Error)?
        /// Who the request is assigned to, as `updateRequest` last set it.
        var assignee: String?
        /// Awaited at the start of `updateRequest`, before its reads: a test holds an edit in flight with it.
        var beforeEdit: (@Sendable () async -> Void)?
        /// Each thread whole, by its id; a thread with none is its last note alone.
        var details: [String: ReviewThreadDetail] = [:]
        /// The status of the request's head pipeline, nil with none; a retry of a failed one makes it `running`.
        var pipeline: String?
        /// Awaited inside `retryPipeline` after its read, before `beforeWrite`: a test holds a retry in flight with it.
        var beforeRetry: (@Sendable () async -> Void)?
    }

    private let script: Mutex<Script>
    private let calls = Mutex<[String]>([])

    init(_ script: Script = Script()) { self.script = Mutex(script) }

    var log: [String] { calls.withLock { $0 } }
    var reviewers: [String] { script.withLock { $0.reviewers } }
    /// The request it keeps, as opened and edited.
    var request: MergeRequest? { script.withLock { $0.existing } }
    var assignee: String? { script.withLock { $0.assignee } }
    func update(_ change: (inout Script) -> Void) { script.withLock { change(&$0) } }

    static let url = "https://git.example.net/web/acme-web/-/merge_requests/12"
    static let repository = "git.example.net/web/acme-web"

    var repository: String { script.withLock { $0.repository } }

    func protection(of branch: String) async throws -> BranchProtection {
        calls.withLock { $0.append("protection \(branch)") }
        let (protected, fails, error) = script.withLock { ($0.protected, $0.protectionFails, $0.protectionError) }
        if let error { throw error }
        if fails { throw ProtectionUnknown.unreadable("The host didn’t say which branches it protects") }
        return protected[branch].map { .protected($0) } ?? .unprotected
    }

    func existingRequest(from source: String) async throws -> MergeRequest? {
        calls.withLock { $0.append("existing \(source)") }
        if let hold = script.withLock({ $0.beforeExisting }) { await hold() }
        if let error = script.withLock({ $0.existingError }) { throw error }
        return script.withLock { $0.existing }
    }

    func createRequest(from source: String, into target: String, title: String, description: String, draft: Bool) async throws -> MergeRequest {
        calls.withLock { $0.append("create \(source) → \(target)\(draft ? " draft" : "")") }
        if let hold = script.withLock({ $0.beforeCreate }) { await hold() }
        let request = MergeRequest(iid: 12, title: title, sourceBranch: source, targetBranch: target, author: "aiterm",
                                   state: "opened", draft: draft, url: Self.url, description: description)
        let (fails, loses) = script.withLock { ($0.createFails, $0.loseCreateReply) }
        if fails { throw URLError(.timedOut) }
        script.withLock { $0.existing = request; $0.loseCreateReply = false }
        if loses { throw URLError(.networkConnectionLost) }
        return request
    }

    func readiness(of number: Int) async throws -> MergeReadiness {
        calls.withLock { $0.append("readiness \(number)") }
        if let hold = script.withLock({ $0.beforeReadiness }) { await hold() }
        if script.withLock({ $0.readinessFailsAfterReady }), calls.withLock({ $0.contains("ready \(number)") }) { throw URLError(.timedOut) }
        let failing = script.withLock { s in
            guard s.readinessFailures > 0 else { return false }
            s.readinessFailures -= 1
            return true
        }
        if failing { throw URLError(.timedOut) }
        return script.withLock { s in
            s.readiness.count > 1 ? s.readiness.removeFirst() : (s.readiness.first ?? .waiting("its pipeline is running"))
        }
    }

    func state(of request: MergeRequest) async throws -> MergeRequestState {
        calls.withLock { $0.append("state \(request.iid)") }
        if let hold = script.withLock({ $0.beforeState }) { await hold() }
        if let error = script.withLock({ $0.stateError }) { throw error }
        return script.withLock { s in
            s.state ?? MergeRequestState(iid: request.iid, url: request.url, draft: s.existing?.draft ?? request.draft, pipeline: nil,
                                         mergeable: "mergeable", approvedBy: s.approvals, head: nil)
        }
    }

    func merge(_ number: Int, at sha: String) async throws -> MergeReadiness {
        calls.withLock { $0.append("merge \(number) at \(sha)") }
        return script.withLock { $0.merge } ?? .merged(commit: "5eed5eed", head: sha)
    }

    func retarget(_ number: Int, to target: String) async throws {
        calls.withLock { $0.append("retarget \(number) → \(target)") }
        script.withLock { $0.existing?.targetBranch = target }
    }

    /// Logged as `edit 12 title …; description …; assignee …`, naming only what it changes. The request is the open one it
    /// keeps, or one that is still open when it keeps none.
    func updateRequest(_ number: Int, _ edit: RequestContent, beforeWrite: @Sendable (MergeRequest) async throws -> Void) async throws {
        if let hold = script.withLock({ $0.beforeEdit }) { await hold() }
        let live = script.withLock { $0.existing } ?? MergeRequest(iid: number, title: "", sourceBranch: "", targetBranch: "",
                                                                   author: "aiterm", state: "opened", draft: false, url: Self.url)
        try await beforeWrite(live)
        let parts = [edit.title.map { "title \($0)" }, edit.description.map { "description \($0)" }, edit.assignee.map { "assignee \($0)" }]
        calls.withLock { $0.append("edit \(number) " + parts.compactMap { $0 }.joined(separator: "; ")) }
        if let error = script.withLock({ $0.editError }) { throw error }
        script.withLock { s in
            if let title = edit.title { s.existing?.title = title }
            if let description = edit.description { s.existing?.description = description }
            if let assignee = edit.assignee { s.assignee = assignee }
        }
    }

    // The Review slice's calls, logged as the others are.
    private func reviewCall(_ line: String) async throws {
        calls.withLock { $0.append(line) }
        if let hook = script.withLock({ $0.onCall }) { await hook(line) }
        if let error = script.withLock({ $0.reviewError }) { throw error }
    }

    /// A write is logged only once `beforeWrite` let it go, as a host that was never sent it.
    func markReady(_ number: Int, beforeWrite: @Sendable () async throws -> Void) async throws {
        try await beforeWrite()
        try await reviewCall("ready \(number)")
        script.withLock { $0.existing?.draft = false }
    }

    func assignReviewers(_ number: Int, usernames: [String], beforeWrite: @Sendable () async throws -> Void) async throws {
        let current = script.withLock { $0.reviewers }
        try await reviewCall("reviewers \(number) \(usernames.joined(separator: ","))")
        try await beforeWrite()
        script.withLock { $0.reviewers = current + usernames.filter { !current.contains($0) } }
        if let hook = script.withLock({ $0.afterAssignment }) { await hook() }
    }

    func threads(of number: Int) async throws -> [ReviewThread] {
        try await reviewCall("threads \(number)")
        return script.withLock { $0.threads }
    }

    func reply(_ number: Int, thread: String, body: String) async throws {
        try await reviewCall("reply \(number) \(thread) \(body)")
        if script.withLock({ s in defer { s.loseReply = false }; return s.loseReply }) { throw URLError(.networkConnectionLost) }
    }

    /// Logged as `detail 64 d1`.
    func threadDetail(_ number: Int, thread: String) async throws -> ReviewThreadDetail {
        try await reviewCall("detail \(number) \(thread)")
        return script.withLock { s in
            s.details[thread] ?? ReviewThreadDetail(id: thread, path: nil, line: nil, notes: s.threads.filter { $0.id == thread }
                .map { ReviewThreadDetail.Note(author: $0.lastAuthor, body: $0.lastBody) })
        }
    }

    /// Logged as `resolve 64 d1`; the thread it keeps is resolved after.
    func resolve(_ number: Int, thread: String) async throws {
        try await reviewCall("resolve \(number) \(thread)")
        script.withLock { s in
            if let i = s.threads.firstIndex(where: { $0.id == thread }) { s.threads[i].resolved = true }
        }
    }

    /// Logged as `retry 69` once `beforeWrite` let it go. The request is the open one it keeps, or one still open from
    /// `feat/a` when it keeps none.
    func retryPipeline(_ number: Int, beforeWrite: @Sendable (MergeRequest) async throws -> Void) async throws -> PipelineRetry {
        let (status, live) = script.withLock { s in
            (s.pipeline, s.existing ?? MergeRequest(iid: number, title: "", sourceBranch: "feat/a", targetBranch: "main",
                                                     author: "aiterm", state: "opened", draft: false, url: Self.url))
        }
        if let hold = script.withLock({ $0.beforeRetry }) { await hold() }
        guard let status else { return .notFailed("it has no pipeline") }
        guard status == "failed" else { return .notFailed("its pipeline is \(status)") }
        try await beforeWrite(live)
        calls.withLock { $0.append("retry \(number)") }
        script.withLock { $0.pipeline = "running" }
        return .retried("pipeline 5501")
    }

    func findUsers(_ query: String) async throws -> [HostUser] {
        try await reviewCall("users \(query)")
        return script.withLock { $0.users }.filter {
            $0.username.localizedCaseInsensitiveContains(query) || ($0.name?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func approvals(of number: Int) async throws -> [String] {
        try await reviewCall("approvals \(number)")
        return script.withLock { $0.approvals }
    }

    /// Not logged: a lookup of who the token is changes nothing on the host. Counted in `userLookups`, for a budget.
    func currentUser() async throws -> String {
        lookups.withLock { $0 += 1 }
        return try script.withLock { script in
            guard script.userFailures == 0 else {
                script.userFailures -= 1
                throw URLError(.timedOut)
            }
            return script.me
        }
    }

    private let lookups = Mutex(0)
    /// How many times `currentUser` was asked, which `log` leaves out.
    var userLookups: Int { lookups.withLock { $0 } }
}
