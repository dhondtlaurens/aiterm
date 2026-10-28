import Foundation
import AiTermCore

extension OperatorToolHandler {
    func mergeEvidenceIdentity(of task: TaskItem, in run: OperatorRun) -> String {
        PublicationGuard.evidence(task: task, run: run)
    }

    func validateMergeEvidence(_ expected: String?, call: ToolCall, in run: OperatorRun) throws {
        guard let expected else { return }
        let task = try task(call, in: run)
        if let previous = try? JSONDecoder().decode(JSONValue.self, from: Data(expected.utf8)),
           let sha = previous["acceptance"]?["resultSHA"]?.stringValue, task.operated?.acceptance?.resultSHA != sha {
            throw ToolRefusal("\(task.operated?.key ?? task.title) was accepted again on another commit while the Oracle judged its merge: call finish_task again without challengeId.")
        }
        guard let current = state.run(id: run.id), mergeEvidenceIdentity(of: task, in: current) == expected else {
            throw ToolRefusal("The acceptance evidence or required checks changed while the Oracle judged this merge. Call finish_task again without challengeId for a fresh check.")
        }
    }

    /// Fresh repository identity alongside the same acceptance run_status exposes. A failed read is
    /// explicit missing evidence, never a claim of failed tests. No historical refusal is an input.
    func mergeEvidence(of task: TaskItem) async -> String {
        let git = ports.git, path = task.worktreePath, branch = task.branch
        let acceptance = task.operated?.acceptance
        return await BackgroundWork.run {
            var evidence: [String: JSONValue] = [:]
            evidence["acceptance"] = acceptance.flatMap { try? JSONValue(encoding: $0) } ?? .null
            do {
                let repository = Repository(path, git: git)
                let head = try repository.commit("refs/heads/" + branch)
                evidence["branchHead"] = head.map(JSONValue.string) ?? .null
                evidence["acceptanceMatchesHead"] = .bool(head != nil && head == acceptance?.resultSHA)
                evidence["uncommitted"] = .string(try git.run(["status", "--porcelain"], in: path))
                let main = repository.defaultBranch()
                evidence["mainBranch"] = .string(main)
                var refs: [JSONValue] = []
                for ref in ["refs/heads/" + main, "refs/remotes/origin/" + main] {
                    if let sha = try git.ask(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: path, none: [1, 128]),
                       let accepted = acceptance?.resultSHA {
                        refs.append(["ref": .string(ref), "sha": .string(sha),
                                     "includesCurrentMain": .bool(try repository.isAncestor(sha, of: accepted))])
                    }
                }
                evidence["mainAncestry"] = .array(refs)
            } catch {
                evidence["repositoryUnavailable"] = .string("Could not verify the current branch and main ancestry: " + error.localizedDescription)
            }
            return (try? JSONEncoder().encode(JSONValue.object(evidence))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }
}
