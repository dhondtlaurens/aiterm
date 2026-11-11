import Foundation
import Synchronization
@testable import AiTermCore
@testable import AiTermTestSupport

extension FixPipeline {
    /// The pipeline with the agent's two runs replaced: `prepare` makes a real clone in `root`,
    /// `look` validates `answer` against the clone as the live one does, `apply` runs `work` in the
    /// clone and then the real `FixGuard.check` against the tips read in `look`, and `land` is the
    /// real landing on `TaskWorkflow`'s queue.
    static func fake(git: any GitRunning, root: String,
                     look answer: @escaping @Sendable (FixClone) throws -> FixLookAnswer,
                     apply work: @escaping @Sendable (FixClone) throws -> Void) -> FixPipeline {
        let project = Mutex<String>("")
        return FixPipeline(
            prepare: { request throws(FixRefusal) in
                project.withLock { $0 = request.projectPath }
                return try FixClone.make(for: request, git: git, root: root)
            },
            look: { agent, clone, request throws(FixRefusal) in
                do {
                    let tips = try clone.branchTips()
                    return (try FixLook(validating: try answer(clone), request: request, localOnly: try clone.localOnly(), agent: agent), FixLookSession(id: "S", before: tips))
                } catch let refusal as FixRefusal { throw refusal } catch { throw .cloneFailed("\(error)") }
            },
            apply: { _, clone, proposal, session throws(FixRefusal) in
                defer { session.finish() }
                guard let tips = session.tips else { throw .checkFailed("Couldn’t check the fix: its branches were not read before it was made, so nothing was changed.") }
                do { try work(clone) } catch { throw .cloneFailed("\(error)") }
                return try FixGuard.check(clone, proposal: proposal, before: tips)
            },
            land: { clone, checked throws(FixRefusal) in
                let path = project.withLock { $0 }
                let project = Project(id: UUID(), name: "p", path: path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
                return try await TaskWorkflow(git: git).landFix(from: clone, tip: checked, in: project)
            })
    }
}
