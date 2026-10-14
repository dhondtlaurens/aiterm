import Foundation
import Synchronization
import AiTermCore

extension FixPipeline {
    /// The pipeline with the agent's two runs replaced: `prepare` makes a real clone in `root`,
    /// `look` validates `answer` against the clone as the live one does, `apply` runs `work` in the
    /// clone and then the real `FixGuard.check` against the tips read in `look`, and `land` is the
    /// real landing on `TaskWorkflow`'s queue — this library sees only what Core makes public.
    static func fake(git: any GitRunning, root: String,
                     look answer: @escaping @Sendable (FixClone) throws -> FixLookAnswer,
                     apply work: @escaping @Sendable (FixClone) throws -> Void) -> FixPipeline {
        let before = Mutex<[String: String]>([:])
        let project = Mutex<String>("")
        return FixPipeline(
            prepare: { request throws(FixRefusal) in
                project.withLock { $0 = request.projectPath }
                return try FixClone.make(for: request, git: git, root: root)
            },
            look: { agent, clone, request throws(FixRefusal) in
                do {
                    let tips = try clone.branchTips()
                    before.withLock { $0 = tips }
                    return (try FixLook(validating: try answer(clone), request: request, localOnly: try clone.localOnly(), agent: agent), "S")
                } catch let refusal as FixRefusal { throw refusal } catch { throw .cloneFailed("\(error)") }
            },
            apply: { _, clone, proposal, _ throws(FixRefusal) in
                do { try work(clone) } catch { throw .cloneFailed("\(error)") }
                try FixGuard.check(clone, proposal: proposal, before: before.withLock { $0 })
            },
            land: { clone throws(FixRefusal) in
                let path = project.withLock { $0 }
                let project = Project(id: UUID(), name: "p", path: path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
                return try await TaskWorkflow(git: git).landFix(from: clone, in: project)
            })
    }
}
