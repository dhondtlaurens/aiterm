import Foundation
import AiTermCore

extension OperatorToolHandler {
    /// Only Oracle preferences follow Settings during a broadcast. Autonomy remains the person's
    /// original grant. Repository pipeline, review and commit checks remain the finisher's own gates.
    func refreshOracleSettings() {
        guard let defaults = ports.preferences, let profile = OperatorProfileStore.saved(defaults) else { return }
        let revision = OperatorProfileStore.oracleRevision(defaults)
        let changed = lastOracleRevision.map { $0 != revision } ?? false
        lastOracleRevision = revision
        let runs = state.runs.filter { !$0.hasEnded && (changed || $0.profile.oracle != profile.oracle) }
        guard !runs.isEmpty else { return }
        for run in runs {
            oracleGenerations[run.id, default: 0] += 1
            for challenge in run.challenges where challenge.stage != .acted {
                runningChallenges.removeValue(forKey: challenge.id)?.cancel()
            }
        }
        workspace.mutate { state in
            for run in runs {
                state.updateRun(id: run.id) {
                    $0.profile.oracle = profile.oracle
                    $0.challenges.removeAll { $0.stage != .acted }
                }
                for task in state.tasks(inRun: run.id) where task.operated?.isFinished == false {
                    state.updateOperated(task.id) {
                        $0.publication?.conditionsHeld = nil
                        $0.publication?.mergeRefusal = nil
                    }
                }
            }
        }
    }

    func oracleGeneration(_ run: UUID) -> Int { oracleGenerations[run, default: 0] }
}
