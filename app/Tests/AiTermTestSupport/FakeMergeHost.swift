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
        /// Awaited inside a create, after it is logged: a test holds a create in flight with it.
        var beforeCreate: (@Sendable () async -> Void)?
        var existing: MergeRequest?
        var readiness: [MergeReadiness] = [.waiting("its pipeline is running")]
        var merge: MergeReadiness = .merged(commit: "5eed5eed")
        /// The create fails before the host has it (a timeout on the way there).
        var createFails = false
        /// The host opens it, then the answer is lost.
        var loseCreateReply = false
    }

    private let script: Mutex<Script>
    private let calls = Mutex<[String]>([])

    init(_ script: Script = Script()) { self.script = Mutex(script) }

    var log: [String] { calls.withLock { $0 } }
    func update(_ change: (inout Script) -> Void) { script.withLock { change(&$0) } }

    static let url = "https://git.example.net/web/acme-web/-/merge_requests/12"

    func protection(of branch: String) async throws -> BranchProtection {
        calls.withLock { $0.append("protection \(branch)") }
        let (protected, fails) = script.withLock { ($0.protected, $0.protectionFails) }
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
        return script.withLock { $0.merge }
    }

    func retarget(_ number: Int, to target: String) async throws {
        calls.withLock { $0.append("retarget \(number) → \(target)") }
        script.withLock { $0.existing?.targetBranch = target }
    }
}
