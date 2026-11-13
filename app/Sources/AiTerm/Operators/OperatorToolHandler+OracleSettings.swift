import Foundation
import AiTermCore

extension OperatorToolHandler {
    /// Only Oracle preferences follow Settings during a broadcast. Autonomy remains the person's
    /// original grant. Repository pipeline, review and commit checks remain the finisher's own gates.
    func refreshOracleSettings() {
        WorkMeter.note(.oracleSettingsRead)
        let defaults = ports.preferences
        guard let profile = OperatorProfileStore.saved(defaults) else { return }
        let revision = OperatorProfileStore.oracleRevision(defaults)
        let changed = observeOracleRevision(revision)
        let runs = state.runs.filter { !$0.hasEnded && (changed || $0.profile.oracle != profile.oracle) }
        guard !runs.isEmpty else { return }
        for run in runs {
            advanceOracleGeneration(run.id)
            cancelOracleChallenges(run.challenges.filter { $0.stage != .acted }.map(\.id))
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

}
