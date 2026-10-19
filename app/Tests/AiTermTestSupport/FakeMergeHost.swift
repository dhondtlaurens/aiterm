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
        var readiness: [MergeReadiness] = [.waiting("its pipeline is running")]
        /// The merge's answer; nil: merged as `5eed5eed`, at the commit it was asked to merge.
        var merge: MergeReadiness?
        /// The create fails before the host has it (a timeout on the way there).
        var createFails = false
        /// The host opens it, then the answer is lost.
        var loseCreateReply = false
        /// The request's review threads and approvals, as the Review slice reads them.
        var threads: [ReviewThread] = []
        var approvals: [String] = []
        /// The people `findUsers` searches.
        var users: [HostUser] = []
        /// Thrown by every Review slice call while set.
        var reviewError: (any Error)?
        /// The username the token acts as.
        var me = "aiterm"
        /// The repository the host is bound to: the project's origin as it resolves now.
        var repository = FakeMergeHost.repository
        /// Awaited after a Review slice call is logged, with its line: a test holds a call in flight with it.
        var onCall: (@Sendable (String) async -> Void)?
        /// The next reply reaches the host, then its answer is lost.
        var loseReply = false
    }

    private let script: Mutex<Script>
    private let calls = Mutex<[String]>([])

    init(_ script: Script = Script()) { self.script = Mutex(script) }

    var log: [String] { calls.withLock { $0 } }
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
        return script.withLock { $0.existing }
    }

    func createRequest(from source: String, into target: String, title: String, description: String, draft: Bool) async throws -> MergeRequest {
        calls.withLock { $0.append("create \(source) → \(target)\(draft ? " draft" : "")") }
        if let hold = script.withLock({ $0.beforeCreate }) { await hold() }
        let request = MergeRequest(iid: 12, title: title, sourceBranch: source, targetBranch: target, author: "aiterm",
                                   state: "opened", draft: draft, url: Self.url)
        let (fails, loses) = script.withLock { ($0.createFails, $0.loseCreateReply) }
        if fails { throw URLError(.timedOut) }
        script.withLock { $0.existing = request; $0.loseCreateReply = false }
        if loses { throw URLError(.networkConnectionLost) }
        return request
    }

    func readiness(of number: Int) async throws -> MergeReadiness {
        calls.withLock { $0.append("readiness \(number)") }
        return script.withLock { s in
            s.readiness.count > 1 ? s.readiness.removeFirst() : (s.readiness.first ?? .waiting("its pipeline is running"))
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
        try await beforeWrite()
        try await reviewCall("reviewers \(number) \(usernames.joined(separator: ","))")
    }

    func threads(of number: Int) async throws -> [ReviewThread] {
        try await reviewCall("threads \(number)")
        return script.withLock { $0.threads }
    }

    func reply(_ number: Int, thread: String, body: String) async throws {
        try await reviewCall("reply \(number) \(thread) \(body)")
        if script.withLock({ s in defer { s.loseReply = false }; return s.loseReply }) { throw URLError(.networkConnectionLost) }
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

    /// Not logged: a lookup of who the token is changes nothing on the host.
    func currentUser() async throws -> String { script.withLock { $0.me } }
}
